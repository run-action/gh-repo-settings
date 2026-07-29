#!/usr/bin/env bats
#
# Pins the settings.yml -> REST API contract: which endpoint each key reaches,
# what payload it carries, and that already-matching state issues no write.

load helpers/load

setup() { setup_common; }

@test "dry-run issues no write requests" {
  DRY_RUN=true run_sync
  [ "$status" -eq 0 ]
  run write_calls
  [ -z "$output" ]
}

@test "dry-run still reads, so the reported diff is real" {
  DRY_RUN=true run_sync
  [ "$status" -eq 0 ]
  [ "$(count_calls GET repos/owner/repo)" -eq 1 ]
  run calls
  [[ "$output" == *"GET repos/owner/repo/rulesets"* ]]
}

@test "dry-run reports each pending change" {
  DRY_RUN=true run_sync
  [[ "$output" == *"[dry-run] PATCH"* ]]
  [[ "$output" == *"[dry-run] PUT"* ]]
}

@test "DRY_RUN=1 is honoured as well as true" {
  DRY_RUN=1 run_sync
  [ "$status" -eq 0 ]
  run write_calls
  [ -z "$output" ]
}

@test "secret scanning keys map into the security_and_analysis shape" {
  run_sync
  [ "$status" -eq 0 ]
  run body_of PATCH repos/owner/repo
  [ "$(jq -r '.security_and_analysis.secret_scanning.status' <<<"$output")" = "enabled" ]
  [ "$(jq -r '.security_and_analysis.secret_scanning_push_protection.status' <<<"$output")" = "enabled" ]
}

@test "repository_extra is merged over repository in the same PATCH" {
  run_sync
  run body_of PATCH repos/owner/repo
  [ "$(jq -r '.allow_auto_merge' <<<"$output")" = "true" ]
  [ "$(jq -r '.description' <<<"$output")" = "Test repository" ]
}

@test "PATCH omits keys handled by dedicated endpoints" {
  run_sync
  run body_of PATCH repos/owner/repo
  for key in topics enable_vulnerability_alerts enable_automated_security_fixes \
    enable_secret_scanning enable_secret_scanning_push_protection \
    enable_private_vulnerability_reporting enable_immutable_releases; do
    [ "$(jq -r --arg k "$key" 'has($k)' <<<"$output")" = "false" ]
  done
}

@test "PATCH omits fields that already match the live repo" {
  run_sync
  run body_of PATCH repos/owner/repo
  # allow_squash_merge is true in both the file and the fresh fixture.
  [ "$(jq -r 'has("allow_squash_merge")' <<<"$output")" = "false" ]
  # allow_merge_commit differs, so it must be present.
  [ "$(jq -r '.allow_merge_commit' <<<"$output")" = "false" ]
}

@test "topics go to the topics endpoint as a names array" {
  run_sync
  [ "$(count_calls PUT repos/owner/repo/topics)" -eq 1 ]
  run body_of PUT repos/owner/repo/topics
  [ "$(jq -cr '.names | sort' <<<"$output")" = '["alpha","beta"]' ]
}

@test "a true toggle that is off PUTs its endpoint" {
  run_sync
  [ "$(count_calls PUT repos/owner/repo/vulnerability-alerts)" -eq 1 ]
  [ "$(count_calls PUT repos/owner/repo/automated-security-fixes)" -eq 1 ]
  [ "$(count_calls PUT repos/owner/repo/private-vulnerability-reporting)" -eq 1 ]
}

@test "a false toggle that is on DELETEs its endpoint" {
  run_sync
  [ "$(count_calls DELETE repos/owner/repo/immutable-releases)" -eq 1 ]
  [ "$(count_calls PUT repos/owner/repo/immutable-releases)" -eq 0 ]
}

@test "toggles already in the desired state are skipped" {
  CURL_FIXTURES="$BATS_TEST_DIRNAME/fixtures/api/insync" run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable_vulnerability_alerts already true, skipping."* ]]
  [[ "$output" == *"enable_immutable_releases already false, skipping."* ]]
}

@test "labels are created, updated, or skipped based on live state" {
  run_sync
  [ "$(count_calls POST repos/owner/repo/labels)" -eq 1 ]
  [ "$(jq -r '.name' <<<"$(body_of POST repos/owner/repo/labels)")" = "bug" ]
  [ "$(count_calls PATCH repos/owner/repo/labels/changed)" -eq 1 ]
  [ "$(count_calls PATCH repos/owner/repo/labels/unchanged)" -eq 0 ]
  [[ "$output" == *"= unchanged (unchanged)"* ]]
}

@test "label colour comparison ignores case and a leading hash" {
  # Live "unchanged" is FFFFFF and live "changed" is lowercase 123456; only the
  # genuinely different description should trigger a write.
  CURL_FIXTURES="$BATS_TEST_DIRNAME/fixtures/api/insync" run_sync
  run write_calls
  [[ "$output" != *"labels/unchanged"* ]]
  [[ "$output" != *"labels/changed"* ]]
}

@test "a missing ruleset is created with its rules intact" {
  run_sync
  [ "$(count_calls POST repos/owner/repo/rulesets)" -eq 1 ]
  run body_of POST repos/owner/repo/rulesets
  [ "$(jq -r '.name' <<<"$output")" = "default branch protection" ]
  [ "$(jq -r '.enforcement' <<<"$output")" = "active" ]
  [ "$(jq -cr '[.rules[].type] | sort' <<<"$output")" = '["deletion","non_fast_forward","pull_request"]' ]
  [ "$(jq -cr '.conditions.ref_name.include' <<<"$output")" = '["~DEFAULT_BRANCH"]' ]
}

@test "required_status_checks contexts survive the YAML to JSON round trip" {
  SETTINGS_PATH="$BATS_TEST_DIRNAME/fixtures/status-checks.yml" run_sync
  [ "$status" -eq 0 ]
  run body_of POST repos/owner/repo/rulesets
  local checks
  checks="$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters' <<<"$output")"
  [ "$(jq -r '.strict_required_status_checks_policy' <<<"$checks")" = "true" ]
  [ "$(jq -cr '[.required_status_checks[].context]' <<<"$checks")" = \
    '["shellcheck","yamllint","actionlint","bats"]' ]
}

@test "required_linear_history survives as a parameterless rule" {
  SETTINGS_PATH="$BATS_TEST_DIRNAME/fixtures/status-checks.yml" run_sync
  run body_of POST repos/owner/repo/rulesets
  [ "$(jq -r '[.rules[] | select(.type == "required_linear_history")] | length' <<<"$output")" = "1" ]
}

@test "the repo's own settings.yml parses and produces one ruleset write" {
  SETTINGS_PATH="$REPO_ROOT/.github/settings.yml" run_sync
  [ "$status" -eq 0 ]
  [ "$(count_calls POST repos/owner/repo/rulesets)" -eq 1 ]
  run body_of POST repos/owner/repo/rulesets
  [ "$(jq -cr '[.rules[].type] | sort | join(",")' <<<"$output")" = \
    "deletion,non_fast_forward,pull_request,required_linear_history,required_status_checks" ]
}

@test "an existing ruleset is matched by name and updated, not duplicated" {
  # insync list returns id 42 but the full ruleset differs from the file only
  # if the projection is wrong, so prove the id is used rather than a POST.
  CURL_FIXTURES="$BATS_TEST_DIRNAME/fixtures/api/insync" run_sync
  [ "$(count_calls POST repos/owner/repo/rulesets)" -eq 0 ]
}

@test "an identical ruleset issues no write despite rule order and extra params" {
  CURL_FIXTURES="$BATS_TEST_DIRNAME/fixtures/api/insync" run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"= default branch protection (unchanged)"* ]]
  [ "$(count_calls PUT repos/owner/repo/rulesets/42)" -eq 0 ]
}

@test "actions block reaches the workflow permissions endpoint" {
  run_sync
  [ "$(count_calls PUT repos/owner/repo/actions/permissions/workflow)" -eq 1 ]
  run body_of PUT repos/owner/repo/actions/permissions/workflow
  [ "$(jq -r '.default_workflow_permissions' <<<"$output")" = "read" ]
  [ "$(jq -r '.can_approve_pull_request_reviews' <<<"$output")" = "false" ]
}

@test "unsupported keys in the actions block are dropped" {
  cat >"$BATS_TEST_TMPDIR/extra.yml" <<'EOF'
actions:
  default_workflow_permissions: read
  not_a_real_field: true
EOF
  SETTINGS_PATH="$BATS_TEST_TMPDIR/extra.yml" run_sync
  [ "$status" -eq 0 ]
  run body_of PUT repos/owner/repo/actions/permissions/workflow
  [ "$(jq -r 'has("not_a_real_field")' <<<"$output")" = "false" ]
}

@test "a repo that already matches the file issues no write at all" {
  CURL_FIXTURES="$BATS_TEST_DIRNAME/fixtures/api/insync" run_sync
  [ "$status" -eq 0 ]
  run write_calls
  [ -z "$output" ]
}

@test "absent blocks are skipped rather than cleared" {
  cat >"$BATS_TEST_TMPDIR/only-repo.yml" <<'EOF'
repository:
  description: "Only a description"
EOF
  SETTINGS_PATH="$BATS_TEST_TMPDIR/only-repo.yml" run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"No labels: block found"* ]]
  [[ "$output" == *"No rulesets: block found"* ]]
  [[ "$output" == *"No actions: block found"* ]]
  run write_calls
  [[ "$output" != *"labels"* ]]
  [[ "$output" != *"rulesets"* ]]
  [[ "$output" != *"actions"* ]]
}

@test "a missing settings file fails before any request" {
  SETTINGS_PATH="$BATS_TEST_TMPDIR/nope.yml" run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"Settings file not found"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "no token fails before any request" {
  # PATH without the real gh, so the gh auth token fallback cannot succeed.
  GITHUB_TOKEN= GH_TOKEN= PATH="$BATS_TEST_DIRNAME/stubs:/usr/bin:/bin" run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"No token found"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "an unreadable repo degrades to syncing everything instead of failing" {
  cp "$BATS_TEST_DIRNAME"/fixtures/api/fresh/* "$BATS_TEST_TMPDIR/"
  echo 500 >"$BATS_TEST_TMPDIR/GET_repos_owner_repo.status"
  CURL_FIXTURES="$BATS_TEST_TMPDIR" run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not fetch current repository settings"* ]]
  [ "$(count_calls PATCH repos/owner/repo)" -eq 1 ]
}

@test "GITHUB_API_URL retargets every request, for GHES" {
  GITHUB_API_URL="https://ghe.example.com/api/v3" run_sync
  [ "$status" -eq 0 ]
  run jq -r '.url' "$CURL_LOG"
  [[ "$output" == *"https://ghe.example.com/api/v3/repos/owner/repo"* ]]
  [[ "$output" != *"api.github.com"* ]]
}

#!/usr/bin/env bats
#
# Argument parsing for the gh-settings entrypoint: what each flag exports, and
# that a bad invocation fails loudly instead of syncing something unintended.

load helpers/load

setup() {
  setup_common
  # A repository-only file keeps these tests to a single endpoint, so they
  # assert on argument handling rather than on sync behaviour.
  cat >"$BATS_TEST_TMPDIR/minimal.yml" <<'EOF'
repository:
  description: "From the minimal fixture"
EOF
  export SETTINGS_PATH="$BATS_TEST_TMPDIR/minimal.yml"
}

cli() { run "$REPO_ROOT/gh-settings" "$@"; }

@test "help exits zero and lists every subcommand" {
  cli help
  [ "$status" -eq 0 ]
  for sub in init sync check; do
    [[ "$output" == *"gh-settings $sub"* ]]
  done
}

@test "--help and -h behave like help" {
  cli --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  cli -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "no arguments prints usage rather than syncing" {
  cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "an unknown command exits 2 without any request" {
  cli frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command: frobnicate"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "an unknown sync flag exits 2 without any request" {
  cli sync --wat
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown argument: --wat"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "--settings without a value fails instead of falling back" {
  cli sync --settings
  [ "$status" -ne 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "sync --dry-run performs no write" {
  cli sync --dry-run
  [ "$status" -eq 0 ]
  run write_calls
  [ -z "$output" ]
}

@test "a positional owner/repo overrides the environment" {
  REPOSITORY=owner/repo cli sync --dry-run other/target
  [ "$status" -eq 0 ]
  run jq -r '.path' "$CURL_LOG"
  [[ "$output" == *"repos/other/target"* ]]
  [[ "$output" != *"repos/owner/repo"* ]]
}

@test "--settings points the sync at another file" {
  cat >"$BATS_TEST_TMPDIR/other.yml" <<'EOF'
repository:
  description: "From the other file"
EOF
  cli sync --settings "$BATS_TEST_TMPDIR/other.yml"
  [ "$status" -eq 0 ]
  run body_of PATCH repos/owner/repo
  [ "$(jq -r '.description' <<<"$output")" = "From the other file" ]
}

@test "flags compose in any order" {
  cli sync other/target --dry-run --settings "$SETTINGS_PATH"
  [ "$status" -eq 0 ]
  run write_calls
  [ -z "$output" ]
  run jq -r '.path' "$CURL_LOG"
  [[ "$output" == *"repos/other/target"* ]]
}

@test "check is an alias for healthcheck" {
  cli check --help
  local check_status="$status"
  cli healthcheck --help
  [ "$status" -eq "$check_status" ]
}

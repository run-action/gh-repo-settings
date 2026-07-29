# Shared setup for the bats suite.

setup_common() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  # Set both so the script never falls through to `gh auth token` or to
  # `git remote get-url origin`, which would reach outside the test.
  export GITHUB_TOKEN=fake-token
  export REPOSITORY=owner/repo

  local resolved
  resolved="$(command -v curl || true)"
  if [[ "$resolved" != "$BATS_TEST_DIRNAME/stubs/curl" ]]; then
    printf 'curl resolves to %s, not the stub\n' "${resolved:-nothing}" >&2
    return 1
  fi

  export CURL_LOG="$BATS_TEST_TMPDIR/calls.jsonl"
  : >"$CURL_LOG"
  export CURL_FIXTURES="$BATS_TEST_DIRNAME/fixtures/api/fresh"
  export SETTINGS_PATH="$BATS_TEST_DIRNAME/fixtures/full.yml"
  unset DRY_RUN
}

run_sync() {
  run "$REPO_ROOT/scripts/sync-settings.sh" "$@"
}

calls() {
  jq -r '"\(.method) \(.path)"' "$CURL_LOG"
}

count_calls() {
  jq -s --arg m "$1" --arg p "$2" \
    '[.[] | select(.method == $m and .path == $p)] | length' "$CURL_LOG"
}

body_of() {
  jq -s --arg m "$1" --arg p "$2" \
    'first(.[] | select(.method == $m and .path == $p)) | .body | fromjson' "$CURL_LOG"
}

write_calls() {
  jq -r 'select(.method == "PATCH" or .method == "PUT" or .method == "POST"
                or .method == "DELETE") | "\(.method) \(.path)"' "$CURL_LOG"
}

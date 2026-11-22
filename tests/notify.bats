#!/usr/bin/env bats
# notify.sh: a failed cron pipeline opens one GitHub issue, and the token never reaches the command line or the log.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../notify.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BIN" "$CALLS"
  # A fake curl: records its arguments, the headers file and the body, and answers like the GitHub API
  cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CALLS/args"
prev=
for a in "$@"; do
  [[ $prev == -H && $a == @* ]] && cp "${a#@}" "$CALLS/headers"
  prev=$a
done
cat > "$CALLS/body"
[[ ${FAKE_CURL_FAIL:-} == 1 ]] && { echo 'curl: (22) The requested URL returned error: 401' >&2; exit 22; }
printf '{"url": "https://api.github.com/repos/owner/repo/issues/9", "repository_url": "https://api.github.com/repos/owner/repo", "html_url": "https://github.com/owner/repo/issues/9", "number": 9}\n'
FAKE
  chmod +x "$BIN/curl"
  export PATH="$BIN:$PATH" CALLS
  export GITHUB_TOKEN=secret-token-value CI_REPO=owner/repo CI_PIPELINE_NUMBER=42 CI_PIPELINE_EVENT=cron
  export CI_PIPELINE_URL=https://ci.example/repos/3/pipeline/42 CI_COMMIT_SHA=0123456789abcdef CI_COMMIT_BRANCH=main
  unset CI_CACHE GITHUB_API FAKE_CURL_FAIL
}

@test "a failed cron pipeline opens an issue in its own repository with a link to the pipeline" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'opened https://github.com/owner/repo/issues/9'* ]]
  grep -qx 'https://api.github.com/repos/owner/repo/issues' "$CALLS/args"
  grep -qx -- '-X' "$CALLS/args" && grep -qx 'POST' "$CALLS/args"
  grep -q '"title": *"CI: cron のパイプライン #42 が落ちた"' "$CALLS/body"
  grep -q 'https://ci.example/repos/3/pipeline/42' "$CALLS/body"
  grep -q '0123456789abcdef' "$CALLS/body"
}

@test "the token goes in a headers file, never on the command line or in the output" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *'secret-token-value'* ]]
  grep -qx 'Authorization: Bearer secret-token-value' "$CALLS/headers"
  run ! grep -q 'secret-token-value' "$CALLS/args"
}

@test "a cold-cache run says so in the issue, since the cron's name is not available to the step" {
  export CI_CACHE=off
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'CI_CACHE=off' "$CALLS/body"
}

@test "quotes, backslashes and newlines in the values stay valid JSON" {
  export CI_COMMIT_BRANCH='we"ird\branch'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'we\\"ird\\\\branch' "$CALLS/body"
  # The body is one JSON line: the newlines of the issue text are escaped
  [ "$(wc -l < "$CALLS/body")" -le 1 ]
}

@test "GITHUB_API points the call at another server" {
  export GITHUB_API=https://ghe.example/api/v3
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'https://ghe.example/api/v3/repos/owner/repo/issues' "$CALLS/args"
}

@test "a missing token or repository fails loudly, so a missing secret shows as a failed step" {
  unset GITHUB_TOKEN
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *'GITHUB_TOKEN'* ]]
  export GITHUB_TOKEN=secret-token-value
  unset CI_REPO
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *'CI_REPO'* ]]
}

@test "an API error fails the step" {
  export FAKE_CURL_FAIL=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" != *'secret-token-value'* ]]
}

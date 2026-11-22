#!/usr/bin/env bash
# Open a GitHub issue when a workflow of a cron pipeline fails, so a failed night is seen without anyone checking
# the server.
#
# Run it from the last step of each workflow, with `status: [failure]` (see the README). A separate workflow that
# depends on the others cannot do it: with `status: [failure]` alone, Woodpecker runs it only when none of its
# dependencies succeeded, and it gives a step no word of how the dependencies ended. A step is not told the cron's
# name either, so the issue links to the pipeline.
#
# usage: notify.sh
#
# Settings (environment): GITHUB_TOKEN (required; a fine-grained token with Issues: write, from a Woodpecker
# secret), GITHUB_API (default https://api.github.com), and Woodpecker's CI_REPO, CI_PIPELINE_NUMBER,
# CI_PIPELINE_URL, CI_PIPELINE_EVENT, CI_WORKFLOW_NAME, CI_COMMIT_SHA, CI_COMMIT_BRANCH and CI_CACHE.
set -euo pipefail
shopt -s inherit_errexit

GITHUB_API=${GITHUB_API:-https://api.github.com}

log() { printf '[notify] %s\n' "$*" >&2; }
die() { printf '[notify] ERROR: %s\n' "$*" >&2; exit 2; }

[[ -n ${GITHUB_TOKEN:-} ]] || die 'GITHUB_TOKEN is not set (register the secret and pass it with from_secret)'
[[ -n ${CI_REPO:-} ]] || die 'CI_REPO is not set (run this from a Woodpecker step)'
[[ -n ${CI_PIPELINE_NUMBER:-} ]] || die 'CI_PIPELINE_NUMBER is not set (run this from a Woodpecker step)'
[[ -n ${CI_WORKFLOW_NAME:-} ]] || die 'CI_WORKFLOW_NAME is not set (run this from a Woodpecker step)'

# A JSON string: backslash first, then quotes and the control characters the text can hold
json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

title="CI: ${CI_PIPELINE_EVENT:-cron} のパイプライン #${CI_PIPELINE_NUMBER} の ${CI_WORKFLOW_NAME} が落ちた"
body="${CI_PIPELINE_EVENT:-cron} のパイプラインで、ワークフロー ${CI_WORKFLOW_NAME} が落ちました。どの段が落ちたかは、パイプラインで見てください。

- パイプライン: ${CI_PIPELINE_URL:-（CI_PIPELINE_URL が無い）}
- ブランチ: ${CI_COMMIT_BRANCH:-?}
- コミット: ${CI_COMMIT_SHA:-?}"
if [[ ${CI_CACHE:-} == off ]]; then
  body+="
- キャッシュ: CI_CACHE=off（キャッシュを使わない cron。キャッシュがあるときだけ通っていた疑いがある）"
fi
body+="

この Issue は woodpecker-config の notify.sh が作りました。直したら閉じてください。"

# The token goes in a headers file only this process can read, so it is on neither the command line nor the log
headers=$(mktemp)
trap 'rm -f "$headers"' EXIT
chmod 600 "$headers"
printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$headers"

response=$(printf '{"title": %s, "body": %s}' "$(json "$title")" "$(json "$body")" |
  curl -fsS -X POST \
    -H "@$headers" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    --data-binary @- \
    "$GITHUB_API/repos/$CI_REPO/issues")

# The first html_url of an issue is the issue's own (the user's and the repository's come later). The issue is
# open once curl succeeds, so an answer without it is not a failure
url=$(grep -o '"html_url": *"[^"]*"' <<< "$response" | sed -n '1s/.*"\([^"]*\)"$/\1/p' || true)
log "opened ${url:-an issue in $CI_REPO}"

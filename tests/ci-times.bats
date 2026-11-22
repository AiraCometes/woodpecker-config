#!/usr/bin/env bats
# ci-times.sh: how long each workflow and step of a pipeline took, how long each workflow waited for the agent,
# and which other repositories' pipelines ran on the agent meanwhile.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../ci-times.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # A fake woodpecker-cli that answers the three queries ci-times.sh makes. Times are Unix seconds:
  # pipeline 15 is created at 1000; gate waits 60s, runs 150s; test waits 600s (another repo ran), runs 300s.
  cat > "$BIN/woodpecker-cli" <<'FAKE'
#!/usr/bin/env bash
pwd > "$BATS_TEST_TMPDIR/cwd"
case "$1 $2" in
  'pipeline show')
    [[ $* == *'owner/kura 15'* ]] || { echo "unexpected: $*" >&2; exit 1; }
    printf 'P 15 pull_request success 1000 1060 2110\n'
    printf 'W notify skipped 0 0\n'
    printf 'W test success 1810 2110\n'
    printf 'S clone success 1810 1813\n'
    printf 'S test success 1813 2110\n'
    printf 'W gate success 1060 1210\n'
    printf 'S clone success 1060 1063\n'
    printf 'S gate success 1063 1210\n'
    ;;
  'repo ls')
    printf 'owner/kura\nowner/other\nowner/idle\n'
    ;;
  'pipeline ls')
    case "$*" in
      *owner/other*) printf '7 success push 1200 1800\n3 success push 100 200\n' ;;
      *owner/idle*) printf '' ;;
      *) echo "unexpected: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
  chmod +x "$BIN/woodpecker-cli"
  export PATH="$BIN:$PATH" TZ=UTC
}

@test "each workflow shows its wait and run time, in the order the agent ran them" {
  run "$SCRIPT" owner/kura 15
  [ "$status" -eq 0 ]
  [[ "$output" == *'pipeline 15 (pull_request, success): 18m30s from creation to finish'* ]]
  [[ "$output" == *'gate  waited 1m0s  ran 2m30s'* ]]
  [[ "$output" == *'test  waited 10m0s  ran 5m0s'* ]]
  # gate ran first, so it comes first even though the server listed test first; a workflow that never started
  # comes last
  [[ "$output" == *gate*test*'notify  not started (skipped)'* ]]
}

@test "each step shows its own run time under its workflow" {
  run "$SCRIPT" owner/kura 15
  [ "$status" -eq 0 ]
  [[ "$output" == *'  clone 3s'* ]]
  [[ "$output" == *'  gate 2m27s'* ]]
  [[ "$output" == *'  test 4m57s'* ]]
}

@test "the pipelines of other repositories that overlapped the run are listed, and old ones are not" {
  run "$SCRIPT" owner/kura 15
  [ "$status" -eq 0 ]
  [[ "$output" == *'owner/other #7 (push) 00:20:00-00:30:00'* ]]
  [[ "$output" != *'#3'* ]]
  [[ "$output" != *'owner/idle'* ]]
}

@test "woodpecker-cli runs outside the current folder, so a .env there is not read" {
  cd "$BATS_TEST_TMPDIR"
  run "$SCRIPT" owner/kura 15
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/cwd")" != "$BATS_TEST_TMPDIR" ]
}

@test "missing arguments print the usage" {
  run "$SCRIPT" owner/kura
  [ "$status" -eq 2 ]
  [[ "$output" == *'usage: ci-times.sh OWNER/REPO NUMBER'* ]]
}

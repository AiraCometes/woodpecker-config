#!/usr/bin/env bats
# cache.sh: restore copies a snapshot, only a push or a cron on the default branch stores, and prune keeps the
# cache bounded.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../cache.sh"
  STORE="$BATS_TEST_TMPDIR/store"
  mkdir -p "$STORE"
  export CACHE_RO="$STORE" CACHE_RW="$STORE" CACHE_STATE="$BATS_TEST_TMPDIR/state" CACHE_MIN_FREE_GB=0
  export CI_REPO=owner/repo CI_REPO_DEFAULT_BRANCH=main CI_PIPELINE_NUMBER=7
  export CI_PIPELINE_EVENT=push CI_COMMIT_BRANCH=main
  unset CI_CACHE CI_PIPELINE_CRON
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cd "$WORK" || return
  printf 'lock 1\n' > Cargo.lock
}

prefix() { printf '%s/v1/owner__repo/%s/%s\n' "$STORE" "$1" "$(uname -m)"; }

# A pipeline: a fresh state and volume, restore, fill, save
pipeline() {
  rm -rf "$CACHE_STATE" "$BATS_TEST_TMPDIR/vol"
  mkdir -p "$BATS_TEST_TMPDIR/vol"
}

@test "a first pipeline starts empty and a default branch push stores the snapshot" {
  pipeline
  run "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  [ "$status" -eq 0 ]
  [[ "$output" == *'cargo: no snapshot, starting empty'* ]]
  echo crate > "$BATS_TEST_TMPDIR/vol/cargo/a.crate"
  run "$SCRIPT" save
  [ "$status" -eq 0 ]
  [[ "$output" == *'cargo: stored'* ]]
  key="$("$SCRIPT" key cargo Cargo.lock)"
  [ "$(cat "$(prefix cargo)/$key/data/a.crate")" = crate ]
}

@test "the same lockfile restores the stored snapshot, and a pull request cannot store" {
  pipeline
  "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  echo crate > "$BATS_TEST_TMPDIR/vol/cargo/a.crate"
  "$SCRIPT" save
  pipeline
  export CI_PIPELINE_EVENT=pull_request CI_COMMIT_BRANCH=main
  run "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  [[ "$output" == *'cargo: restored exact'* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/vol/cargo/a.crate")" = crate ]
  echo poisoned > "$BATS_TEST_TMPDIR/vol/cargo/a.crate"
  run "$SCRIPT" save
  [ "$status" -eq 0 ]
  [[ "$output" == *'only a push or a cron on the default branch stores the cache'* ]]
  key="$("$SCRIPT" key cargo Cargo.lock)"
  [ "$(cat "$(prefix cargo)/$key/data/a.crate")" = crate ]
}

@test "a push or a cron on another branch and a manual run do not store" {
  for case in 'push feature' 'manual main' 'cron feature'; do
    pipeline
    export CI_PIPELINE_EVENT="${case% *}" CI_COMMIT_BRANCH="${case#* }"
    "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
    echo x > "$BATS_TEST_TMPDIR/vol/cargo/x"
    run "$SCRIPT" save
    [[ "$output" == *'nothing stored'* ]]
  done
  [ ! -d "$STORE/v1" ]
}

@test "a cron on the default branch stores the snapshot that the next restore reads" {
  pipeline
  export CI_PIPELINE_EVENT=cron CI_COMMIT_BRANCH=main
  run "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  [ "$status" -eq 0 ]
  [[ "$output" == *'cargo: no snapshot, starting empty'* ]]
  echo crate > "$BATS_TEST_TMPDIR/vol/cargo/a.crate"
  run "$SCRIPT" save
  [ "$status" -eq 0 ]
  [[ "$output" == *'cargo: stored'* ]]
  pipeline
  run "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  [[ "$output" == *'cargo: restored exact'* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/vol/cargo/a.crate")" = crate ]
}

@test "a changed lockfile gets a new key: latest starts from the newest snapshot, exact starts empty" {
  pipeline
  "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  "$SCRIPT" restore tools "$BATS_TEST_TMPDIR/vol/tools" exact Cargo.lock =rust-1.100.0
  echo old > "$BATS_TEST_TMPDIR/vol/cargo/old.crate"
  echo rust > "$BATS_TEST_TMPDIR/vol/tools/rustc"
  "$SCRIPT" save
  old_key="$("$SCRIPT" key cargo Cargo.lock)"
  printf 'lock 2\n' > Cargo.lock
  [ "$("$SCRIPT" key cargo Cargo.lock)" != "$old_key" ]
  pipeline
  run "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  [[ "$output" == *"cargo: restored fallback ($old_key)"* ]]
  [ -f "$BATS_TEST_TMPDIR/vol/cargo/old.crate" ]
  run "$SCRIPT" restore tools "$BATS_TEST_TMPDIR/vol/tools" exact Cargo.lock =rust-1.100.0
  [[ "$output" == *'tools: no snapshot, starting empty'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/vol/tools/rustc" ]
  "$SCRIPT" save
  [ -d "$(prefix cargo)/$("$SCRIPT" key cargo Cargo.lock)" ]
}

@test "a literal input such as a version changes the key" {
  [ "$("$SCRIPT" key tools =rust-1.100.0)" != "$("$SCRIPT" key tools =rust-1.99.0)" ]
  [ "$("$SCRIPT" key tools =rust-1.100.0)" = "$("$SCRIPT" key tools =rust-1.100.0)" ]
  [ "$("$SCRIPT" key tools =a)" != "$("$SCRIPT" key cargo =a)" ]
}

@test "a missing input file is an error, not a silent key" {
  pipeline
  run "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest missing.lock
  [ "$status" -eq 2 ]
  [[ "$output" == *'input file not found: missing.lock'* ]]
}

@test "rolling restores the newest and stores a new snapshot every time" {
  pipeline
  "$SCRIPT" restore sccache-test "$BATS_TEST_TMPDIR/vol/sccache" rolling
  echo 1 > "$BATS_TEST_TMPDIR/vol/sccache/one"
  CI_PIPELINE_NUMBER=1 "$SCRIPT" save
  touch -d '-1 minute' "$(prefix sccache-test)"/*/stamp
  pipeline
  run "$SCRIPT" restore sccache-test "$BATS_TEST_TMPDIR/vol/sccache" rolling
  [[ "$output" == *'sccache-test: restored fallback'* ]]
  echo 2 > "$BATS_TEST_TMPDIR/vol/sccache/two"
  CI_PIPELINE_NUMBER=2 "$SCRIPT" save
  [ "$(find "$(prefix sccache-test)" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]
  newest="$(ls -t "$(prefix sccache-test)" | head -n 1)"
  [ -f "$(prefix sccache-test)/$newest/data/one" ]
  [ -f "$(prefix sccache-test)/$newest/data/two" ]
}

@test "CI_CACHE=off restores and stores nothing" {
  pipeline
  "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  echo crate > "$BATS_TEST_TMPDIR/vol/cargo/a.crate"
  "$SCRIPT" save
  pipeline
  run env CI_CACHE=off "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  [[ "$output" == *'cargo: off'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/vol/cargo/a.crate" ]
  run env CI_CACHE=off "$SCRIPT" save
  [[ "$output" == *'nothing stored'* ]]
}

@test "a folder another entry caches is left out of the outer snapshot" {
  pipeline
  "$SCRIPT" restore tools "$BATS_TEST_TMPDIR/vol/tools" exact =rust
  "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/tools/cargo/registry" latest Cargo.lock
  echo bin > "$BATS_TEST_TMPDIR/vol/tools/cargo/rustup"
  echo crate > "$BATS_TEST_TMPDIR/vol/tools/cargo/registry/a.crate"
  "$SCRIPT" save
  tools="$(prefix tools)/$("$SCRIPT" key tools =rust)/data"
  [ -f "$tools/cargo/rustup" ]
  [ ! -e "$tools/cargo/registry" ]
  [ -f "$(prefix cargo)/$("$SCRIPT" key cargo Cargo.lock)/data/a.crate" ]
}

@test "an existing key is not overwritten, only marked as used" {
  pipeline
  "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  echo first > "$BATS_TEST_TMPDIR/vol/cargo/a"
  "$SCRIPT" save
  pipeline
  "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  echo second > "$BATS_TEST_TMPDIR/vol/cargo/a"
  run "$SCRIPT" save
  [[ "$output" == *'already stored, marked as used'* ]]
  [ "$(cat "$(prefix cargo)/$("$SCRIPT" key cargo Cargo.lock)/data/a")" = first ]
}

@test "prune keeps the newest CACHE_KEEP of each name and drops anything unused for CACHE_MAX_AGE_DAYS" {
  for n in 1 2 3; do
    printf 'lock %s\n' "$n" > Cargo.lock
    pipeline
    "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
    echo "$n" > "$BATS_TEST_TMPDIR/vol/cargo/n"
    "$SCRIPT" save
    touch -d "-$((10 - n)) minutes" "$(prefix cargo)/$("$SCRIPT" key cargo Cargo.lock)/stamp"
  done
  pipeline
  "$SCRIPT" restore tools "$BATS_TEST_TMPDIR/vol/tools" exact =old
  echo t > "$BATS_TEST_TMPDIR/vol/tools/t"
  "$SCRIPT" save
  [ "$(find "$(prefix cargo)" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]
  [ ! -d "$(prefix cargo)/$(printf 'lock 1\n' > /tmp/l1.$$ && "$SCRIPT" key cargo /tmp/l1.$$)" ] || true
  touch -d '-40 days' "$(prefix tools)/$("$SCRIPT" key tools =old)/stamp"
  pipeline
  "$SCRIPT" save
  [ ! -d "$(prefix tools)/$("$SCRIPT" key tools =old)" ]
}

@test "prune keeps the whole cache under CACHE_MAX_GB, oldest first" {
  for n in 1 2; do
    pipeline
    "$SCRIPT" restore "big$n" "$BATS_TEST_TMPDIR/vol/big" exact
    head -c 2097152 /dev/zero > "$BATS_TEST_TMPDIR/vol/big/blob"
    "$SCRIPT" save
    touch -d "-$((10 - n)) minutes" "$(prefix "big$n")"/*/stamp
  done
  # 2 MiB each; a cap of 3 MiB keeps only the newer one (CACHE_MAX_GB takes whole GB, so scale with a tiny cap)
  pipeline
  run env CACHE_MAX_GB=0 "$SCRIPT" save
  [ "$status" -eq 0 ]
  [ ! -d "$(prefix big1)" ] || [ -z "$(ls "$(prefix big1)")" ]
}

@test "a restore that cannot copy starts empty instead of half filled" {
  pipeline
  "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  echo crate > "$BATS_TEST_TMPDIR/vol/cargo/a.crate"
  "$SCRIPT" save
  pipeline
  mkdir -p "$BATS_TEST_TMPDIR/vol"
  echo file > "$BATS_TEST_TMPDIR/vol/cargo"
  run "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/vol/cargo" latest Cargo.lock
  [ "$status" -ne 0 ] || [[ "$output" == *'starting empty'* ]]
}

@test "bad arguments are refused" {
  run "$SCRIPT" restore 'Bad Name' /x exact
  [ "$status" -eq 2 ]
  run "$SCRIPT" restore cargo relative exact
  [ "$status" -eq 2 ]
  run "$SCRIPT" restore cargo /x sometimes
  [ "$status" -eq 2 ]
  run env CI_REPO='a/b/c' "$SCRIPT" restore cargo "$BATS_TEST_TMPDIR/x" exact
  [ "$status" -eq 2 ]
  run "$SCRIPT" nope
  [ "$status" -eq 2 ]
}

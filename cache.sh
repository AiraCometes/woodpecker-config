#!/usr/bin/env bash
# Dependency and tool caches for Woodpecker CI, kept on the agent's disk.
#
# Only a successful push to the default branch writes the cache (the `save` step, the one step that mounts the
# cache writable). Every other pipeline only reads it: `restore` copies a snapshot into the pipeline's own
# volume, and the copy is thrown away with the pipeline, so a pull request cannot change what main builds with.
#
# usage:
#   cache.sh restore NAME DIR MODE [INPUT...]
#     NAME   what is cached (tools, cargo, sccache-test...)
#     DIR    where the pipeline uses it (inside /woodpecker, the volume every step shares)
#     MODE   exact   only the snapshot whose key matches; anything else starts empty (tools)
#            latest  the snapshot whose key matches, else the newest one of NAME (downloads checked by lockfiles)
#            rolling the newest one of NAME; save always stores a new one (sccache)
#     INPUT  a file whose content goes into the key, or =TEXT for a literal (a version, an image tag)
#   cache.sh save     store what restore recorded in this pipeline, then prune (default branch pushes only)
#
# Settings (environment): CACHE_RO (default /cache, read-only mount), CACHE_RW (default /cache-rw, the save
# step's writable mount), CACHE_STATE (default /woodpecker/cache-state), CI_CACHE=off or the cron job
# `cache-cold` (nothing is restored or saved), CACHE_KEEP (2), CACHE_MAX_AGE_DAYS (30), CACHE_MAX_GB (50),
# CACHE_SCCACHE_MAX_GB (20), CACHE_MIN_FREE_GB (30).
set -euo pipefail
shopt -s inherit_errexit

CACHE_RO=${CACHE_RO:-/cache}
CACHE_RW=${CACHE_RW:-/cache-rw}
CACHE_STATE=${CACHE_STATE:-/woodpecker/cache-state}
CACHE_KEEP=${CACHE_KEEP:-2}
CACHE_MAX_AGE_DAYS=${CACHE_MAX_AGE_DAYS:-30}
CACHE_MAX_GB=${CACHE_MAX_GB:-50}
CACHE_SCCACHE_MAX_GB=${CACHE_SCCACHE_MAX_GB:-20}
CACHE_MIN_FREE_GB=${CACHE_MIN_FREE_GB:-30}
LAYOUT=v1

log() { printf '[cache] %s\n' "$*" >&2; }
die() { printf '[cache] ERROR: %s\n' "$*" >&2; exit 2; }

disabled() {
  [[ "${CI_CACHE:-}" == off || "${CI_PIPELINE_CRON:-}" == cache-cold ]]
}

# owner/name -> owner__name, so a snapshot path never nests by accident
repo_slug() {
  local repo=${CI_REPO:?CI_REPO is not set}
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "unexpected CI_REPO: $repo"
  printf '%s\n' "${repo/\//__}"
}

prefix() { # ROOT NAME -> the folder that holds NAME's snapshots for this repository and machine
  local slug
  slug=$(repo_slug)
  printf '%s/%s/%s/%s/%s\n' "$1" "$LAYOUT" "$slug" "$2" "$(uname -m)"
}

key_of() { # NAME INPUT... -> 32 hex characters
  local name=$1 input
  shift
  {
    printf 'name:%s\n' "$name"
    for input in "$@"; do
      if [[ "$input" == =* ]]; then
        printf 'text:%s\n' "${input#=}"
      else
        [[ -f "$input" ]] || die "input file not found: $input"
        printf 'file:%s:%s\n' "$input" "$(sha256sum < "$input" | cut -d ' ' -f 1)"
      fi
    done
  } | sha256sum | cut -c 1-32
}

newest() { # PREFIX -> the newest snapshot folder, by its stamp, or nothing
  local dir=$1
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 2 -maxdepth 2 -name stamp -printf '%T@ %h\n' 2>/dev/null | sort -rn | sed -n 1p | cut -d ' ' -f 2-
}

record() { # NAME DIR MODE KEY HIT
  mkdir -p "$CACHE_STATE"
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" > "$CACHE_STATE/$1"
}

cmd_restore() {
  [[ $# -ge 3 ]] || die 'usage: cache.sh restore NAME DIR MODE [INPUT...]'
  local name=$1 dir=$2 mode=$3 key src="" hit=none
  shift 3
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid NAME: $name"
  [[ "$dir" == /* ]] || die "DIR must be absolute: $dir"
  case "$mode" in exact | latest | rolling) ;; *) die "invalid MODE: $mode" ;; esac
  key=$(key_of "$name" "$@")
  mkdir -p "$dir"
  if disabled; then
    log "$name: off (CI_CACHE=off or the cache-cold cron), starting empty"
    record "$name" "$dir" "$mode" "$key" off
    return 0
  fi
  local base
  base=$(prefix "$CACHE_RO" "$name")
  if [[ "$mode" != rolling && -f "$base/$key/stamp" ]]; then
    src="$base/$key"
    hit=exact
  elif [[ "$mode" != exact ]]; then
    src=$(newest "$base")
    [[ -n "$src" ]] && hit=fallback
  fi
  if [[ -z "$src" ]]; then
    log "$name: no snapshot, starting empty"
  elif cp -a --reflink=auto "$src/data/." "$dir/"; then
    log "$name: restored $hit ($(basename "$src"))"
  else
    log "$name: restoring $(basename "$src") failed, starting empty"
    find "$dir" -mindepth 1 -delete
    hit=none
  fi
  record "$name" "$dir" "$mode" "$key" "$hit"
}

default_branch_push() {
  [[ "${CI_PIPELINE_EVENT:-}" == push && -n "${CI_REPO_DEFAULT_BRANCH:-}" && "${CI_COMMIT_BRANCH:-}" == "$CI_REPO_DEFAULT_BRANCH" ]]
}

store() { # NAME DIR MODE KEY HIT
  local name=$1 dir=$2 mode=$3 key=$4 hit=$5 base target tmp other excludes=()
  base=$(prefix "$CACHE_RW" "$name")
  [[ "$mode" == rolling ]] && key="$(date -u +%Y%m%d%H%M%S)-${CI_PIPELINE_NUMBER:-0}"
  target="$base/$key"
  if [[ -f "$target/stamp" ]]; then
    touch "$target/stamp"
    log "$name: $key is already stored, marked as used"
    return 0
  fi
  [[ -d "$dir" ]] || { log "$name: $dir is gone, nothing to store"; return 0; }
  # A folder another entry caches (cargo's registry inside CARGO_HOME) is stored by that entry only
  for other in "$CACHE_STATE"/*; do
    local odir
    odir=$(cut -f 1 "$other")
    [[ "$odir" == "$dir"/* ]] && excludes+=("--exclude=./${odir#"$dir"/}")
  done
  mkdir -p "$base"
  tmp=$(mktemp -d "$base/.tmp-$key-XXXXXX")
  mkdir "$tmp/data"
  if ! tar -C "$dir" "${excludes[@]}" -cf - . | tar -C "$tmp/data" -xf -; then
    rm -rf -- "$tmp"
    log "$name: copying failed, not stored"
    return 0
  fi
  touch "$tmp/stamp"
  if mv -T -- "$tmp" "$target" 2> /dev/null; then
    log "$name: stored $key (was $hit)"
  else
    rm -rf -- "$tmp"
    log "$name: $key was stored by another workflow"
  fi
}

size_kb() { du -sk "$1" 2> /dev/null | cut -f 1; }

# Snapshots of every repository on this machine, oldest first: "<mtime> <folder>"
all_snapshots() {
  [[ -d "$CACHE_RW/$LAYOUT" ]] || return 0
  find "$CACHE_RW/$LAYOUT" -mindepth 5 -maxdepth 5 -name stamp -printf '%T@ %h\n' | sort -n
}

drop() { rm -rf -- "$1"; log "pruned ${1#"$CACHE_RW"/}"; }

cmd_prune() {
  local line dir prefixdir count
  [[ -d "$CACHE_RW/$LAYOUT" ]] || return 0
  # Half-written copies from a save that died
  find "$CACHE_RW/$LAYOUT" -mindepth 4 -maxdepth 4 -name '.tmp-*' -mmin +1440 -exec rm -rf -- {} +
  # 1. Only the newest CACHE_KEEP of each name
  while IFS= read -r prefixdir; do
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      ((count > CACHE_KEEP)) && drop "${line#* }"
    done < <(find "$prefixdir" -mindepth 2 -maxdepth 2 -name stamp -printf '%T@ %h\n' | sort -rn)
  done < <(find "$CACHE_RW/$LAYOUT" -mindepth 3 -maxdepth 3 -type d)
  # 2. Nothing older than CACHE_MAX_AGE_DAYS (neither stored nor used by a default branch push)
  while IFS= read -r dir; do
    drop "${dir%/stamp}"
  done < <(find "$CACHE_RW/$LAYOUT" -mindepth 5 -maxdepth 5 -name stamp -mtime "+$CACHE_MAX_AGE_DAYS")
  # 3. sccache within CACHE_SCCACHE_MAX_GB, everything within CACHE_MAX_GB and CACHE_MIN_FREE_GB free
  local total sccache free
  sccache=0
  while IFS= read -r dir; do
    sccache=$((sccache + $(size_kb "$dir")))
  done < <(all_snapshots | cut -d ' ' -f 2- | grep '/sccache[^/]*/[^/]*/[^/]*$' || true)
  while ((sccache > CACHE_SCCACHE_MAX_GB * 1024 * 1024)); do
    dir=$(all_snapshots | cut -d ' ' -f 2- | grep '/sccache[^/]*/[^/]*/[^/]*$' | sed -n 1p || true)
    [[ -n "$dir" ]] || break
    sccache=$((sccache - $(size_kb "$dir")))
    drop "$dir"
  done
  while :; do
    total=$(size_kb "$CACHE_RW/$LAYOUT")
    free=$(df -Pk "$CACHE_RW" | awk 'NR == 2 { print $4 }')
    ((total > CACHE_MAX_GB * 1024 * 1024 || free < CACHE_MIN_FREE_GB * 1024 * 1024)) || break
    dir=$(all_snapshots | sed -n 1p | cut -d ' ' -f 2-)
    [[ -n "$dir" ]] || break
    drop "$dir"
  done
}

cmd_save() {
  if disabled; then
    log 'off (CI_CACHE=off or the cache-cold cron), nothing stored'
    return 0
  fi
  if ! default_branch_push; then
    log "only a push to the default branch stores the cache (this is ${CI_PIPELINE_EVENT:-?} on ${CI_COMMIT_BRANCH:-?}), nothing stored"
    return 0
  fi
  [[ -d "$CACHE_RW" && -w "$CACHE_RW" ]] || die "$CACHE_RW is not a writable mount"
  local entry name dir mode key hit
  for entry in "$CACHE_STATE"/*; do
    [[ -f "$entry" ]] || continue
    name=$(basename "$entry")
    IFS=$'\t' read -r dir mode key hit < "$entry"
    [[ "$hit" == off ]] && continue
    store "$name" "$dir" "$mode" "$key" "$hit"
  done
  cmd_prune
}

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    restore) cmd_restore "$@" ;;
    save) cmd_save "$@" ;;
    key) key_of "$@" ;;
    *) die 'usage: cache.sh restore NAME DIR MODE [INPUT...] | cache.sh save' ;;
  esac
}

main "$@"

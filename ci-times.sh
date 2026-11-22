#!/usr/bin/env bash
# How long a Woodpecker pipeline took: each workflow's wait for the agent and run time, each step's run time, and
# the other repositories' pipelines that ran on the agent meanwhile (the agent runs one workflow at a time, so a
# long wait is usually another repository's pipeline).
#
# usage: ci-times.sh OWNER/REPO NUMBER
#
# Runs on a person's machine with woodpecker-cli logged in. woodpecker-cli reads a .env in the current folder, so it
# is run from /tmp.
set -euo pipefail
shopt -s inherit_errexit

usage() { echo 'usage: ci-times.sh OWNER/REPO NUMBER' >&2; exit 2; }
[[ $# -eq 2 ]] || usage
repo=$1 number=$2

wp() { (cd /tmp && woodpecker-cli "$@"); }

# 3s, 2m30s, 1h2m3s
dur() {
  local s=$1
  if ((s >= 3600)); then printf '%dh%dm%ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
  elif ((s >= 60)); then printf '%dm%ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"
  fi
}
clock() { date -d "@$1" +%H:%M:%S; }

now=$(date +%s)
# P number event status created started finished / W name state started stopped / S name state started stopped
show=$(wp pipeline show --output 'go-template={{range .}}P {{.Number}} {{.Event}} {{.Status}} {{.Created}} {{.Started}} {{.Finished}}{{"\n"}}{{range .Workflows}}W {{.Name}} {{.State}} {{.Started}} {{.Stopped}}{{"\n"}}{{range .Children}}S {{.Name}} {{.State}} {{.Started}} {{.Stopped}}{{"\n"}}{{end}}{{end}}{{end}}' "$repo" "$number")

read -r _ p_number p_event p_status p_created p_started p_finished < <(grep '^P ' <<< "$show")
((p_finished > 0)) || p_finished=$now
printf 'pipeline %s (%s, %s): %s from creation to finish\n' "$p_number" "$p_event" "$p_status" "$(dur $((p_finished - p_created)))"

# Order the workflows by when the agent started them (the server lists them by id): prefix every line with its
# workflow's start and its position, sort, and drop the prefix
ordered=$(awk '$1 == "W" { start = $4 } $1 == "W" || $1 == "S" { print start, NR, $0 }' <<< "$show" | sort -n -k1,1 -k2,2 | cut -d' ' -f3-)

prev=$p_created
while read -r kind name state started stopped; do
  ((stopped > 0)) || stopped=$now
  suffix=
  [[ $state == success ]] || suffix=" ($state)"
  if [[ $kind == W ]]; then
    if ((started > 0)); then
      printf '%s  waited %s  ran %s%s\n' "$name" "$(dur $((started - prev)))" "$(dur $((stopped - started)))" "$suffix"
      prev=$stopped
    else
      printf '%s  not started%s\n' "$name" "$suffix"
    fi
  elif ((started > 0)); then
    printf '  %s %s%s\n' "$name" "$(dur $((stopped - started)))" "$suffix"
  fi
done <<< "$ordered"

# Other repositories' pipelines that overlapped this one
others=()
while read -r other; do
  [[ -n $other && $other != "$repo" ]] || continue
  while read -r o_number _ o_event o_started o_finished; do
    [[ -n $o_number ]] || continue
    ((o_started > 0)) || continue
    ((o_finished > 0)) || o_finished=$now
    if ((o_started < p_finished && o_finished > p_started)); then
      others+=("$(printf '%s #%s (%s) %s-%s' "$other" "$o_number" "$o_event" "$(clock "$o_started")" "$(clock "$o_finished")")")
    fi
  done < <(wp pipeline ls --limit 10 --output 'go-template={{range .}}{{.Number}} {{.Status}} {{.Event}} {{.Started}} {{.Finished}}{{"\n"}}{{end}}' "$other")
done < <(wp repo ls --output 'go-template={{range .}}{{.FullName}}{{"\n"}}{{end}}')

if ((${#others[@]})); then
  printf 'other pipelines on the agent meanwhile (%s-%s):\n' "$(clock "$p_started")" "$(clock "$p_finished")"
  printf '  %s\n' "${others[@]}"
fi

#!/bin/zsh
# The crash corpus run (Docs/plans/Legacy-PPT-and-Encryption.md §6.4): opens every file in a folder of real `.ppt`
# files through `dccli info`, each with a time limit, and records only how it ended: opened, failed cleanly (with the
# reason), crashed (a signal), or timed out. Nothing from the files is compared, committed or shown; the folder is
# local (by default ~/Library/Caches/DeckCraftNative/govdocs/ppt, filled from Govdocs1 with the operator's approval,
# 2026-10-30), and so is the result.
#
# With CRASH_RUN_RENDER=1 each file that opens is also rendered, every slide at quarter scale, into one scratch folder
# that each file overwrites; a crash or time-out there counts the same.
#
#   Tools/legacy/crash-run.sh [DIR]     prints the tally; exit status = crashes + time-outs
set -uo pipefail
root=${0:A:h:h:h}
dir=${1:-$HOME/Library/Caches/DeckCraftNative/govdocs/ppt}
limit=${CRASH_RUN_SECONDS:-30}
out=$HOME/Library/Caches/DeckCraftNative/govdocs/crash-run.txt
(cd "$root" && swift build --product dccli --scratch-path .build-gate >/dev/null 2>&1) || { print -u2 "crash-run: dccli didn't build"; exit 99 }
dccli=$root/.build-gate/debug/dccli
typeset -A tally=(opened 0 failed 0 crashed 0 timedout 0)
: > "$out"
scratch=$(mktemp -d -t crash-run)
for f in $dir/*(N.); do
  msg=$(timeout $limit "$dccli" info "$f" 2>&1 >/dev/null)
  code=$?
  if (( code == 0 )) && [[ ${CRASH_RUN_RENDER:-0} == 1 ]]; then
    msg=$(timeout $limit "$dccli" render "$f" --all --scale 0.25 "$scratch" 2>&1 >/dev/null)
    code=$?
  fi
  if (( code == 0 )); then kind=opened
  elif (( code == 124 )); then kind=timedout
  elif (( code >= 128 )); then kind=crashed
  else kind=failed
  fi
  tally[$kind]=$((tally[$kind] + 1))
  print -r -- "$kind	${f:t}	${msg//$'\n'/ }" >> "$out"
done
print "opened ${tally[opened]}, failed cleanly ${tally[failed]}, crashed ${tally[crashed]}, timed out ${tally[timedout]} (details in $out)"
exit $((tally[crashed] + tally[timedout]))

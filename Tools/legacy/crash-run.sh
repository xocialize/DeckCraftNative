#!/bin/zsh
# The crash corpus run (Docs/plans/Legacy-PPT-and-Encryption.md §6.4): opens every file in a folder of real `.ppt`
# files through `dccli info`, each with a time limit, and records only how it ended: opened, failed cleanly (with the
# reason), crashed (a signal), or timed out. Nothing from the files is compared, committed or shown; the folder is
# local (by default ~/Library/Caches/DeckCraftNative/govdocs/ppt, filled from Govdocs1 with the operator's approval,
# 2026-10-30; the whole Govdocs1 set, approved 2026-10-31, is in govdocs/ppt-all), and so is the result.
#
# With CRASH_RUN_RENDER=1 each file that opens is also rendered, every slide at quarter scale, into a scratch folder
# of its own; a crash or time-out there counts the same. CRASH_RUN_JOBS runs that many files at once (default 1);
# CRASH_RUN_SECONDS is each step's time limit (default 30); CRASH_RUN_CONFIG=release uses a Release dccli, several
# times faster for rendering a large corpus (Debug, the default, also traps on assertions).
#
#   Tools/legacy/crash-run.sh [DIR]     prints the tally; exit status = crashes + time-outs
set -uo pipefail
root=${0:A:h:h:h}
config=${CRASH_RUN_CONFIG:-debug}
dccli=$root/.build-gate/$config/dccli
limit=${CRASH_RUN_SECONDS:-30}

# One file: prints "kind<TAB>name<TAB>message".
if [[ ${1:-} == --one ]]; then
  f=$2
  msg=$(timeout $limit "$dccli" info "$f" 2>&1 >/dev/null)
  code=$?
  if (( code == 0 )) && [[ ${CRASH_RUN_RENDER:-0} == 1 ]]; then
    scratch=$(mktemp -d -t crash-run)
    msg=$(timeout $limit "$dccli" render "$f" --all --scale 0.25 "$scratch" 2>&1 >/dev/null)
    code=$?
    rm -rf "$scratch"
  fi
  if (( code == 0 )); then kind=opened
  elif (( code == 124 )); then kind=timedout
  elif (( code >= 128 )); then kind=crashed
  else kind=failed
  fi
  print -r -- "$kind	${f:t}	${msg//$'\n'/ }"
  exit 0
fi

dir=${1:-$HOME/Library/Caches/DeckCraftNative/govdocs/ppt}
out=${CRASH_RUN_OUT:-$HOME/Library/Caches/DeckCraftNative/govdocs/crash-run.txt}
(cd "$root" && swift build --product dccli -c $config --scratch-path .build-gate >/dev/null 2>&1) || { print -u2 "crash-run: dccli didn't build"; exit 99 }
export CRASH_RUN_RENDER=${CRASH_RUN_RENDER:-0} CRASH_RUN_SECONDS=$limit CRASH_RUN_CONFIG=$config
print -rN -- $dir/*(N.) | xargs -0 -P ${CRASH_RUN_JOBS:-1} -n 1 zsh $0 --one > "$out"
typeset -A tally=(opened 0 failed 0 crashed 0 timedout 0)
for kind in ${(f)"$(cut -f1 "$out")"}; do tally[$kind]=$((tally[$kind] + 1)); done
print "opened ${tally[opened]}, failed cleanly ${tally[failed]}, crashed ${tally[crashed]}, timed out ${tally[timedout]} (details in $out)"
exit $((tally[crashed] + tally[timedout]))

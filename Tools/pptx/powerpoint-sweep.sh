#!/bin/zsh
# Export every test deck to .pptx with dccli and check each in Microsoft PowerPoint: it opens without the repair
# prompt (powerpoint-check.sh), and PowerPoint sees the same slides and the same number of shapes on each slide as
# DeckCraftNative wrote (nothing silently dropped). The decks are the oracle corpus, every engine script's deck and
# every pointer session's deck from the fixtures. PowerPoint is a black-box oracle: files are opened from a scratch
# copy and closed without saving, and nothing it produces is kept.
#
#   Tools/pptx/powerpoint-sweep.sh [OUT_DIR]     prints one line per deck; exit status = the number of failures
set -uo pipefail
root=${0:A:h:h:h}
out=${1:-$(mktemp -d -t dc-sweep)}
mkdir -p "$out/pptx"
fix=${DECKCRAFT_FIXTURES:-$root/../DeckCraftNative-Fixtures}
source "$root/Tools/oracle/pin.env"
bin=$root/.build-sweep/out/Products/Debug
(cd "$root" && swift build --product dccli --scratch-path .build-sweep >/dev/null 2>&1) || { print -u2 "sweep: dccli didn't build"; exit 99 }

decks=($fix/oracle/${DECKCRAFT_COMMIT[1,8]}/decks/*.deckcraft(N) $fix/engine/*.deckcraft(N) $fix/pointer/*.deckcraft(N))
decks=(${decks:#*from-pptx*})
fails=0
for d in $decks; do
  name=${${d:h}:t}-${d:t:r}
  [[ ${d:h:t} == decks ]] && name=corpus-${d:t:r}
  "$bin/dccli" convert "$d" "$out/pptx/$name.pptx" >/dev/null 2>&1 || { print "EXPORT-FAILED $name"; fails=$((fails + 1)); continue }
done

# 1. The repair prompt.
"$root/Tools/pptx/powerpoint-check.sh" $out/pptx/*.pptx > "$out/check.txt" 2>&1
grep -v '^OPEN-OK' "$out/check.txt" && fails=$((fails + $(grep -vc '^OPEN-OK' "$out/check.txt")))

# 2. Slides and shapes per slide, as PowerPoint reads them, against what DeckCraftNative wrote.
for f in $out/pptx/*.pptx; do
  ppt=$(timeout 90 osascript -e "tell application \"Microsoft PowerPoint\"
open (POSIX file \"$f\")
delay 2
set p to active presentation
set k to count of slides of p
set r to \"\"
repeat with i from 1 to k
set r to r & (count of shapes of slide i of p) & \",\"
end repeat
close p saving no
return r
end tell" 2>&1)
  ours=$("$bin/dccli" info "$f" | python3 -c "import json,sys; print(','.join(str(s['shapes']) for s in json.load(sys.stdin)['slides'])+',')")
  if [[ $ppt == $ours ]]; then print "OK $f:t:r"; else print "DIFF $f:t:r powerpoint=$ppt ours=$ours"; fails=$((fails + 1)); fi
  osascript -e 'tell application "Microsoft PowerPoint" to repeat with p in (get presentations)
close p saving no
end repeat' >/dev/null 2>&1
done
print "decks: ${#decks}, failures: $fails, files in $out"
exit $fails

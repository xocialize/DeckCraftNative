#!/bin/zsh
# Checks that compound files DCCFB writes open in two independent readers, olefile and Apache POI, with every storage
# and stream where DCCFB put it and every stream's bytes intact (Docs/plans/Legacy-PPT-and-Encryption.md, E1). The
# files come from DCCFBTests' writeFilesForOtherReaders (v3 and v4, mini and large streams, a DIFAT, 300 entries).
#
#   Tools/legacy/check-cfb-writer.sh        prints one line per file; exit status = the number of failures
set -uo pipefail
root=${0:A:h:h:h}
tools=${LEGACY_TOOLS:-$HOME/Library/Caches/DeckCraftNative/legacy-tools}
java=${JAVA:-/opt/homebrew/opt/openjdk/bin/java}
py=$tools/venv/bin/python
out=$(mktemp -d -t dccfb-written)
(cd "$root" && swift build --build-tests --scratch-path .build-gate >/dev/null 2>&1) || { print -u2 "check-cfb-writer: build failed"; exit 99 }
(cd "$root" && DCCFB_WRITE_DIR=$out swift test --skip-build --scratch-path .build-gate --filter "CompoundFileTests/writeFilesForOtherReaders" >/dev/null 2>&1) \
  || { print -u2 "check-cfb-writer: the writing test failed"; exit 99 }

compare='
import json, sys
def norm(d): return sorted(((e["path"], e["kind"], e.get("size"), e.get("sha256")) for e in d["entries"]), key=lambda t: t[0].lower())
want = norm(json.load(open(sys.argv[1])))
got = norm(json.loads(sys.stdin.read()))
if want == got: print("same")
else:
    w, g = set(want), set(got)
    print("differs: missing", sorted(w - g)[:3], "extra", sorted(g - w)[:3])
'
fails=0
for f in $out/*.cfb(N); do
  exp=${f:r}.expected.json
  ole=$("$py" -I "$root/Tools/legacy/fixtures.py" olefile-list "$f" 2>&1 | "$py" -I -c "$compare" "$exp" 2>&1)
  poi=$("$java" -cp "$tools/poi-6.0.0/*" "$root/Tools/legacy/PoiTool.java" list-cfb "$f" 2>/dev/null | "$py" -I -c "$compare" "$exp" 2>&1)
  if [[ $ole == same && $poi == same ]]; then print "OK ${f:t}"; else print "FAIL ${f:t} olefile: $ole; POI: $poi"; fails=$((fails + 1)); fi
done
rm -rf "$out"
exit $fails

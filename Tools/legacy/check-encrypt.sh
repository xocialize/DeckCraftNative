#!/bin/zsh
# Checks that password-protected files CNOffCrypto (CraftNativeKit) writes open in two independent readers, msoffcrypto-tool and Apache
# POI, and decrypt to exactly the zip that went in (Docs/plans/Legacy-PPT-and-Encryption.md, E3). The files come from
# CNOffCryptoTests' writeFilesForOtherReaders: each corpus deck's .pptx, encrypted with passwords in ASCII, with
# accents, outside the BMP and at 255 characters.
#
#   Tools/legacy/check-encrypt.sh [OUT_DIR]     prints one line per file; exit status = the number of failures
#   With OUT_DIR the files are kept there (for opening them in PowerPoint).
set -uo pipefail
root=${0:A:h:h:h}
# The writing test is CraftNativeKit's (moved there 2026-11-01): its checkout beside this repo.
kit=${CRAFTNATIVEKIT:-${root:h}/CraftNativeKit}
tools=${LEGACY_TOOLS:-$HOME/Library/Caches/DeckCraftNative/legacy-tools}
java=${JAVA:-/opt/homebrew/opt/openjdk/bin/java}
keep=${1:-}
out=${keep:-$(mktemp -d -t dcoffcrypto-written)}
(cd "$kit" && swift build --build-tests --scratch-path .build-gate >/dev/null 2>&1) || { print -u2 "check-encrypt: build failed"; exit 99 }
(cd "$kit" && CNOFFCRYPTO_WRITE_DIR=$out swift test --skip-build --scratch-path .build-gate --filter "OfficeCryptoTests/writeFilesForOtherReaders" >/dev/null 2>&1) \
  || { print -u2 "check-encrypt: the writing test failed"; exit 99 }
fails=0
for f in $out/*.pptx(N); do
  pw=$(<${f:r}.password)
  t1=$(mktemp); t2=$(mktemp)
  "$tools/venv/bin/msoffcrypto-tool" -p "$pw" "$f" "$t1" 2>/dev/null
  "$java" -cp "$tools/poi-6.0.0/*" "$root/Tools/legacy/PoiTool.java" decrypt-ooxml "$pw" "$f" "$t2" 2>/dev/null
  if cmp -s "${f:r}.plain" "$t1" && cmp -s "${f:r}.plain" "$t2"; then print "OK ${f:t}"; else print "FAIL ${f:t}"; fails=$((fails + 1)); fi
  rm -f "$t1" "$t2"
done
[[ -z $keep ]] && rm -rf "$out"
exit $fails

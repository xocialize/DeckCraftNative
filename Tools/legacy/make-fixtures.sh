#!/bin/zsh
# Makes the legacy test files (Docs/plans/Legacy-PPT-and-Encryption.md §6.1) into ../DeckCraftNative-Fixtures/legacy/,
# from DeckCraftNative's own decks only: nothing here was saved by PowerPoint.
#
#   pptx/        each deck exported by dccli: the plaintext every encrypted copy must decrypt to
#   ppt/         each deck converted to .ppt by LibreOffice (headless)
#   encrypted/   the corpus decks encrypted by Apache POI (Agile AES-256/SHA-512, Agile AES-128/SHA-1, Standard) and
#                msoffcrypto-tool (Agile), and their .ppt encrypted by POI (RC4 CryptoAPI)
#   hostile/     truncated, bit-flipped and chain-broken copies (fixtures.py mutate, fixed seed)
#   reference/   what the independent readers say: POI's JSON dump and ppt2pptx's report of every .ppt
#   manifest.json  every file with its sha256, producer, method and password (.meta.json sidecars)
#
# Needs the tools from E0: LibreOffice in /Applications, Homebrew's openjdk, and ~/Library/Caches/DeckCraftNative/
# legacy-tools/ with POI's jars (poi-6.0.0/) and a venv holding msoffcrypto-tool, olefile and ppt2pptx.
#
#   Tools/legacy/make-fixtures.sh [--quick]     --quick: the corpus decks only
set -uo pipefail
root=${0:A:h:h:h}
fix=${DECKCRAFT_FIXTURES:-$root/../DeckCraftNative-Fixtures}
out=$fix/legacy
tools=${LEGACY_TOOLS:-$HOME/Library/Caches/DeckCraftNative/legacy-tools}
java=${JAVA:-/opt/homebrew/opt/openjdk/bin/java}
soffice=/Applications/LibreOffice.app/Contents/MacOS/soffice
py=$tools/venv/bin/python
quick=0; [[ ${1:-} == --quick ]] && quick=1
source "$root/Tools/oracle/pin.env"

for need in $soffice $java $py $tools/poi-6.0.0/poi-6.0.0.jar $tools/venv/bin/msoffcrypto-tool $tools/venv/bin/ppt2pptx; do
  [[ -e $need ]] || { print -u2 "make-fixtures: missing $need (see the plan's E0)"; exit 2 }
done
(cd "$root" && swift build --product dccli --scratch-path .build-sweep >/dev/null 2>&1) || { print -u2 "make-fixtures: dccli didn't build"; exit 2 }
dccli=$root/.build-sweep/out/Products/Debug/dccli
poi() { "$java" -cp "$tools/poi-6.0.0/*" "$root/Tools/legacy/PoiTool.java" "$@" 2> >(grep -v "Log4j API" >&2) }
meta() { print -r -- "$2" > "$1.meta.json" }
lover=$("$soffice" --version 2>/dev/null | awk '{print $2}')
poiver=6.0.0
mocver=$("$tools/venv/bin/pip" show msoffcrypto-tool 2>/dev/null | awk '/^Version/{print $2}')

rm -rf "$out"
mkdir -p $out/{pptx,ppt,encrypted,hostile,reference}

corpus=($fix/oracle/${DECKCRAFT_COMMIT[1,8]}/decks/*.deckcraft(N))
corpus=(${corpus:#*from-pptx*})
others=($fix/engine/*.deckcraft(N) $fix/pointer/*.deckcraft(N))
(( quick )) && others=()

# 1. Plaintext .pptx from our own decks, and .ppt from LibreOffice.
lo_profile=$(mktemp -d -t lo-fixtures)
for d in $corpus $others; do
  name=${${d:h}:t}-${d:t:r}
  [[ ${d:h:t} == decks ]] && name=corpus-${d:t:r}
  "$dccli" convert "$d" "$out/pptx/$name.pptx" >/dev/null 2>&1 || { print -u2 "export failed: $name"; continue }
  meta "$out/pptx/$name.pptx" "{\"kind\":\"pptx\",\"deck\":\"${d#$fix/}\",\"producer\":\"dccli\"}"
done
"$soffice" --headless --norestore "-env:UserInstallation=file://$lo_profile" --convert-to ppt --outdir "$out/ppt" $out/pptx/*.pptx >/dev/null 2>&1
rm -rf "$lo_profile"
for p in $out/ppt/*.ppt(N); do
  meta "$p" "{\"kind\":\"ppt\",\"from\":\"pptx/${p:t:r}.pptx\",\"producer\":\"LibreOffice $lover\"}"
done

# 2. Encrypted copies of the corpus decks. Passwords cover ASCII, accented letters, a character outside the BMP
#    (a UTF-16 surrogate pair) and Office's 255-character maximum.
long=$(printf 'p%.0s' {1..255})
typeset -A pw=(ascii 'Password1' accents 'Tëst-pässwörd' astral 'key-🔑-2026' long "$long")
i=0
for f in $out/pptx/corpus-*.pptx(N); do
  n=${f:t:r}
  kinds=(ascii accents astral long); k=${kinds[$((i % 4 + 1))]}; i=$((i + 1)); p=${pw[$k]}
  pj=$($py -I -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$p")
  for spec in "agile aes256 sha512" "agile aes128 sha1" "standard aes128 sha1"; do
    set -- ${=spec}
    o=$out/encrypted/$n.poi-$1-$2-$3.pptx
    poi encrypt-ooxml $1 $2 $3 "$p" "$f" "$o" && meta "$o" "{\"kind\":\"encrypted-pptx\",\"plaintext\":\"pptx/${f:t}\",\"producer\":\"Apache POI $poiver\",\"password\":$pj,\"passwordKind\":\"$k\",\"describe\":$($py -I $root/Tools/legacy/fixtures.py describe "$o")}"
  done
  o=$out/encrypted/$n.msoffcrypto-agile.pptx
  "$tools/venv/bin/msoffcrypto-tool" -e -p "$p" "$f" "$o" && meta "$o" "{\"kind\":\"encrypted-pptx\",\"plaintext\":\"pptx/${f:t}\",\"producer\":\"msoffcrypto-tool $mocver\",\"password\":$pj,\"passwordKind\":\"$k\",\"describe\":$($py -I $root/Tools/legacy/fixtures.py describe "$o")}"
  if [[ -f $out/ppt/$n.ppt ]]; then
    o=$out/encrypted/$n.poi-rc4cryptoapi.ppt
    poi encrypt-ppt "$p" "$out/ppt/$n.ppt" "$o" && meta "$o" "{\"kind\":\"encrypted-ppt\",\"from\":\"ppt/$n.ppt\",\"producer\":\"Apache POI $poiver\",\"method\":\"rc4cryptoapi\",\"password\":$pj,\"passwordKind\":\"$k\"}"
  fi
done

# 3. Every encrypted .pptx must decrypt to its plaintext with both independent tools.
bad=0
for o in $out/encrypted/*.pptx(N); do
  p=$($py -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["password"])' "$o.meta.json")
  plain=$out/pptx/${${o:t}%%.*}.pptx
  t1=$(mktemp); t2=$(mktemp)
  "$tools/venv/bin/msoffcrypto-tool" -p "$p" "$o" "$t1" 2>/dev/null; poi decrypt-ooxml "$p" "$o" "$t2"
  if ! cmp -s "$plain" "$t1" || ! cmp -s "$plain" "$t2"; then print -u2 "decrypt mismatch: ${o:t}"; bad=$((bad + 1)); fi
  rm -f "$t1" "$t2"
done

# 4. What the independent readers say about every .ppt.
for p in $out/ppt/*.ppt(N) $out/encrypted/*.ppt(N); do
  pass=()
  [[ -f $p.meta.json ]] && pass=($($py -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("password",""))' "$p.meta.json"))
  poi dump-ppt "$p" $pass > "$out/reference/${p:t}.poi.json" || print -u2 "POI couldn't read ${p:t}"
  t=$(mktemp -d)
  "$tools/venv/bin/ppt2pptx" "$p" -o "$t/x.pptx" --report "$out/reference/${p:t}.ppt2pptx.json" ${pass:+--password} $pass >/dev/null 2>&1 || print -u2 "ppt2pptx couldn't read ${p:t}"
  rm -rf "$t"
done

# 5. Hostile copies (fixed seed), from one file of each kind.
seeds=($out/ppt/corpus-sample.ppt(N) $out/encrypted/corpus-sample.poi-agile-aes256-sha512.pptx(N)
       $out/encrypted/corpus-sample.poi-standard-aes128-sha1.pptx(N) $out/encrypted/corpus-sample.poi-rc4cryptoapi.ppt(N))
$py -I $root/Tools/legacy/fixtures.py mutate 20261030 "$out/hostile" $seeds >/dev/null
for h in $out/hostile/*(N); do meta "$h" "{\"kind\":\"hostile\",\"seed\":20261030}"; done

n=$($py -I $root/Tools/legacy/fixtures.py manifest "$out")
print "legacy fixtures: $n files in $out; decrypt mismatches: $bad"
exit $bad

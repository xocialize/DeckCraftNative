#!/bin/zsh
# Has Microsoft PowerPoint save password-protected copies of DeckCraftNative's own decks, the real-world target of
# the decryption work (Docs/plans/Legacy-PPT-and-Encryption.md §6.1; the operator approved this on 2026-10-30).
# The one exception to "nothing PowerPoint saves is kept": these files stay LOCAL, in
# ~/Library/Caches/DeckCraftNative/powerpoint-protected/, never in the repo or ../DeckCraftNative-Fixtures, and this
# script remakes them.
#
# For each deck: a password to open, as .pptx (Agile) and as .ppt (RC4 CryptoAPI); a password to open and one to
# modify; and a password to modify only (a .pptx that isn't encrypted). PowerPoint is sandboxed: saving into a folder
# it hasn't been given asks "Grant File Access" for that folder, so every file goes through one fixed folder, `work/`,
# which is granted once (the first run shows the prompt; choose Grant Access).
#
#   Tools/legacy/powerpoint-protect.sh [DECK.pptx …]   default: the legacy fixtures' corpus sample, content, charts
set -uo pipefail
root=${0:A:h:h:h}
fix=${DECKCRAFT_FIXTURES:-$root/../DeckCraftNative-Fixtures}
out=$HOME/Library/Caches/DeckCraftNative/powerpoint-protected
py=$HOME/Library/Caches/DeckCraftNative/legacy-tools/venv/bin/python
decks=("$@")
(( ${#decks} )) || decks=($fix/legacy/pptx/corpus-{sample,content,charts}.pptx(N))
(( ${#decks} )) || { print -u2 "powerpoint-protect: no decks (run Tools/legacy/make-fixtures.sh first)"; exit 2 }
# A missing input would leave PowerPoint an error alert per save (it opens whatever path it is given).
for d in $decks; do [[ -f $d ]] || { print -u2 "powerpoint-protect: no such deck: $d"; exit 2 }; done
mkdir -p "$out/work"
ver=$(defaults read "/Applications/Microsoft PowerPoint.app/Contents/Info" CFBundleShortVersionString 2>/dev/null)

# save SRC DST FORMAT OPEN_PW MODIFY_PW: one PowerPoint save, through the granted work folder.
save() {
  local src=$1 dst=$2 fmt=$3 open_pw=$4 modify_pw=$5 tmp=$out/work
  rm -f "$tmp"/in.pptx "$tmp"/out.*(N)
  cp "$src" "$tmp/in.pptx"
  timeout 150 osascript - "$tmp/in.pptx" "$tmp/out.${dst:e}" "$fmt" "$open_pw" "$modify_pw" <<'EOF' >/dev/null
on run argv
  tell application "Microsoft PowerPoint"
    with timeout of 120 seconds
      open (POSIX file (item 1 of argv))
      set p to active presentation
      if (item 4 of argv) is not "" then set password of p to (item 4 of argv)
      if (item 5 of argv) is not "" then set write password of p to (item 5 of argv)
      if (item 3 of argv) is "ppt" then
        save p in (POSIX file (item 2 of argv)) as save as presentation
      else
        save p in (POSIX file (item 2 of argv)) as save as Open XML presentation
      end if
      close p saving no
    end timeout
  end tell
end run
EOF
  local ok=$?
  [[ $ok == 0 && -f $tmp/out.${dst:e} ]] && mv "$tmp/out.${dst:e}" "$dst"
  rm -f "$tmp"/in.pptx "$tmp"/out.*(N)
  [[ -f $dst ]] || { print -u2 "PowerPoint didn't save ${dst:t}"; return 1 }
  local pj mj
  pj=$($py -I -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$open_pw")
  mj=$($py -I -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$modify_pw")
  # olefile's listing (DCCFB's tests) and msoffcrypto-tool's plaintext digest (DCOffCrypto's tests) of a protected file.
  if [[ -n $open_pw && $fmt == pptx ]]; then
    "$py" -I "$root/Tools/legacy/fixtures.py" olefile-list "$dst" > "$dst.olefile.json"
    local plain=$(mktemp)
    "${py:h}/msoffcrypto-tool" -p "$open_pw" "$dst" "$plain" && shasum -a 256 "$plain" | awk '{print $1}' > "$dst.plain.sha256"
    rm -f "$plain"
  elif [[ $fmt == ppt ]]; then
    "$py" -I "$root/Tools/legacy/fixtures.py" olefile-list "$dst" > "$dst.olefile.json"
  fi
  print -r -- "{\"kind\":\"powerpoint-protected\",\"from\":\"${src#$fix/}\",\"producer\":\"Microsoft PowerPoint $ver\",\"format\":\"$fmt\",\"password\":$pj,\"modifyPassword\":$mj,\"describe\":$($py -I $root/Tools/legacy/fixtures.py describe "$dst")}" > "$dst.meta.json"
}

fails=0
for d in $decks; do
  n=${d:t:r}
  save "$d" "$out/$n.open.pptx" pptx 'Password1' '' || fails=$((fails + 1))
  save "$d" "$out/$n.open-accents.pptx" pptx 'Tëst-pässwörd' '' || fails=$((fails + 1))
  save "$d" "$out/$n.open-modify.pptx" pptx 'Password1' 'Modify2' || fails=$((fails + 1))
  save "$d" "$out/$n.modify-only.pptx" pptx '' 'Modify2' || fails=$((fails + 1))
  save "$d" "$out/$n.open.ppt" ppt 'Password1' '' || fails=$((fails + 1))
  save "$d" "$out/$n.open-modify.ppt" ppt 'Password1' 'Modify2' || fails=$((fails + 1))
done
osascript -e 'tell application "Microsoft PowerPoint" to repeat with p in (get presentations)
close p saving no
end repeat' >/dev/null 2>&1
print "powerpoint-protected: $(ls $out/*.ppt(N) $out/*.pptx(N) | wc -l | tr -d ' ') files in $out; failures: $fails"
exit $fails

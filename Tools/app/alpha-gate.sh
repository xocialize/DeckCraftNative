#!/bin/zsh
# DeckCraftNative — deckcraft's six alpha-gate workflows (docs/roadmap.md), driven end to end in the real app
# through the control channel, with a screenshot of each step. Wave 5's acceptance (PLAN.md §7). Step 0, the start
# window, is milestone S1's (Docs/plans/Ribbon-and-StartScreen.md §10): a launch with nothing to open shows it.
#
# Usage: Tools/app/alpha-gate.sh [OUT_DIR]   (builds DeckCraftDev and dccli into .build-gate first)
# GATE_LAYOUT=ribbon|mac runs every workflow in that window layout (`ui.set {layout}` after each launch; R4 runs the
# gate in both). Unset, the app starts as a new install does: the ribbon.
# Every check prints PASS or FAIL; the exit status is the number of failures. Screenshots and the files the
# workflows write land in OUT_DIR (default: a temporary folder, printed at the end).
set -u
ROOT=${0:A:h:h:h}
OUT=${1:-$(mktemp -d -t dc-gate)}
mkdir -p "$OUT"
FIX=${DECKCRAFT_FIXTURES:-$ROOT/../DeckCraftNative-Fixtures}
source "$ROOT/Tools/oracle/pin.env"
CORPUS=$FIX/oracle/${DECKCRAFT_COMMIT[1,8]}/decks
PORT=${GATE_PORT:-7990}
BIN=$ROOT/.build-gate/out/Products/Debug
fails=0

cd "$ROOT"
for p in DeckCraftDev dccli; do
  swift build --product $p --scratch-path .build-gate >/dev/null 2>&1 || { echo "build of $p failed"; exit 99; }
done

app() { "$BIN/dccli" app --port $PORT "$@" 2>&1; }
method() { app --method "$@"; }
# The value at a JSON path in stdin (python syntax after the root, e.g. "['documents'][0]['dirty']").
jq_() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }
check() { # check NAME CONDITION-RESULT(0 = pass)
  if [ "$2" = 0 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}
shot() { method ui.screenshot "{\"path\":\"$OUT/$1.png\"}" >/dev/null; }
LAYOUT=${GATE_LAYOUT:-}
launch() {
  DECKCRAFT_NO_PREFS=1 DECKCRAFT_SHOW_WINDOWED=1 "$BIN/DeckCraftDev" --control $PORT "$@" >"$OUT/app.log" 2>&1 &
  for i in {1..40}; do method ui.inspect '{}' >/dev/null 2>&1 && break; sleep 0.25; done
  method ui.inspect '{}' >/dev/null 2>&1 || { echo "the app didn't answer on port $PORT"; exit 98; }
  [ -n "$LAYOUT" ] && method ui.set "{\"layout\":\"$LAYOUT\"}" >/dev/null
  local now=$(method ui.inspect '{}' | jq_ "['ribbon']['layout']")
  if [ -n "$LAYOUT" ] && [ "$now" != "$LAYOUT" ]; then echo "the layout is $now, not $LAYOUT"; exit 97; fi
  return 0
}
quit() { method app.quit '{}' >/dev/null 2>&1; sleep 1; pkill -f "DeckCraftDev --control $PORT" 2>/dev/null; sleep 0.5; }

echo "== layout: ${LAYOUT:-as a new install}"
echo "== 0. Start screen → create from Harbor → one document"
launch
HOME_=$(method ui.inspect '{}' | jq_ "['startScreen']['shown']")
DOCS=$(method ui.inspect '{}' | jq_ "['documents'].__len__()")
check "launch shows the start window and no untitled document" $([ "$HOME_" = True ] && [ "$DOCS" = 0 ]; echo $?)
method ui.startScreen '{"page":"new","select":"theme:Harbor"}' >/dev/null
method ui.screenshot "{\"path\":\"$OUT/0-start.png\",\"window\":\"start\"}" >/dev/null
method ui.startScreen '{"activate":true}' >/dev/null
DOCS=$(method ui.inspect '{}' | jq_ "['documents'].__len__()")
HOME_=$(method ui.inspect '{}' | jq_ "['home']")
THEME=$(app document.inspect | jq_ "['theme']")
check "created from Harbor: one document, the start window closed" $([ "$DOCS" = 1 ] && [ "$HOME_" = False ] && [ "$THEME" = Harbor ]; echo $?)
shot 0-created
quit

echo "== 1. Build a deck from scratch, save, close, reopen"
launch
app file.new '{"theme":"DeckCraft"}' >/dev/null
TITLE=$(app slide.inspect '{"index":0}' | jq_ "['shapes'][0]['id']")
app text.set "{\"id\":$TITLE,\"text\":\"Quarterly Review\"}" >/dev/null
app slide.new '{"layout":"titleAndContent","title":"Highlights","body":"Revenue up\nCosts down\nNew customers"}' >/dev/null
app shape.insert '{"preset":"star5","rect":[600,300,120,120]}' >/dev/null
PIC=$(ls "$CORPUS"/sample.render/slide-01.png 2>/dev/null | head -1)
[ -n "$PIC" ] && app insert.picture "{\"path\":\"$PIC\",\"rect\":[60,300,240,135]}" >/dev/null
shot 1-built
N=$(app document.inspect | jq_ "['slides'].__len__()")
check "two slides built" $([ "$N" = 2 ]; echo $?)
app file.save "{\"path\":\"$OUT/built.deckcraft\"}" >/dev/null
check "saved .deckcraft" $([ -s "$OUT/built.deckcraft" ]; echo $?)
DIRTY=$(method ui.inspect '{}' | jq_ "['documents'][0]['dirty']")
check "clean after save" $([ "$DIRTY" = False ]; echo $?)
app file.close >/dev/null
method app.open "{\"path\":\"$OUT/built.deckcraft\"}" >/dev/null
SHAPES=$(app document.inspect | jq_ "['slides'][1]['shapes']")
check "reopened with its shapes" $([ "${SHAPES:-0}" -ge 3 ]; echo $?)
shot 1-reopened
quit

echo "== 2. Open a colleague's .pptx, edit, save back as .pptx"
launch "$CORPUS/charts.pptx"
app slide.new '{"layout":"titleOnly","title":"Added in DeckCraftNative"}' >/dev/null
app file.save "{\"path\":\"$OUT/edited.pptx\",\"format\":\"pptx\"}" >/dev/null
check "saved .pptx" $([ -s "$OUT/edited.pptx" ]; echo $?)
"$BIN/dccli" info "$OUT/edited.pptx" >"$OUT/edited.info.json" 2>&1
check ".pptx reads back" $?
shot 2-pptx
quit

echo "== 2b. Open a .ppt: a converted copy with its shapes, saved as .pptx (legacy plan P3)"
launch "$FIX/legacy/ppt/corpus-shapes.ppt"
N=$(app document.inspect | jq_ "['slides'][1]['shapes']")
check "the .ppt opens with its shapes" $([ "${N:-0}" -ge 6 ]; echo $?)
shot 2b-ppt
app file.save "{\"path\":\"$OUT/converted.pptx\",\"format\":\"pptx\"}" >/dev/null
"$BIN/dccli" render "$OUT/converted.pptx" --slide 1 --scale 0.5 "$OUT/2b-converted.png" >/dev/null 2>&1
check "the converted .pptx saves and renders" $([ -s "$OUT/2b-converted.png" ]; echo $?)
quit

echo "== 3. Present: show, transitions, presenter view"
launch "$CORPUS/motion.deckcraft"
method show.start '{"from":0}' >/dev/null
sleep 1
S=$(method ui.inspect '{}' | jq_ "['showing'] is not None")
check "show running" $([ "$S" = True ]; echo $?)
method show.next '{}' >/dev/null; sleep 1.2
method ui.screenshot "{\"path\":\"$OUT/3-show.png\"}" >/dev/null
method ui.screenshot "{\"path\":\"$OUT/3-presenter.png\",\"window\":\"presenter\"}" >/dev/null
method show.end '{}' >/dev/null; sleep 0.5
S=$(method ui.inspect '{}' | jq_ "['showing'] is None")
check "show ended" $([ "$S" = True ]; echo $?)
quit

echo "== 4. Business content: table, chart and its data, a diagram"
launch
app file.new '{}' >/dev/null
app slide.new '{"layout":"titleOnly","title":"Numbers"}' >/dev/null
app insert.table '{"rows":3,"cols":3,"rect":[60,120,400,150]}' >/dev/null
app insert.chart '{"type":"column","rect":[480,120,420,300],"categories":["Q1","Q2","Q3"],"series":[{"name":"Sales","values":[3,5,8]}]}' >/dev/null
app chart.data '{"series":[{"name":"Sales","values":[4,6,9]}]}' >/dev/null
app insert.smartArt '{"kind":"process","items":["Plan","Build","Ship"]}' >/dev/null
shot 4-content
K=$(app document.inspect | jq_ "['slides'][1]['shapes']")
check "table, chart and diagram on the slide" $([ "${K:-0}" -ge 4 ]; echo $?)
quit

echo "== 5. Share: PDF of slides, notes, handouts; images; print to PDF"
launch "$CORPUS/sample.deckcraft"
app file.export "{\"path\":\"$OUT/slides.pdf\"}" >/dev/null
app file.export "{\"path\":\"$OUT/notes.pdf\",\"layout\":\"notes\"}" >/dev/null
app file.export "{\"path\":\"$OUT/handouts.pdf\",\"layout\":\"handouts\",\"perPage\":3}" >/dev/null
app file.export "{\"path\":\"$OUT/slide1.png\",\"slide\":0}" >/dev/null
app app.print "{\"path\":\"$OUT/printed.pdf\",\"layout\":\"handouts\",\"perPage\":6}" >/dev/null
for f in slides.pdf notes.pdf handouts.pdf slide1.png printed.pdf; do check "wrote $f" $([ -s "$OUT/$f" ]; echo $?); done
quit

echo "== 6. Review: comments, replies, resolve; spelling"
launch
app file.new '{}' >/dev/null
TITLE=$(app slide.inspect '{"index":0}' | jq_ "['shapes'][0]['id']")
app text.set "{\"id\":$TITLE,\"text\":\"Teh quick brwn fox\"}" >/dev/null
app comment.add '{"text":"Check the title"}' >/dev/null
app comment.reply '{"index":0,"text":"Fixed it"}' >/dev/null
app comment.resolve '{"index":0}' >/dev/null
C=$(app comment.list | jq_ "[0]['resolved']")
check "comment resolved with a reply" $([ "$C" = True ]; echo $?)
W=$(app review.spelling | jq_ ".__len__()")
check "spelling finds the misspellings" $([ "${W:-0}" -ge 2 ]; echo $?)
app view.pane '{"pane":"comments"}' >/dev/null
shot 6-review
quit

echo
echo "screenshots and files: $OUT"
echo "failures: $fails"
exit $fails

#!/bin/zsh
# Tools/app/ribbon-widths.sh — the ribbon's width check (Docs/plans/Ribbon-and-StartScreen.md §9, milestone R4). It
# launches DeckCraftDev in the ribbon layout and lays every tab out at 1600, 1150, 920 and 700 pt: the regular tabs,
# each contextual tab with its object selected, and the master views' tabs. At each width the ribbon must report
# `truncated == []` in `ui.inspect` (no label clipped, no control cut off or overlapping, measured from the text
# layout) and keep the selected tab in the tab row. It runs in one or more languages:
#
#   en      English
#   pseudo  en-XA, every catalog string accented and bracketed (Tools/l10n/pseudo.sh)
#   double  every localized string twice as long (-NSDoubleLocalizedStrings YES)
#   rtl     right to left (-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES): the ribbon mirrors
#
#   Tools/app/ribbon-widths.sh [en|pseudo|double|rtl|all …] [--shots DIR]   # default: pseudo double rtl
#
# Every tab and width prints PASS or FAIL; the exit status is the number of failures. --shots saves a screenshot of
# each tab at each width (our app's window only). Builds into .build-strings, as pseudo.sh does.
set -u
ROOT=${0:A:h:h:h}
SCRATCH=${SCRATCH:-$ROOT/.build-strings}
BIN=$SCRATCH/out/Products/Debug
PORT=${WIDTHS_PORT:-7994}
SHOTS=""
modes=()
while (( $# )); do
  case $1 in
    --shots) SHOTS=${2:A}; shift ;;
    all) modes+=(en pseudo double rtl) ;;
    en|pseudo|double|rtl) modes+=($1) ;;
    *) echo "unknown argument $1"; exit 99 ;;
  esac
  shift
done
(( ${#modes} )) || modes=(pseudo double rtl)
[ -n "$SHOTS" ] && mkdir -p "$SHOTS"

for p in DeckCraftDev dccli; do
  swift build --package-path "$ROOT" --product $p --scratch-path "$SCRATCH" >/dev/null 2>&1 || { echo "build of $p failed"; exit 99; }
done

launch() {
  export DECKCRAFT_NO_PREFS=1 DECKCRAFT_SHOW_WINDOWED=1
  # pseudo.sh compiles en-XA tables into the built bundles; the other runs are of the English strings.
  [ $1 = pseudo ] || rm -rf "$BIN/en-XA.lproj" "$BIN"/*.bundle/Contents/Resources/en-XA.lproj(N)
  case $1 in
    en) "$BIN/DeckCraftDev" --control $PORT -AppleLanguages '(en)' ;;
    pseudo) SCRATCH=$SCRATCH "$ROOT/Tools/l10n/pseudo.sh" --control $PORT ;;
    double) "$BIN/DeckCraftDev" --control $PORT -AppleLanguages '(en)' -NSDoubleLocalizedStrings YES ;;
    rtl) "$BIN/DeckCraftDev" --control $PORT -AppleLanguages '(en)' -AppleTextDirection YES -NSForceRightToLeftWritingDirection YES ;;
  esac >"${TMPDIR:-/tmp}/dc-ribbon-widths-$1.log" 2>&1 &
  for i in {1..120}; do "$BIN/dccli" app --port $PORT --method ui.inspect '{}' >/dev/null 2>&1 && return 0; sleep 0.25; done
  echo "the app didn't answer on port $PORT ($1)"; exit 98
}
quit() {
  "$BIN/dccli" app --port $PORT --method app.quit '{}' >/dev/null 2>&1; sleep 1
  pkill -f "DeckCraftDev.*--control $PORT" 2>/dev/null; sleep 0.5
}

fails=0
for mode in $modes; do
  echo "== $mode"
  launch $mode
  python3 -I - "$BIN/dccli" $PORT $mode "$SHOTS" <<'PY'
import base64, json, struct, subprocess, sys, time
dccli, port, mode, shots = sys.argv[1:5]

def call(*args):
    out = subprocess.run([dccli, "app", "--port", port, *args], capture_output=True, text=True).stdout
    try:
        d = json.loads(out)
    except ValueError:
        return {}
    return d.get("result", d) if isinstance(d, dict) else d

def method(m, p=None): return call("--method", m, json.dumps(p or {}))
def cmd(c, p=None): return call(c, json.dumps(p or {}))
def ribbon(): return (method("ui.inspect") or {}).get("ribbon", {})

n = 800  # a short silent WAV, for the Audio tabs
wav = b"RIFF" + struct.pack("<I", 36 + n) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 8000, 1, 8) + b"data" + struct.pack("<I", n) + bytes([128]) * n
png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
objects = [("shape.insert", {"preset": "rect", "rect": [300, 100, 100, 100]}), ("insert.picture", {"data": png, "name": "dot.png"}),
           ("insert.table", {"rows": 2, "cols": 2}), ("insert.chart", {"type": "Column"}),
           ("insert.smartArt", {"kind": "process", "items": ["Plan", "Build"]}),
           ("insert.audio", {"data": base64.b64encode(wav).decode(), "name": "tone.wav"})]

cmd("file.new")
method("ui.set", {"layout": "ribbon", "ribbonCollapsed": False})
fails, checked = 0, set()

def walk(tabs):
    global fails
    for t in tabs:
        cmd("view.tab", {"tab": t})
        for w in (1600, 1150, 920, 700):
            method("ui.resize", {"width": w, "height": 700})
            r, deadline = ribbon(), time.time() + 5
            while abs(r.get("width", 0) - w) >= 1 and time.time() < deadline:
                time.sleep(0.2)
                r = ribbon()
            time.sleep(0.4)  # the frames report after the layout
            r = ribbon()
            tid = r.get("tabId", "?")
            checked.add(tid)
            problems = list(r.get("truncated", ["no ribbon"]))
            if abs(r.get("width", 0) - w) >= 1: problems.append(f"the ribbon is {r.get('width')} wide")
            if tid not in r.get("tabsShown", []): problems.append("the selected tab went into »")
            if shots:
                for _ in range(2):  # a screenshot shows the redraw before the last
                    method("ui.screenshot", {"path": f"{shots}/{mode}-{tid}-{w}.png"})
                    time.sleep(0.5)  # and is written after it answers
            print(("PASS" if not problems else "FAIL") + f"  {mode} {tid} {w}" + ("  " + "; ".join(problems) if problems else ""), flush=True)
            fails += bool(problems)

r = ribbon()
walk([t for t in r.get("tabs", []) if t not in r.get("contextual", [])])
for c, p in objects:
    cmd(c, p)
    r = ribbon()
    walk([t for t in r.get("tabs", []) if t in r.get("contextual", [])])
for m in ("view.slideMaster", "view.notesMaster", "view.handoutMaster"):
    cmd(m)
    r = ribbon()
    walk([t for t in r.get("tabs", []) if t in r.get("contextual", [])])
    cmd("view.closeMaster")
print(f"{mode}: {len(checked)} tabs, {fails} failures", flush=True)
sys.exit(min(fails, 250))
PY
  fails=$((fails + $?))
  quit
done
echo "failures: $fails"
exit $(( fails > 250 ? 250 : fails ))

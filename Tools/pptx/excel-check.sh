#!/bin/zsh
# Open each .xlsx in Microsoft Excel and report whether it opens cleanly or asks to be repaired: the embedded
# workbooks DeckCraftNative writes for charts (AB-T-0435). `--from-pptx` takes presentations instead and
# checks every workbook embedded in them (ppt/embeddings/*.xlsx).
# Excel is a black-box oracle here, as PowerPoint is for powerpoint-check.sh: the script never presses Yes
# (recover) or Save. It answers the "We found a problem with some content" alert with No, closes any workbook
# it opened without saving, and leaves nothing open behind it.
#
#   Tools/pptx/excel-check.sh book.xlsx [more.xlsx…]           prints OPEN-OK or NEEDS-REPAIR per file
#   Tools/pptx/excel-check.sh --from-pptx deck.pptx [more…]     the same for each embedded workbook
#
# Each file is opened from a private copy, so Excel never touches the original or writes beside it. Needs
# Excel for Mac and Accessibility access for whatever runs osascript (System Events reads the alert). Exit
# status: 0 when every file opens cleanly, 1 when any needs repair, 2 when a file couldn't be checked (Excel
# showed something else, timed out, or a workbook of the same name was already open).
# EXCEL_TIMEOUT sets the seconds to wait for each file [60].
set -uo pipefail

(( $# )) || { print -u2 "usage: ${0:t} [--from-pptx] file… "; exit 2 }
: ${EXCEL_TIMEOUT:=60}
app="Microsoft Excel"
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

files=()
if [[ $1 == --from-pptx ]]; then
  shift
  for deck in "$@"; do
    dir=$work/from/$RANDOM
    mkdir -p $dir
    unzip -q -o $deck 'ppt/embeddings/*.xlsx' -d $dir 2>/dev/null
    for b in $dir/ppt/embeddings/*.xlsx(N); do
      # A name that says which deck it came from, for the report.
      named=$dir/${deck:t:r}-${b:t}
      mv $b $named
      files+=($named)
    done
  done
else
  files=("$@")
fi

# The text of Excel's frontmost AXDialog window, or nothing when there is none.
dialog_text() {
  osascript 2>/dev/null <<'EOF2'
tell application "System Events"
  if not (exists process "Microsoft Excel") then return ""
  tell process "Microsoft Excel"
    if not (exists (first window whose subrole is "AXDialog")) then return ""
    set AppleScript's text item delimiters to " "
    return (value of every static text of (first window whose subrole is "AXDialog")) as text
  end tell
end tell
EOF2
}

# Press a named button of the frontmost AXDialog. Only No, Cancel and OK are ever passed.
press() {
  osascript -e "tell application \"System Events\" to tell process \"$app\" to click button \"$1\" of (first window whose subrole is \"AXDialog\")" >/dev/null 2>&1
}

# How many open workbooks have this file name.
open_count() {
  osascript -e "tell application \"$app\" to get name of every workbook" 2>/dev/null |
    tr ',' '\n' | sed 's/^ *//' | grep -cxF -- $1
}

close_without_saving() {
  osascript -e "tell application \"$app\" to close (workbooks whose name is \"$1\") saving no" >/dev/null 2>&1
}

rc=0
for src in $files; do
  if [[ ! -f $src ]]; then print "ERROR $src: no such file"; rc=2; continue; fi
  name=${src:t}
  if (( $(open_count $name) > 0 )); then
    print "ERROR $src: a workbook named $name is already open in Excel"; rc=2; continue
  fi
  if [[ -n $(dialog_text) ]]; then
    print "ERROR $src: Excel already shows a dialog: $(dialog_text)"; rc=2; continue
  fi
  copy=$work/$RANDOM/$name
  mkdir -p ${copy:h} && cp $src $copy
  open -a $app $copy

  result=""
  for (( i = 0; i < EXCEL_TIMEOUT * 2; i++ )); do
    sleep 0.5
    text=$(dialog_text)
    if [[ $text == *"found a problem with some content"* ]]; then
      press No || press Cancel
      result=NEEDS-REPAIR
      break
    elif [[ -n $text ]]; then
      result="ERROR $src: Excel shows a dialog the script doesn't answer: ${text//$'\n'/ }"
      break
    elif (( $(open_count $name) > 0 )); then
      # An alert, when there is one, comes before the window; wait a moment in case it follows.
      sleep 1
      if [[ $(dialog_text) == *"found a problem with some content"* ]]; then
        press No || press Cancel; result=NEEDS-REPAIR
      else
        result=OPEN-OK
      fi
      break
    fi
  done

  # No can be followed by a second alert; answer it without opening anything.
  if [[ $result == NEEDS-REPAIR ]]; then
    for (( i = 0; i < 6; i++ )); do
      sleep 0.5
      text=$(dialog_text)
      [[ -z $text ]] && continue
      press OK || press Cancel
    done
  fi
  close_without_saving $name

  case $result in
    OPEN-OK) print "OPEN-OK $src" ;;
    NEEDS-REPAIR) print "NEEDS-REPAIR $src"; (( rc == 0 )) && rc=1 ;;
    "") print "ERROR $src: no workbook or alert after ${EXCEL_TIMEOUT}s"; rc=2 ;;
    *) print $result; rc=2 ;;
  esac
done
exit $rc

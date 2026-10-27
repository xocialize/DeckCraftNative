#!/bin/zsh
# Open each .pptx in Microsoft PowerPoint and report whether it opens cleanly or asks to be repaired.
# PowerPoint is a black-box oracle here: the script never presses Repair or Save. It answers the
# "PowerPoint found a problem with content" alert (an AXDialog window) with Cancel, closes any presentation
# it opened without saving, and leaves nothing open behind it.
#
#   Tools/pptx/powerpoint-check.sh file.pptx [more.pptx…]     prints OPEN-OK or NEEDS-REPAIR per file
#
# Each file is opened from a private copy, so PowerPoint never touches the original or writes beside it.
# Needs PowerPoint for Mac and Accessibility access for whatever runs osascript (System Events reads the
# alert). Exit status: 0 when every file opens cleanly, 1 when any needs repair, 2 when a file couldn't be
# checked (PowerPoint showed something else, timed out, or a presentation of the same name was already open).
# POWERPOINT_TIMEOUT sets the seconds to wait for each file [60].
set -uo pipefail

(( $# )) || { print -u2 "usage: ${0:t} file.pptx [more.pptx…]"; exit 2 }
: ${POWERPOINT_TIMEOUT:=60}
app="Microsoft PowerPoint"
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

# The text of PowerPoint's frontmost AXDialog window, or nothing when there is none.
dialog_text() {
  osascript 2>/dev/null <<'EOF2'
tell application "System Events"
  if not (exists process "Microsoft PowerPoint") then return ""
  tell process "Microsoft PowerPoint"
    if not (exists (first window whose subrole is "AXDialog")) then return ""
    set AppleScript's text item delimiters to " "
    return (value of every static text of (first window whose subrole is "AXDialog")) as text
  end tell
end tell
EOF2
}

# Press a named button of the frontmost AXDialog. Only Cancel and OK are ever passed.
press() {
  osascript -e "tell application \"System Events\" to tell process \"$app\" to click button \"$1\" of (first window whose subrole is \"AXDialog\")" >/dev/null 2>&1
}

# How many open presentations have this file name. (PowerPoint answers a `count … whose` with missing value.)
open_count() {
  osascript -e "tell application \"$app\" to get name of every presentation" 2>/dev/null |
    tr ',' '\n' | sed 's/^ *//' | grep -cxF -- $1
}

close_without_saving() {
  osascript -e "tell application \"$app\" to close (presentations whose name is \"$1\") saving no" >/dev/null 2>&1
}

rc=0
for src in "$@"; do
  if [[ ! -f $src ]]; then print "ERROR $src: no such file"; rc=2; continue; fi
  name=${src:t}
  if (( $(open_count $name) > 0 )); then
    print "ERROR $src: a presentation named $name is already open in PowerPoint"; rc=2; continue
  fi
  if [[ -n $(dialog_text) ]]; then
    print "ERROR $src: PowerPoint already shows a dialog: $(dialog_text)"; rc=2; continue
  fi
  copy=$work/$RANDOM/$name
  mkdir -p ${copy:h} && cp $src $copy
  open -a $app $copy

  result=""
  for (( i = 0; i < POWERPOINT_TIMEOUT * 2; i++ )); do
    sleep 0.5
    text=$(dialog_text)
    if [[ $text == *"found a problem with content"* ]]; then
      press Cancel
      result=NEEDS-REPAIR
      break
    elif [[ -n $text ]]; then
      result="ERROR $src: PowerPoint shows a dialog the script doesn't answer: ${text//$'\n'/ }"
      break
    elif (( $(open_count $name) > 0 )); then
      # An alert, when there is one, comes before the window; wait a moment in case it follows.
      sleep 1
      if [[ $(dialog_text) == *"found a problem with content"* ]]; then
        press Cancel; result=NEEDS-REPAIR
      else
        result=OPEN-OK
      fi
      break
    fi
  done

  # Cancel can be followed by a second alert; answer it without opening anything.
  if [[ $result == NEEDS-REPAIR ]]; then
    for (( i = 0; i < 6; i++ )); do
      sleep 0.5
      text=$(dialog_text)
      [[ -z $text ]] && continue
      if [[ $text == *"$name"* || $text == *"can't"* || $text == *"cannot"* ]]; then
        press OK || press Cancel
      fi
    done
  fi
  close_without_saving $name

  case $result in
    OPEN-OK) print "OPEN-OK $src" ;;
    NEEDS-REPAIR) print "NEEDS-REPAIR $src"; (( rc == 0 )) && rc=1 ;;
    "") print "ERROR $src: no presentation or alert after ${POWERPOINT_TIMEOUT}s"; rc=2 ;;
    *) print $result; rc=2 ;;
  esac
done
exit $rc

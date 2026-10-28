#!/bin/zsh
# End-to-end check of DeckCraftNative's App Intents extension through Shortcuts, with the app NOT running
# (DCExtensions/PORT-NOTES.md, "The Shortcuts end-to-end run").
#   shortcuts-e2e.sh register <version>   install build/release/<version>/export/DeckCraftNative.app into ~/Applications
#                                         (linkd ignores copies under /private/tmp) and register it with lsregister
#   then, once, in the Shortcuts app: a new shortcut named "DeckCraft Export Test" with one action,
#   DeckCraftNative › Export Presentation (format PDF, file: Shortcut Input)
#   shortcuts-e2e.sh run                  run that shortcut on the corpus deck; checks the PDF, and that no app process appeared
#   shortcuts-e2e.sh cleanup              unregister and delete the ~/Applications copy (delete the shortcut by hand)
# Stale LaunchServices records of deleted builds claim the extension's identifier (WFActionErrorDomain 16):
# remove them with `lsregister -u <path>`.
set -euo pipefail
repo=${0:A:h:h:h}
app=$HOME/Applications/DeckCraftNative.app
deck=$repo/../DeckCraftNative-Fixtures/oracle/88c2ceff/decks/sample.deckcraft
out=${TMPDIR:-/tmp}/deckcraft-shortcuts-e2e
shortcut="DeckCraft Export Test"
lsr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
case ${1:-} in
  register)
    export_app=$repo/build/release/${2:?version}/export/DeckCraftNative.app
    rm -rf $app; mkdir -p ${app:h}; ditto $export_app $app
    codesign --verify --deep --strict $app
    $lsr -f -R -trusted $app
    sleep 3; pluginkit -m -v -i com.xocialize.deckcraftnative.Intents ;;
  run)
    rm -rf $out; mkdir -p $out
    print "before: app processes: $(pgrep -x DeckCraftNative || print none)"
    ( for i in {1..300}; do pgrep -x DeckCraftNative >> $out/app-seen.txt || true; pgrep -x DeckCraftIntents >> $out/ext-seen.txt || true; sleep 0.1; done ) &
    poll=$!
    time shortcuts run $shortcut --input-path $deck --output-path $out/sample.pdf
    sleep 2; kill $poll 2>/dev/null || true
    print "after: app processes: $(pgrep -x DeckCraftNative || print none)"
    print "app pids seen while running: $(sort -u $out/app-seen.txt 2>/dev/null | tr '\n' ' ' || true)"
    print "extension pids seen: $(sort -u $out/ext-seen.txt 2>/dev/null | tr '\n' ' ' || true)"
    file $out/sample.pdf
    mdls -name kMDItemNumberOfPages $out/sample.pdf || true ;;
  cleanup)
    $lsr -u $app || true; rm -rf $app $out ;;
  *) sed -n '2,12p' $0 ;;
esac

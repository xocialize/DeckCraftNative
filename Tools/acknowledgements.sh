#!/bin/zsh
# DeckCraftNative — writes Apps/DeckCraftNative/App/Acknowledgements.txt, the licence texts and notices of everything
# the app bundle ships: deckcraft (the ported code), craft-fonts (the bundled fonts, each folder keeps its OFL.txt
# beside it in Contents/Resources/fonts), and every Swift package in Package.resolved. The App folder is synchronized
# with the Xcode target, so the file lands in Contents/Resources. Run it when a dependency changes; release.sh checks
# it is current.
#
# Usage: Tools/acknowledgements.sh [--check]   (--check: exit 1 if the file would change)
set -euo pipefail
root=${0:A:h:h}
out=$root/Apps/DeckCraftNative/App/Acknowledgements.txt
checkouts=${DC_CHECKOUTS:-$root/.build-lead/checkouts}
[[ -d $checkouts ]] || checkouts=$HOME/Library/Caches/DeckCraftNative/xcode/SourcePackages/checkouts
[[ -d $checkouts ]] || { print -u2 "acknowledgements: no package checkouts (build once first)"; exit 2; }

tmp=$(mktemp)
{
  print "DeckCraftNative — acknowledgements"
  print "=================================="
  print
  print "DeckCraftNative is a native macOS port of DeckCraft by the ArtCraft team (https://github.com/storytold/deckcraft)."
  print "It is not made, sponsored or endorsed by the ArtCraft Team. The licences and notices of everything it ships follow."
  print
  print "------------------------------------------------------------------------------------------------------------"
  print "DeckCraft (ported code) — MIT OR Apache-2.0"
  print "------------------------------------------------------------------------------------------------------------"
  cat "$root/LICENSES/deckcraft/NOTICE"; print
  cat "$root/LICENSES/deckcraft/LICENSE-MIT"; print
  print "The Apache License 2.0 text follows the package licences below."
  print
  print "------------------------------------------------------------------------------------------------------------"
  print "craft-fonts (bundled fonts) — each font's licence (SIL Open Font License 1.1 or Apache-2.0) is in its folder"
  print "in Contents/Resources/fonts/; the font list and sources are in craft-fonts' ATTRIBUTION.md."
  print "------------------------------------------------------------------------------------------------------------"
  [[ -f $root/../craft-fonts/ATTRIBUTION.md ]] && cat "$root/../craft-fonts/ATTRIBUTION.md"
  print
  for pin in $(python3 -c "import json;print(' '.join(p['identity'] for p in json.load(open('$root/Package.resolved'))['pins']))"); do
    dir=$(ls -d "$checkouts"/* 2>/dev/null | while read d; do [[ ${d:t:l} == ${pin:l} ]] && print "$d"; done | head -1 || true)
    [[ -n $dir ]] || { print -u2 "acknowledgements: no checkout for $pin in $checkouts"; exit 3; }
    print "------------------------------------------------------------------------------------------------------------"
    print "${dir:t} (Swift package)"
    print "------------------------------------------------------------------------------------------------------------"
    lic=$(ls "$dir" | grep -iE '^(LICENSE|LICENCE|COPYING)(\.(txt|md))?$' | head -1 || true)
    [[ -n $lic ]] && cat "$dir/$lic" || print "(no licence file in the package)"
    note=$(ls "$dir" | grep -iE '^NOTICE(\.(txt|md))?$' | head -1 || true)
    [[ -n $note ]] && { print; cat "$dir/$note"; }
    print
  done
  print "------------------------------------------------------------------------------------------------------------"
  print "Apache License 2.0 (DeckCraft's alternative licence)"
  print "------------------------------------------------------------------------------------------------------------"
  cat "$root/LICENSES/deckcraft/LICENSE-APACHE"
} > "$tmp"

if [[ ${1:-} == --check ]]; then
  cmp -s "$tmp" "$out" && { rm "$tmp"; exit 0; } || { rm "$tmp"; print -u2 "Acknowledgements.txt is out of date: run Tools/acknowledgements.sh"; exit 1; }
fi
mv "$tmp" "$out"
print "wrote $out ($(wc -l < "$out") lines)"

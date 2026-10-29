#!/bin/zsh
# Tools/l10n/pseudo.sh — run DeckCraftDev in the build-only pseudo-language en-XA: every string that comes from a
# String Catalog shows bracketed and accented ("[Śļîðé Šöŕţéŕ]"), so English text left in view is text that
# bypasses the catalogs. The en-XA tables are compiled into the built resource bundles of .build-strings only;
# the catalogs never get an en-XA localization.
#
#   Tools/l10n/pseudo.sh [--control PORT] [--sample | file …]   # builds, adds en-XA, launches
set -euo pipefail
ROOT=${0:A:h:h:h}
SCRATCH=${SCRATCH:-$ROOT/.build-strings}
PRODUCTS=$SCRATCH/out/Products/Debug
SOURCES=$ROOT/Packages/DCApp/Sources
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --product DeckCraftDev 2>&1 | grep -E "error|Build complete"
L10N=(python3 -I "$ROOT/Tools/l10n/l10n.py")
"${L10N[@]}" pseudo "$SOURCES/DCAppModel/Resources/Localizable.xcstrings" "$PRODUCTS/DeckCraftNative_DCAppModel.bundle/Contents/Resources"
"${L10N[@]}" pseudo "$SOURCES/DCAppModel/Resources/Commands.xcstrings" "$PRODUCTS/DeckCraftNative_DCAppModel.bundle/Contents/Resources"
"${L10N[@]}" pseudo "$SOURCES/DCAppModel/Resources/Ribbon.xcstrings" "$PRODUCTS/DeckCraftNative_DCAppModel.bundle/Contents/Resources"
"${L10N[@]}" pseudo "$SOURCES/DCApp/Resources/Localizable.xcstrings" "$PRODUCTS/DeckCraftNative_DCApp.bundle/Contents/Resources"
# The resource bundles follow the language the main bundle picks (CFBundle doesn't mix localizations), and
# DeckCraftDev's main bundle is its folder: give it an en-XA.lproj too.
mkdir -p "$PRODUCTS/en-XA.lproj"
print -r -- '"DeckCraftDev" = "DeckCraftDev";' > "$PRODUCTS/en-XA.lproj/PseudoLanguage.strings"
exec "$PRODUCTS/DeckCraftDev" -AppleLanguages '(en-XA)' "$@"

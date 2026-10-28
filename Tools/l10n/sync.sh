#!/bin/zsh
# Tools/l10n/sync.sh — fill the String Catalogs with every key the code uses. Re-run it after changing UI text.
#
# The keys come from the compiler, not from a guess. A target with a String Catalog is compiled with string
# extraction on (`-emit-localized-strings`, which SwiftPM and Xcode turn on by themselves): every source file
# writes a `.stringsdata` listing each `String(localized:)`, `Text(…)`, `LocalizedStringResource` and
# `String.LocalizationValue` literal with its type-checked format key (`\(n)` of an Int is `%lld`, of a String
# `%@`) and its `comment:`; Xcode adds the App Shortcuts phrases and parameter summaries. `xcstringstool sync`
# merges them into the catalogs: new keys are added, keys no longer used are marked stale, plural variations
# and translations already there are kept. Then `l10n.py` adds the plural variations in `plurals.json` and
# writes every English value out (`fill`).
#
#   catalog                                                   keys from
#   Packages/DCApp/Sources/DCAppModel/Resources/Localizable   DCAppModel (bundle: .module)
#   Packages/DCApp/Sources/DCApp/Resources/Localizable        DCApp (bundle: .module)
#   Apps/DeckCraftNative/App/Localizable                      the main bundle: App Intents metadata in DCApp/Intents
#                                                             (no `bundle:`) and the app target's own files
#   Apps/DeckCraftNative/App/AppShortcuts                     the App Shortcuts phrases
#   Apps/DeckCraftNative/App/InfoPlist                        the built app's Info.plist (name, copyright, document types)
#   Packages/DCExtensions/Sources/DCIntentsKit/Resources/Localizable
#                                                             DCIntentsKit (bundle: .module): the file intents' run-time text
#   Apps/DeckCraftNative/Extensions/Intents/Localizable       the App Intents extension's main bundle: DCIntentsKit's
#                                                             App Intents metadata (no `bundle:`) and parameter summaries
#                                                             (the app's catalog holds them too: both bundles list the intents)
#
# The Commands catalog is generated from the registry by `Tools/l10n/commands.sh`, not here.
#
#   Tools/l10n/sync.sh            # SwiftPM build (.build-strings) and Xcode build of the app
#   Tools/l10n/sync.sh --no-app   # the two package catalogs only
set -euo pipefail
ROOT=${0:A:h:h:h}
SCRATCH=${SCRATCH:-$ROOT/.build-strings}
DERIVED=${DERIVED:-$HOME/Library/Caches/DeckCraftNative/xcode-strings}
OUT=$SCRATCH/l10n-stringsdata
SOURCES=$ROOT/Packages/DCApp/Sources
EXT_SOURCES=$ROOT/Packages/DCExtensions/Sources
APP=$ROOT/Apps/DeckCraftNative/App
INTENTS_EXT=$ROOT/Apps/DeckCraftNative/Extensions/Intents
L10N=(python3 -I "$ROOT/Tools/l10n/l10n.py")
WITH_APP=1
[[ ${1:-} == --no-app ]] && WITH_APP=0

if ! log=$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --target DCApp 2>&1); then
    print -r -- "$log" | grep -E "error" | head -20
    echo "sync.sh: the build failed; the catalogs are unchanged" >&2
    exit 1
fi

# The .stringsdata of the last build (a file that wasn't recompiled keeps its earlier, still current one).
rm -rf "$OUT"
mkdir -p "$OUT"
for module in DCAppModel DCApp DCIntentsKit; do
    cp "$SCRATCH"/out/Intermediates.noindex/DeckCraftNative.build/Debug/$module-t.build/Objects-normal/*/*.stringsdata "$OUT"/
done
"${L10N[@]}" split "$OUT" "$SOURCES" "$EXT_SOURCES"

finish() {  # plurals, English values, counts
    "${L10N[@]}" plurals "$1" "$ROOT/Tools/l10n/plurals.json"
    "${L10N[@]}" fill "$1"
    "${L10N[@]}" stats "$1"
}

for module in DCAppModel DCApp; do
    xcrun xcstringstool sync "$SOURCES/$module/Resources/Localizable.xcstrings" --stringsdata "$OUT/$module"/*.stringsdata
    finish "$SOURCES/$module/Resources/Localizable.xcstrings"
done
xcrun xcstringstool sync "$EXT_SOURCES/DCIntentsKit/Resources/Localizable.xcstrings" --stringsdata "$OUT/DCIntentsKit"/*.stringsdata
finish "$EXT_SOURCES/DCIntentsKit/Resources/Localizable.xcstrings"

if (( WITH_APP )); then
    if ! log=$(xcodebuild -project "$ROOT/Apps/DeckCraftNative/DeckCraftNative.xcodeproj" -scheme DeckCraftNative \
        -configuration Debug -derivedDataPath "$DERIVED" build CODE_SIGNING_ALLOWED=NO 2>&1); then
        print -r -- "$log" | grep -E "error:" | head -20
        echo "sync.sh: the app build failed; the app's catalogs are unchanged" >&2
        exit 1
    fi
    objects=("$DERIVED"/Build/Intermediates.noindex/DeckCraftNative.build/Debug/DeckCraftNative.build/Objects-normal/*)
    appdata=("$objects[1]"/*.stringsdata(N) "$OUT"/App/*.stringsdata(N))
    xcrun xcstringstool sync "$APP/Localizable.xcstrings" "$APP/AppShortcuts.xcstrings" --stringsdata "${appdata[@]}"
    finish "$APP/Localizable.xcstrings"
    "${L10N[@]}" fill "$APP/AppShortcuts.xcstrings"
    "${L10N[@]}" stats "$APP/AppShortcuts.xcstrings"
    "${L10N[@]}" infoplist "$DERIVED/Build/Products/Debug/DeckCraftNative.app/Contents/Info.plist" "$APP/InfoPlist.xcstrings"
    "${L10N[@]}" stats "$APP/InfoPlist.xcstrings"
    # The App Intents extension: DCIntentsKit's metadata literals and the summaries Xcode extracts for it.
    extobjects=("$DERIVED"/Build/Intermediates.noindex/DeckCraftNative.build/Debug/DeckCraftIntents.build/Objects-normal/*)
    extdata=("$extobjects[1]"/*.stringsdata(N) "$OUT"/Intents/*.stringsdata(N))
    xcrun xcstringstool sync "$INTENTS_EXT/Localizable.xcstrings" --stringsdata "${extdata[@]}"
    finish "$INTENTS_EXT/Localizable.xcstrings"
fi

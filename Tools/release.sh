#!/bin/zsh
# Builds a release DMG of DeckCraftNative:
#   archive (Release) → Developer ID export → verify signatures (the app and every nested binary) → DMG → sign
#   → [notarize + staple the app and the DMG]
#
#   Tools/release.sh                      Developer ID–signed DMG, not notarized (Gatekeeper refuses it on other Macs)
#   Tools/release.sh --notarize PROFILE   notarized and stapled: the distributable build
#   Tools/release.sh --allow-dirty …      build from a tree with uncommitted changes (refused when notarizing)
#
# Needs a "Developer ID Application" certificate for team CFZS6RXUCP in the login keychain and, to notarize, a
# notarytool keychain profile (`xcrun notarytool store-credentials PROFILE --apple-id … --team-id CFZS6RXUCP`;
# credentials never pass through this script). The fleet's profile is `mlx-notary`.
# The version is DCAppVersion.current (Packages/DCApp/Sources/DCAppModel/UpdatesVersion.swift); the project's
# MARKETING_VERSION must equal it in every configuration of every target.
# Output: build/release/<version>/DeckCraftNative-<version>.dmg (+ .sha256, RELEASE.txt).
# Xcode's derived data: ~/Library/Caches/DeckCraftNative/xcode-release. Publish with Tools/publish-release.sh.
# Follows ML[X] Image Server's Tools/release.sh.
set -euo pipefail

here=${0:A:h}
root=${here:h}
project="$root/Apps/DeckCraftNative/DeckCraftNative.xcodeproj"
scheme="DeckCraftNative"
app_name="DeckCraftNative.app"
bundle_id="com.xocialize.deckcraftnative"
team=CFZS6RXUCP
derived="$HOME/Library/Caches/DeckCraftNative/xcode-release"

profile=""
allow_dirty=0
while (( $# )); do
  case $1 in
    --notarize) profile=${2:?--notarize needs a notarytool keychain profile name}; shift 2 ;;
    --allow-dirty) allow_dirty=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) print -u2 "release: unknown argument $1"; exit 2 ;;
  esac
done

step() { print -P "%B==> $*%b" }
fail() { print -u2 -P "%F{red}release: $*%f"; exit 1 }

# --- Preflight -------------------------------------------------------------------------------------------------
version=$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' \
  "$root/Packages/DCApp/Sources/DCAppModel/UpdatesVersion.swift")
[[ $version == <->.<->.<->* ]] || fail "can't read DCAppVersion.current (got '$version')."
marketing=(${(f)"$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$project/project.pbxproj" | tr -d '"' | sort -u)"})
build_number=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' "$project/project.pbxproj" | tr -d '"' | sort -u | head -1)
[[ ${#marketing} -eq 1 ]] || fail "the project's configurations disagree on MARKETING_VERSION: ${marketing[*]}"
[[ $marketing == $version ]] || fail "MARKETING_VERSION ($marketing) ≠ DCAppVersion.current ($version) — bump both."

# The Developer ID identity of team $team, by its SHA-1 (the keychain holds more than one Developer ID).
id_line=$(security find-identity -v -p codesigning | grep "\"Developer ID Application: .*($team)\"" | head -1 || true)
dev_hash=$(print -r -- "$id_line" | awk '{print $2}')
dev_id=$(print -r -- "$id_line" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p')
[[ -n $dev_hash ]] || fail "no 'Developer ID Application: … ($team)' certificate in the keychain."
if [[ -n $profile ]]; then
  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "notarytool profile '$profile' is missing or invalid — run: xcrun notarytool store-credentials $profile …"
fi
dirty=no
if [[ -n $(git -C "$root" status --porcelain) ]]; then
  dirty=yes
  if [[ -n $profile && $allow_dirty -eq 0 ]]; then fail "uncommitted changes — commit first, or pass --allow-dirty."; fi
  print -P "%F{yellow}release: building from a tree with uncommitted changes%f"
fi

out="$root/build/release/$version"
archive="$out/DeckCraftNative.xcarchive"
rm -rf "$out"
mkdir -p "$out" "$derived"
commit=$(git -C "$root" rev-parse --short HEAD)
step "DeckCraftNative $version ($build_number) at $commit$([[ $dirty == yes ]] && print ' (dirty)') → $out"

# --- Archive + export ------------------------------------------------------------------------------------------
step "Resolving packages"
xcodebuild -resolvePackageDependencies -project "$project" -scheme "$scheme" -derivedDataPath "$derived" -quiet
# The bundle's licence texts must match what it ships (Tools/acknowledgements.sh).
DC_CHECKOUTS="$derived/SourcePackages/checkouts" "$root/Tools/acknowledgements.sh" --check \
  || fail "Acknowledgements.txt is out of date: run Tools/acknowledgements.sh and rebuild"
# The bundled fonts (Contents/Resources/fonts) come from craft-fonts beside this repository.
[[ -f $root/../craft-fonts/fonts/manifest.txt ]] || fail "no ../craft-fonts/fonts: the app would ship without its fonts"

# The project signs ad hoc for local builds; a release signs with the Developer ID, hardened runtime and a secure
# timestamp. Apple silicon only: ARCHS on the command line reaches the Swift package targets too.
sign_settings=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$dev_id" DEVELOPMENT_TEAM=$team
  ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp" ARCHS=arm64)
# The app icon is Apps/DeckCraftNative/App/Assets.xcassets; until the project names it, name it here.
grep -q 'ASSETCATALOG_COMPILER_APPICON_NAME' "$project/project.pbxproj" \
  || sign_settings+=(ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon)

step "Archiving (Release)"
if ! xcodebuild archive -project "$project" -scheme "$scheme" -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" -archivePath "$archive" $sign_settings > "$out/archive.log" 2>&1; then
  grep -E 'error:|\*\* ARCHIVE FAILED' "$out/archive.log" | head -40 >&2 || tail -40 "$out/archive.log" >&2
  fail "the archive failed — log: $out/archive.log"
fi
warnings=$(grep -E '(^|: )warning: ' "$out/archive.log" | sort -u || true)
if [[ -n $warnings ]]; then
  print -P "%F{yellow}release: the archive has $(print -r -- "$warnings" | wc -l | tr -d ' ') warning(s):%f"
  print -r -- "$warnings" | head -20
fi

export_dir="$out/export"
mkdir -p "$export_dir"
step "Exporting with $dev_id"
cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$out/ExportOptions.plist" -quiet
app="$export_dir/$app_name"
[[ -d $app ]] || fail "the export has no $app_name."

# --- Verify ----------------------------------------------------------------------------------------------------
step "Verifying"
plist="$app/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") == $version ]] || fail "bundle version mismatch"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist") == $bundle_id ]] || fail "bundle id mismatch"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$plist" >/dev/null 2>&1 || fail "the app has no icon (CFBundleIconName)."

# Every piece of code in the bundle: the main executable, nested bundles (app extensions, frameworks, XPC services,
# helpers) and loose Mach-O files, innermost first.
nested=()
for b in "$app"/Contents/{PlugIns,Extensions,Frameworks,XPCServices,Library/LoginItems,Helpers}/*(N); do nested+=("$b"); done
for f in "$app"/Contents/**/*(.N); do
  [[ $(file -b "$f") == Mach-O* ]] && nested+=("$f")
done
nested=(${(u)nested})
check_code() {   # $1 = bundle or Mach-O file
  local info authority
  codesign --verify --deep --strict "$1" || fail "${1#$export_dir/}: signature does not verify."
  info=$(codesign -dvv "$1" 2>&1)
  authority=$(print -r -- "$info" | sed -n 's/^Authority=//p' | head -1)
  [[ $authority == $dev_id ]] || fail "${1#$export_dir/} is signed by '$authority', not '$dev_id'."
  print -r -- "$info" | grep -q '^Timestamp=' || fail "${1#$export_dir/} has no secure timestamp."
  print -r -- "$info" | grep -q 'flags=.*runtime' || fail "${1#$export_dir/} lacks the hardened runtime."
  if codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -q 'get-task-allow'; then
    fail "${1#$export_dir/} carries get-task-allow (notarization would reject it)."
  fi
  print "    ok  ${1#$export_dir/}"
}
for n in $nested; do check_code "$n"; done
check_code "$app"
print "    signed by: $dev_id"

# --- Notarize --------------------------------------------------------------------------------------------------
submissions=()
notarize() {   # $1 = file to submit
  local result id status_
  result=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --timeout 1h --output-format json) || true
  id=$(print -r -- "$result" | plutil -extract id raw -o - - 2>/dev/null || true)
  status_=$(print -r -- "$result" | plutil -extract status raw -o - - 2>/dev/null || true)
  if [[ $status_ != Accepted ]]; then
    [[ -n $id ]] && { xcrun notarytool log "$id" --keychain-profile "$profile" "$out/notary-$id.json" || true; }
    print -u2 -r -- "$result"
    fail "notarization of ${1:t} ended '${status_:-unknown}'${id:+ — log: $out/notary-$id.json}"
  fi
  xcrun notarytool log "$id" --keychain-profile "$profile" "$out/notary-$id.json" >/dev/null 2>&1 || true
  submissions+=("${1:t} $id")
  print "    accepted: $id"
}
if [[ -n $profile ]]; then
  # The app itself carries a ticket, so the copy dragged to /Applications passes Gatekeeper offline.
  step "Notarizing the app"
  ditto -c -k --keepParent "$app" "$out/app.zip"
  notarize "$out/app.zip"
  xcrun stapler staple -q "$app"
  rm "$out/app.zip"
fi

# --- DMG -------------------------------------------------------------------------------------------------------
suffix=""
[[ -n $profile ]] || suffix="-unnotarized"
dmg="$out/DeckCraftNative-$version$suffix.dmg"
step "Building ${dmg:t}"
stage="$out/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/$app_name"
ln -s /Applications "$stage/Applications"
# `create -srcfolder`, as ML[X] Image Server does. Not deckcraft's `makehybrid -hfs`: that gives every file a
# com.apple.FinderInfo attribute, and an app copied off such a volume fails `codesign --verify --strict`.
hdiutil create -quiet -volname "DeckCraftNative" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg"
rm -rf "$stage"
codesign --sign "$dev_hash" --timestamp "$dmg"
codesign --verify --strict "$dmg" || fail "the DMG's signature does not verify."
# The app as people get it: on the mounted volume, and copied off it.
mount_point=$(hdiutil attach -nobrowse -readonly -noautoopen "$dmg" 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
[[ -d $mount_point/$app_name ]] || fail "the DMG doesn't mount with $app_name in it."
copy_dir=$(mktemp -d "${TMPDIR:-/tmp}/deckcraftnative-release.XXXXXX")
ok_on_dmg=1
codesign --verify --deep --strict "$mount_point/$app_name" || ok_on_dmg=0
ditto "$mount_point/$app_name" "$copy_dir/$app_name" && { codesign --verify --deep --strict "$copy_dir/$app_name" || ok_on_dmg=0; }
[[ -L $mount_point/Applications ]] || ok_on_dmg=0
hdiutil detach -quiet "$mount_point" || true
rm -rf "$copy_dir"
(( ok_on_dmg )) || fail "the app on the DMG (or copied off it) doesn't verify strictly, or the Applications link is missing."
print "    ok  the app on the DMG and copied off it; Applications link present"

if [[ -n $profile ]]; then
  step "Notarizing the DMG"
  notarize "$dmg"
  xcrun stapler staple -q "$dmg"
  step "Gatekeeper"
  xcrun stapler validate "$dmg"
  xcrun stapler validate "$app"
  spctl -a -vv --type open --context context:primary-signature "$dmg"
  spctl -a -vv "$app"
  for n in $nested; do
    [[ -d $n && $n == *.appex ]] && spctl -a -vv --type execute "$n" 2>&1 | sed 's/^/    /' || true
  done
fi

(cd "$out" && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256" && cat "${dmg:t}.sha256")   # bare name: `shasum -c` works anywhere
{
  print "version: $version ($build_number)"
  print "commit: $commit"
  print "dirty: $dirty"
  print "signed by: $dev_id"
  print "notarized: $([[ -n $profile ]] && print yes || print no)"
  for s in $submissions; do print "notarization: $s"; done
  print "dmg: ${dmg:t}"
  print "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$out/RELEASE.txt"
step "Done: $dmg"
[[ -n $profile ]] || print "    Not notarized. For a distributable build: Tools/release.sh --notarize mlx-notary"

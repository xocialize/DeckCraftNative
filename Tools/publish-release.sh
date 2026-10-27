#!/bin/zsh
# Publishes a notarized build from Tools/release.sh as a GitHub release of the public repo that
# Help › Check for Updates… reads (UpdateSource.releasesRepo, this repository, xocialize/DeckCraftNative):
#   tag v<version> at the build's commit → push the tag to origin → `gh release create` with the DMG, its .sha256
#   and Docs/releases/<version>.md as the notes.
#
#   Tools/publish-release.sh --dry-run [version]   check everything and print what would be done; change nothing
#   Tools/publish-release.sh [version]              publish (the user runs this, never an agent on its own)
#   Tools/publish-release.sh --draft …              create the release as a draft (publish it on GitHub)
#   default version: DCAppVersion.current
#
# Refuses: a build that isn't notarized and stapled, a build from a dirty tree, a checksum that doesn't match,
# missing release notes, a releases repo that doesn't exist (this script never creates it), an existing tag that
# points at another commit, or an existing release. Only versions with a pre-release suffix (`0.2.0-rc.1`) are
# marked pre-release: the update check never offers pre-releases, so a 0.x release must not be one.
# Follows ML[X] Image Server's Tools/publish-release.sh.
set -euo pipefail

here=${0:A:h}
root=${here:h}
releases_repo=$(sed -n 's/.*public static let releasesRepo = "\(.*\)".*/\1/p' \
  "$root/Packages/DCApp/Sources/DCAppModel/UpdatesFeed.swift")
dry=0
draft=()
version=""
while (( $# )); do
  case $1 in
    --dry-run|-n) dry=1; shift ;;
    --draft) draft=(--draft); shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) print -u2 "publish: unknown argument $1"; exit 2 ;;
    *) version=$1; shift ;;
  esac
done
fail() { print -u2 -P "%F{red}publish: $*%f"; exit 1 }
note() { print -P "%B==> $*%b" }
# Runs a command that changes something, or prints it in a dry run.
act() {
  if (( dry )); then print -r -- "    would run: ${(q-)@}"; else "$@"; fi
}

[[ -n $releases_repo ]] || fail "can't read UpdateSource.releasesRepo."
[[ -n $version ]] || version=$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' \
  "$root/Packages/DCApp/Sources/DCAppModel/UpdatesVersion.swift")
out="$root/build/release/$version"
dmg_name="DeckCraftNative-$version.dmg"
notes="$root/Docs/releases/$version.md"
info="$out/RELEASE.txt"
(( dry )) && note "Dry run: nothing is tagged, pushed or published."

# --- The build -------------------------------------------------------------------------------------------------
[[ -f $info ]] || fail "no build at $out — run Tools/release.sh --notarize mlx-notary first."
grep -qx 'notarized: yes' "$info" || fail "the build at $out is not notarized."
[[ -f $out/$dmg_name ]] || fail "missing $out/$dmg_name"
(cd "$out" && shasum -a 256 -c "$dmg_name.sha256" >/dev/null) || fail "$dmg_name does not match its .sha256"
xcrun stapler validate -q "$out/$dmg_name" || fail "$dmg_name has no stapled ticket."
spctl -a -t open --context context:primary-signature "$out/$dmg_name" 2>/dev/null || fail "Gatekeeper rejects $dmg_name."
if grep -qx 'dirty: yes' "$info"; then
  if (( dry )); then
    print -P "%F{yellow}publish: the build at $out comes from a dirty tree; a real run refuses it (commit, then rebuild).%f"
  else
    fail "the build at $out comes from a tree with uncommitted changes — commit, then rebuild."
  fi
fi
[[ -f $notes ]] || {
  if (( dry )); then print -P "%F{yellow}publish: no release notes yet; a real run refuses: write Docs/releases/$version.md%f"
  else fail "write the release notes first: Docs/releases/$version.md"; fi
}
commit=$(sed -n 's/^commit: //p' "$info")
commit=$(git -C "$root" rev-parse --verify "$commit^{commit}") || fail "build commit $commit is not in this repository."
note "DeckCraftNative $version: $dmg_name, built from ${commit[1,7]}"

# --- The releases repo (never created here) ---------------------------------------------------------------------
tag="v$version"
if command -v gh >/dev/null; then
  if gh repo view "$releases_repo" --json visibility -q .visibility >/dev/null 2>&1; then
    visibility=$(gh repo view "$releases_repo" --json visibility -q .visibility)
    [[ $visibility == PUBLIC ]] || fail "$releases_repo is $visibility; the update check reads a PUBLIC repo."
    if gh release view "$tag" --repo "$releases_repo" >/dev/null 2>&1; then fail "$releases_repo already has a release $tag."; fi
  elif (( dry )); then
    print -P "%F{yellow}publish: $releases_repo doesn't exist (or gh can't see it); a real run refuses. Creating it needs the user's yes.%f"
  else
    fail "$releases_repo doesn't exist. Creating the public repo needs the user's explicit yes; this script never does."
  fi
else
  (( dry )) || fail "the GitHub CLI (gh) is needed."
  print -P "%F{yellow}publish: gh is not installed; a real run needs it.%f"
fi

# --- Tag, push, release ----------------------------------------------------------------------------------------
if existing=$(git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}"); then
  [[ $existing == $commit ]] || fail "tag $tag points at ${existing[1,7]}, but the DMG was built from ${commit[1,7]}."
else
  act git -C "$root" tag -a "$tag" "$commit" -m "DeckCraftNative $version"
fi
act git -C "$root" push -q origin "refs/tags/$tag"

prerelease=()
[[ $version == *-* ]] && prerelease=(--prerelease)
# The releases repo holds no code: the tag is made there, on its default branch.
act gh release create "$tag" "$out/$dmg_name" "$out/$dmg_name.sha256" --repo "$releases_repo" \
  --title "DeckCraftNative $version" --notes-file "$notes" $prerelease $draft
if (( dry )); then
  note "Dry run done. Published, the update check would offer $version from https://github.com/$releases_repo/releases/tag/$tag"
else
  note "Published $tag (${commit[1,7]}): https://github.com/$releases_repo/releases/tag/$tag"
fi

#!/bin/zsh
# Regenerates every Types.generated.swift from the pinned deckcraft checkout (Tools/oracle/pin.env).
# Run it after moving the pin, then build: the compiler lists any hand-written piece a new type needs
# (`static var default` for a manual `impl Default`, a custom `skip_serializing_if` predicate).
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
: ${DECKCRAFT_SRC:=${repo:h}/deckcraft}
# serde2swift.py lives in CraftNativeKit (moved there with CNCore, 2026-11-01): its checkout beside this repo, else
# the copy SwiftPM fetched.
: ${CRAFTNATIVEKIT:=${repo:h}/CraftNativeKit}
[[ -f $CRAFTNATIVEKIT/Tools/port/serde2swift.py ]] || CRAFTNATIVEKIT=$repo/.build/checkouts/CraftNativeKit
# The port's own model fields (deliberate divergences: DCModel PORT-NOTES) are patches over the pinned sources in
# divergence/, applied to a copy; the pinned checkout is never changed. A patch that no longer applies after a pin
# move stops the script.
work=$(mktemp -d)
trap 'rm -rf $work' EXIT
mkdir -p $work/crates/model
cp -R $DECKCRAFT_SRC/crates/model/src $work/crates/model/
for p in $here/divergence/model-*.patch(N); do
  patch -s -p1 -d $work --no-backup-if-mismatch < $p
done
M=$work/crates/model/src
python3 -I $CRAFTNATIVEKIT/Tools/port/serde2swift.py $repo/Packages/DCModel/Sources/DCModel/Types.generated.swift \
  --module DCModel \
  --header "deckcraft crates/model at the pin in Tools/oracle/pin.env (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), with Tools/port/divergence/model-*.patch." \
  --import DCColor --import DCGeometry \
  $M/lib.rs $M/style.rs $M/text.rs $M/theme.rs $M/table.rs $M/anim.rs $M/chart.rs
print "generate: DCModel/Types.generated.swift"

#!/bin/zsh
# Regenerates every Types.generated.swift from the pinned deckcraft checkout (Tools/oracle/pin.env).
# Run it after moving the pin, then build: the compiler lists any hand-written piece a new type needs
# (`static var default` for a manual `impl Default`, a custom `skip_serializing_if` predicate).
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
: ${DECKCRAFT_SRC:=${repo:h}/deckcraft}
M=$DECKCRAFT_SRC/crates/model/src
python3 -I $here/serde2swift.py $repo/Packages/DCModel/Sources/DCModel/Types.generated.swift \
  --module DCModel \
  --header "deckcraft crates/model at the pin in Tools/oracle/pin.env (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors)." \
  --import DCColor --import DCGeometry \
  $M/lib.rs $M/style.rs $M/text.rs $M/theme.rs $M/table.rs $M/anim.rs $M/chart.rs
print "generate: DCModel/Types.generated.swift"

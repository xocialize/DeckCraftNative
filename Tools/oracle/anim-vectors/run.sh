#!/bin/zsh
# Build anim-vectors against the pinned deckcraft (../pin.env) and write DeckCraftNative-Fixtures/anim/:
# deckcraft-anim's timelines, show state machine, transition layers and meshes, Morph frames, motion paths and
# easing, and deckcraft-render's transition compositor, over the oracle corpus decks and generated cases.
# DCAnimTests' AnimVectorTests and DCRenderTests' CompositeVectorTests compare DCAnim and DCRender with them.
#
# Environment (defaults in brackets): DECKCRAFT_SRC [../deckcraft beside this repo], CRAFT_FONTS_DIR
# [../craft-fonts], DECKCRAFT_FIXTURES [../DeckCraftNative-Fixtures], CARGO_TARGET_DIR
# [~/Library/Caches/DeckCraftNative/cargo-target].
set -euo pipefail

here=${0:A:h}
repo=${here:h:h:h}
research=${repo:h}
source "$here/../pin.env"

: ${DECKCRAFT_SRC:=$research/deckcraft}
: ${CRAFT_FONTS_DIR:=$research/craft-fonts}
: ${DECKCRAFT_FIXTURES:=$research/DeckCraftNative-Fixtures}
: ${CARGO_TARGET_DIR:=$HOME/Library/Caches/DeckCraftNative/cargo-target}
export CRAFT_FONTS_DIR CARGO_TARGET_DIR
# deckcraft-render pulls in deckcraft-fonts: build it as the oracle is built, with craft-fonts compiled in.
export CRAFT_FONTS_REQUIRED=1
[[ -d /opt/homebrew/opt/rustup/bin ]] && path=(/opt/homebrew/opt/rustup/bin $path)

die() { print -u2 "anim-vectors: $*"; exit 1 }
[[ $(git -C $DECKCRAFT_SRC rev-parse HEAD) == $DECKCRAFT_COMMIT ]] || die "deckcraft is not at the pin ${DECKCRAFT_COMMIT[1,8]}"
[[ $(git -C $CRAFT_FONTS_DIR rev-parse HEAD) == $CRAFT_FONTS_COMMIT ]] || die "craft-fonts is not at the pin ${CRAFT_FONTS_COMMIT[1,8]}"
decks=$DECKCRAFT_FIXTURES/oracle/${DECKCRAFT_COMMIT[1,8]}/decks
[[ -d $decks ]] || die "no corpus at $decks: run Tools/oracle/oracle.sh corpus"

(cd $here && cargo build --release)
out=$DECKCRAFT_FIXTURES/anim
$CARGO_TARGET_DIR/release/anim-vectors $decks $out
print -r -- "deckcraft $DECKCRAFT_COMMIT
$(rustc --version)" > $out/pin.txt

# Frames of every transition kind, drawn by the pinned deckcraft-cli from engine-scripts/transitions.cmds'
# deck (`oracle.sh engine-vectors transitions` writes it), for DCRenderTests' TransitionParityTests: two
# times each, 640 px wide.
deck=$DECKCRAFT_FIXTURES/engine/transitions.deckcraft
if [[ -f $deck ]]; then
  cli=$($here/../oracle.sh path)
  frames=$out/transitions
  rm -rf $frames && mkdir -p $frames
  n=$($cli info $deck | jq '.slides | length')
  for (( i = 1; i < n; i++ )); do
    $cli render-transition $deck --slide $i --t 0.35,0.65 --width 640 $frames/slide-$((i + 1)).png > /dev/null
  done
  shasum -a 256 $deck | cut -d' ' -f1 > $frames/deck.sha256
else
  print -u2 "anim-vectors: no $deck (run Tools/oracle/oracle.sh engine-vectors transitions): transition frames not drawn"
fi

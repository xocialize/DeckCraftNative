#!/bin/zsh
# Build text-vectors against the pinned deckcraft (../pin.env) and write DeckCraftNative-Fixtures/text/:
# the corpus decks' and a synthetic deck's models (decks/*.json) and their layouts (vectors.json), which
# DCTextTests' OracleParityTests compares with DCText.
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
# CRAFT_FONTS_REQUIRED makes a missing font set a build error instead of a silent system-font build.
export CRAFT_FONTS_REQUIRED=1
[[ -d /opt/homebrew/opt/rustup/bin ]] && path=(/opt/homebrew/opt/rustup/bin $path)

die() { print -u2 "text-vectors: $*"; exit 1 }
[[ $(git -C $DECKCRAFT_SRC rev-parse HEAD) == $DECKCRAFT_COMMIT ]] || die "deckcraft is not at the pin ${DECKCRAFT_COMMIT[1,8]}"
[[ $(git -C $CRAFT_FONTS_DIR rev-parse HEAD) == $CRAFT_FONTS_COMMIT ]] || die "craft-fonts is not at the pin ${CRAFT_FONTS_COMMIT[1,8]}"
decks=$DECKCRAFT_FIXTURES/oracle/${DECKCRAFT_COMMIT[1,8]}/decks
[[ -d $decks ]] || die "no corpus at $decks: run Tools/oracle/oracle.sh corpus"

(cd $here && cargo build --release)
out=$DECKCRAFT_FIXTURES/text
$CARGO_TARGET_DIR/release/text-vectors $decks $out
print -r -- "deckcraft $DECKCRAFT_COMMIT
craft-fonts $CRAFT_FONTS_COMMIT
$(rustc --version)" > $out/pin.txt

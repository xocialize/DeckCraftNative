#!/bin/zsh
# Build media-vectors against the pinned deckcraft (../pin.env) and write DeckCraftNative-Fixtures/media/:
# deckcraft-media's probe_headers, probe, audio::decode and VideoDecoder over media/inputs (written by
# DCMediaTests with DCMEDIA_WRITE_INPUTS=1) and upstream's CC0 media fixtures, and mutations of each
# (cases/*.bin, probe.txt). DCMediaTests' OracleParityTests compares DCMedia with them.
#
# Environment (defaults in brackets): DECKCRAFT_FIXTURES [../DeckCraftNative-Fixtures], CARGO_TARGET_DIR
# [~/Library/Caches/DeckCraftNative/cargo-target]. The deckcraft checkout is ../deckcraft beside this repo.
set -euo pipefail

here=${0:A:h}
repo=${here:h:h:h}
research=${repo:h}
source "$here/../pin.env"

: ${DECKCRAFT_FIXTURES:=$research/DeckCraftNative-Fixtures}
: ${CARGO_TARGET_DIR:=$HOME/Library/Caches/DeckCraftNative/cargo-target}
export CARGO_TARGET_DIR
[[ -d /opt/homebrew/opt/rustup/bin ]] && path=(/opt/homebrew/opt/rustup/bin $path)

die() { print -u2 "media-vectors: $*"; exit 1 }
[[ $(git -C $research/deckcraft rev-parse HEAD) == $DECKCRAFT_COMMIT ]] || die "deckcraft is not at the pin ${DECKCRAFT_COMMIT[1,8]}"
[[ -d $DECKCRAFT_FIXTURES/media/inputs ]] || die "no inputs: DCMEDIA_WRITE_INPUTS=1 swift test --filter FixtureWriterTests"

(cd $here && cargo build --release)
$CARGO_TARGET_DIR/release/media-vectors $DECKCRAFT_FIXTURES
print -r -- "deckcraft $DECKCRAFT_COMMIT
$(rustc --version)" > $DECKCRAFT_FIXTURES/media/pin.txt

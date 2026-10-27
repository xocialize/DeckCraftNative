#!/bin/zsh
# Build display-vectors and write DeckCraftNative-Fixtures/json/display-f64.txt and display-f32.txt:
# Rust's `format!("{}", v)` for json-vectors' inputs (f64.txt, f32.txt; `oracle.sh json-vectors` writes
# them), which DCCoreTests' RustDisplayTests compares with `rustDisplay`. Also `oracle.sh display-vectors`.
#
# Environment (defaults in brackets): DECKCRAFT_FIXTURES [../DeckCraftNative-Fixtures], CARGO_TARGET_DIR
# [~/Library/Caches/DeckCraftNative/cargo-target].
set -euo pipefail

here=${0:A:h}
repo=${here:h:h:h}
research=${repo:h}

: ${DECKCRAFT_FIXTURES:=$research/DeckCraftNative-Fixtures}
: ${CARGO_TARGET_DIR:=$HOME/Library/Caches/DeckCraftNative/cargo-target}
export CARGO_TARGET_DIR
[[ -d /opt/homebrew/opt/rustup/bin ]] && path=(/opt/homebrew/opt/rustup/bin $path)

[[ -f $DECKCRAFT_FIXTURES/json/f64.txt ]] || { print -u2 "display-vectors: no json vectors: run Tools/oracle/oracle.sh json-vectors"; exit 1 }
(cd $here && cargo build --release)
$CARGO_TARGET_DIR/release/display-vectors $DECKCRAFT_FIXTURES/json

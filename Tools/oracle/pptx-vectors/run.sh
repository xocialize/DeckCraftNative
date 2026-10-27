#!/bin/zsh
# Build pptx-vectors against the pinned deckcraft (../pin.env) and write DeckCraftNative-Fixtures/pptx/:
# deckcraft-pptx's xml, opc, cfb, png, maps, custgeom, tables and dgm modules run over the oracle corpus
# and generated inputs (xml.txt, corpus.txt, escape.txt, modules.txt), which DCPPTXTests'
# OracleVectorsTests compares with DCPPTX. Also `oracle.sh pptx-vectors`.
#
# Environment (defaults in brackets): DECKCRAFT_FIXTURES [../DeckCraftNative-Fixtures], CARGO_TARGET_DIR
# [~/Library/Caches/DeckCraftNative/cargo-target]. The deckcraft checkout is ../deckcraft beside this
# repo (Cargo.toml's path dependencies and the #[path] modules point there).
set -euo pipefail

here=${0:A:h}
repo=${here:h:h:h}
research=${repo:h}
source "$here/../pin.env"

: ${DECKCRAFT_FIXTURES:=$research/DeckCraftNative-Fixtures}
: ${CARGO_TARGET_DIR:=$HOME/Library/Caches/DeckCraftNative/cargo-target}
export CARGO_TARGET_DIR
[[ -d /opt/homebrew/opt/rustup/bin ]] && path=(/opt/homebrew/opt/rustup/bin $path)

die() { print -u2 "pptx-vectors: $*"; exit 1 }
[[ $(git -C $research/deckcraft rev-parse HEAD) == $DECKCRAFT_COMMIT ]] || die "deckcraft is not at the pin ${DECKCRAFT_COMMIT[1,8]}"
[[ -d $DECKCRAFT_FIXTURES/oracle/${DECKCRAFT_COMMIT[1,8]}/decks ]] || die "no corpus: run Tools/oracle/oracle.sh corpus"

(cd $here && cargo build --release)
$CARGO_TARGET_DIR/release/pptx-vectors $DECKCRAFT_FIXTURES ${DECKCRAFT_COMMIT[1,8]}
print -r -- "deckcraft $DECKCRAFT_COMMIT
$(rustc --version)" > $DECKCRAFT_FIXTURES/pptx/pin.txt

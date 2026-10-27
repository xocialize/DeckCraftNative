#!/bin/zsh
# The Rust oracle: deckcraft-cli built from the pinned upstream commit (pin.env), and the reference
# corpus it writes into the fixtures (PLAN.md §6).
#
#   oracle.sh build              check both checkouts are clean at the pin, then build deckcraft-cli
#   oracle.sh cli ARGS...        run the pinned deckcraft-cli
#   oracle.sh corpus             regenerate $DECKCRAFT_FIXTURES/oracle/<pin>/ from the sample deck and scripts/*.cmds
#   oracle.sh json-vectors       write serde_json's output for generated floats and strings to $DECKCRAFT_FIXTURES/json/
#   oracle.sh geom-vectors       write deckcraft-geom's preset, warp and Morph output to $DECKCRAFT_FIXTURES/geom/
#   oracle.sh metafile-vectors   write deckcraft-metafile's parse, placement and pixels to $DECKCRAFT_FIXTURES/metafile/
#   oracle.sh text-vectors       write deckcraft-text's layouts of the corpus to $DECKCRAFT_FIXTURES/text/
#   oracle.sh display-vectors    write Rust's `{}` of the json-vectors floats to $DECKCRAFT_FIXTURES/json/display-*.txt
#   oracle.sh pptx-vectors       write deckcraft-pptx's xml, opc and support-module output to $DECKCRAFT_FIXTURES/pptx/
#   oracle.sh path               print the binary's path
#
# Environment (defaults in brackets):
#   DECKCRAFT_SRC       the deckcraft checkout                 [../deckcraft beside this repo]
#   CRAFT_FONTS_DIR     the craft-fonts checkout               [../craft-fonts beside this repo]
#   DECKCRAFT_FIXTURES  the fixtures repository                [../DeckCraftNative-Fixtures]
#   CARGO_TARGET_DIR    cargo's output, on the boot disk       [~/Library/Caches/DeckCraftNative/cargo-target]
set -euo pipefail

here=${0:A:h}
repo=${here:h:h}
research=${repo:h}
source "$here/pin.env"

: ${DECKCRAFT_SRC:=$research/deckcraft}
: ${CRAFT_FONTS_DIR:=$research/craft-fonts}
: ${DECKCRAFT_FIXTURES:=$research/DeckCraftNative-Fixtures}
: ${CARGO_TARGET_DIR:=$HOME/Library/Caches/DeckCraftNative/cargo-target}
export CRAFT_FONTS_DIR CARGO_TARGET_DIR
# Homebrew's rustup is keg-only; its proxies (cargo, rustc) live here.
[[ -d /opt/homebrew/opt/rustup/bin ]] && path=(/opt/homebrew/opt/rustup/bin $path)

bin=$CARGO_TARGET_DIR/release/deckcraft-cli
stamp=$bin.pin
short=${DECKCRAFT_COMMIT[1,8]}

die() { print -u2 "oracle: $*"; exit 1 }

# A checkout counts only when it is at the pinned commit with no local changes.
check_checkout() { # dir commit name
  [[ -d $1/.git ]] || die "$3 checkout not found at $1 (git clone it there, or set the variable)"
  local head=$(git -C $1 rev-parse HEAD)
  [[ $head == $2 ]] || die "$3 is at ${head[1,8]}, the pin is ${2[1,8]}: git -C $1 fetch && git -C $1 checkout $2"
  [[ -z $(git -C $1 status --porcelain --untracked-files=no) ]] || die "$3 has local changes at $1"
}

# The binary counts only when the stamp written by `build` names the pin.
check_binary() {
  [[ -x $bin ]] || die "no deckcraft-cli at $bin: run oracle.sh build"
  [[ -f $stamp && $(<$stamp) == $DECKCRAFT_COMMIT ]] || die "$bin was not built from the pin: run oracle.sh build"
}

cmd_build() {
  check_checkout $DECKCRAFT_SRC $DECKCRAFT_COMMIT deckcraft
  check_checkout $CRAFT_FONTS_DIR $CRAFT_FONTS_COMMIT craft-fonts
  # CRAFT_FONTS_REQUIRED makes a missing font set a build error instead of a silent system-font build.
  (cd $DECKCRAFT_SRC && CRAFT_FONTS_REQUIRED=1 cargo build --release --locked -p deckcraft-cli)
  print -r -- $DECKCRAFT_COMMIT > $stamp
  print "oracle: $bin ($($bin --version), deckcraft ${short}, $(rustc --version))"
}

cli() { check_binary; $bin "$@" }

# Everything the oracle says about one .deckcraft: its info, every slide rendered, the formats it
# converts to, and the .pptx it wrote read back in.
deck_outputs() { # dir name
  local d=$1 n=$2
  $bin info $d/$n.deckcraft > $d/$n.info.json
  $bin render $d/$n.deckcraft --all --scale 2 $d/$n.render > /dev/null
  for ext in pptx pdf md; do $bin convert $d/$n.deckcraft $d/$n.$ext > /dev/null; done
  $bin convert $d/$n.pptx $d/$n.from-pptx.deckcraft > /dev/null
  $bin render $d/$n.from-pptx.deckcraft --all --scale 2 $d/$n.from-pptx.render > /dev/null
  # Three frames of every transition.
  local i
  for i in $(jq -r '.slides[] | select(.transition != null) | .index' $d/$n.info.json); do
    $bin render-transition $d/$n.deckcraft --slide $i --t 0.25,0.5,0.75 $d/$n.transitions/slide-$((i + 1)).png > /dev/null
  done
}

cmd_corpus() {
  check_checkout $DECKCRAFT_SRC $DECKCRAFT_COMMIT deckcraft
  check_binary
  [[ -d $DECKCRAFT_FIXTURES ]] || die "no fixtures repository at $DECKCRAFT_FIXTURES"
  local out=$DECKCRAFT_FIXTURES/oracle/$short
  rm -rf $out && mkdir -p $out/decks

  # The command registry, for the engine's parity in wave 4.
  $bin commands > $out/commands.txt

  # The built-in sample deck, then one deck per script: each non-comment line is one --cmd.
  $bin run --sample --save $out/decks/sample.deckcraft > /dev/null
  local script args line
  for script in $here/scripts/*.cmds(N); do
    args=()
    while IFS= read -r line; do
      [[ -z $line || $line == \#* ]] && continue
      args+=(--cmd $line)
    done < $script
    $bin run $args --save $out/decks/${script:t:r}.deckcraft > /dev/null || die "${script:t} failed"
  done

  local deck
  for deck in $out/decks/*.deckcraft(N); do
    [[ $deck == *.from-pptx.deckcraft ]] && continue
    mkdir -p ${deck:r}.transitions
    deck_outputs ${deck:h} ${deck:t:r}
    rmdir ${deck:r}.transitions 2> /dev/null || true
  done

  jq -n --arg deckcraft $DECKCRAFT_COMMIT --arg date $DECKCRAFT_DATE --arg fonts $CRAFT_FONTS_COMMIT \
    --arg cli "$($bin --version)" --arg rustc "$(rustc --version)" \
    --arg scripts "$(cd $here/scripts && shasum -a 256 *.cmds(N))" \
    '{deckcraft: {commit: $deckcraft, date: $date}, craftFonts: {commit: $fonts}, cli: $cli, rustc: $rustc,
      scripts: ($scripts | split("\n") | map(select(length > 0)))}' > $out/manifest.json
  (cd $out && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS)
  print "oracle: corpus at $out ($(find $out -type f | wc -l | tr -d ' ') files, $(du -sh $out | cut -f1))"
}

# serde_json's float and string output, at the versions deckcraft's Cargo.lock pins, for DCCore's writer tests.
cmd_json_vectors() {
  [[ -d $DECKCRAFT_FIXTURES ]] || die "no fixtures repository at $DECKCRAFT_FIXTURES"
  (cd $here/json-vectors && cargo run -q --release -- $DECKCRAFT_FIXTURES/json)
}

# deckcraft-geom's output, built from the pinned checkout, for DCGeometry's bit-exact parity tests.
cmd_geom_vectors() {
  check_checkout $DECKCRAFT_SRC $DECKCRAFT_COMMIT deckcraft
  [[ -d $DECKCRAFT_FIXTURES ]] || die "no fixtures repository at $DECKCRAFT_FIXTURES"
  (cd $here/geom-vectors && cargo run -q --release -- $DECKCRAFT_FIXTURES/geom)
}

# deckcraft-metafile's output for its test shapes and their mutations, for DCMetafile's bit-exact parity test.
cmd_metafile_vectors() {
  check_checkout $DECKCRAFT_SRC $DECKCRAFT_COMMIT deckcraft
  [[ -d $DECKCRAFT_FIXTURES ]] || die "no fixtures repository at $DECKCRAFT_FIXTURES"
  (cd $here/metafile-vectors && cargo run -q --release -- $DECKCRAFT_FIXTURES/metafile)
}

# deckcraft-text's layouts (lines, runs, glyphs) of the corpus decks, for DCText's parity tests. They depend
# on the fonts installed here.
cmd_text_vectors() {
  $here/text-vectors/run.sh
}

# Rust's float Display (`format!("{}", v)`), for DCCore's `rustDisplay`.
cmd_display_vectors() {
  $here/display-vectors/run.sh
}

# deckcraft-pptx's own modules run over the corpus and generated inputs, for DCPPTX's foundation tests.
# Rerun after `corpus`: corpus.txt covers every corpus package.
cmd_pptx_vectors() {
  $here/pptx-vectors/run.sh
}

case ${1:-} in
  build) cmd_build ;;
  geom-vectors) cmd_geom_vectors ;;
  metafile-vectors) cmd_metafile_vectors ;;
  text-vectors) cmd_text_vectors ;;
  display-vectors) cmd_display_vectors ;;
  pptx-vectors) cmd_pptx_vectors ;;
  json-vectors) cmd_json_vectors ;;
  cli) shift; cli "$@" ;;
  corpus) cmd_corpus ;;
  path) print -r -- $bin ;;
  *) sed -n '2,17p' $0 | sed 's/^# \{0,1\}//'; exit 64 ;;
esac

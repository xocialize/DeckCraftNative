#!/bin/zsh
# Copies the hand-test scenario's fixtures from DeckCraftNative-Fixtures into ./fixtures (gitignored: test data stays
# out of this repo's history, README "DECKCRAFT_FIXTURES"). Run it before every scenario run: the save rows write to
# their own copies (save-roundtrip.*), and this puts them back.
#
#   Docs/hand-test/make-fixtures.sh            # finds ../DeckCraftNative-Fixtures beside the repo
#   DECKCRAFT_FIXTURES=/path Docs/hand-test/make-fixtures.sh
#
# Every file here is deckcraft's own output, or a conversion or encryption of it by LibreOffice, Apache POI or
# msoffcrypto-tool (DeckCraftNative-Fixtures/legacy/manifest.json). None is PowerPoint-saved.
set -e
HERE=${0:A:h}
REPO=${HERE:h:h}
SRC=${DECKCRAFT_FIXTURES:-${REPO:h}/DeckCraftNative-Fixtures}
PIN=$(sed -n 's/^DECKCRAFT_COMMIT=\(........\).*/\1/p' $REPO/Tools/oracle/pin.env)
DECKS=$SRC/oracle/$PIN/decks
LEGACY=$SRC/legacy
[[ -d $DECKS && -d $LEGACY ]] || { echo "no fixtures at $SRC (oracle/$PIN, legacy): set DECKCRAFT_FIXTURES"; exit 1 }

OUT=$HERE/fixtures
rm -rf $OUT
mkdir -p $OUT
# deckcraft's sample deck (8 slides in three sections), as .deckcraft and as the .pptx deckcraft-cli writes.
cp $DECKS/sample.deckcraft $DECKS/sample.pptx $OUT/
cp $DECKS/sample.deckcraft $OUT/save-roundtrip.deckcraft
cp $DECKS/sample.pptx $OUT/save-roundtrip.pptx
# A PowerPoint 97–2003 file: LibreOffice's conversion of the sample deck.
cp $LEGACY/ppt/corpus-sample.ppt $OUT/
# Password-protected, by Apache POI: "Password1" (review, 5 slides), "Tëst-pässwörd" (content), and a .ppt under
# PowerPoint's default password, which opens without asking.
cp $LEGACY/encrypted/corpus-review.poi-agile-aes128-sha1.pptx $OUT/protected-ascii.pptx
cp $LEGACY/encrypted/corpus-content.poi-agile-aes128-sha1.pptx $OUT/protected-accents.pptx
cp $LEGACY/encrypted/corpus-sample.poi-rc4cryptoapi-default.ppt $OUT/protected-default.ppt
# A damaged .ppt: the sample's, cut off after 5,463 bytes.
cp $LEGACY/hostile/corpus-sample.trunc-5463.ppt $OUT/damaged.ppt
ls $OUT

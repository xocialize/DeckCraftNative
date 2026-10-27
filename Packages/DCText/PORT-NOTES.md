# DCText port notes

DCText is deckcraft's `crates/fonts` and `crates/text` (pin `27009cd9`, `Tools/oracle/pin.env`) on
CoreText. deckcraft's layout engine is ported line for line: run styles through `Resolve`, font slots and
the cascade, bidi, items, line breaking, bullets and numbering, indents, tabs, spacing, alignment with
kashida, columns, anchoring, vertical text, autofit, decorations, fields and the caret model. CoreText
takes HarfRust's place for shaping, and skrifa's place for font data (with the OpenType tables parsed
here). The Unicode data deckcraft reads through crates is generated from those crates, so bidi classes
and line-break opportunities are deckcraft's to the code point.

## Files

| File | Port of | What |
|---|---|---|
| `TextTypes.swift` | text `lib.rs` (public types) | `PositionedGlyph`, `GlyphRun`, `RunEffects`, `TextShadow`, `DecoDash`, `DecoLine`, `Deco` (`pieces()`, `wave()`), `LineInfo`, `TextLayout`, `TextFields`/`NoFields`, `TextOpts`, `Affinity`, `MoveMode`, `CaretPos` (deckcraft's `Pos`) |
| `TextLayoutEngine.swift` | text `lib.rs` `layout`, `layout_scaled`, `merge_decos`, `kashida_opportunities`, `fit_height`, `fit_width` | the layout pass, autofit search, columns, anchoring, run and decoration emission |
| `Paragraph.swift` | text `lib.rs` `make_style` … `tab_advance` | styles, face chains, shaping into cells, `measure_str`, break opportunities, line breaking, tabs |
| `Caret.swift` | text `lib.rs` `impl LineInfo`, `impl TextLayout` | carets with affinity, hit testing, logical/visual movement, selection, composition underlines, `LineInfo.span`/`spans` |
| `Autonum.swift` | text `lib.rs` `autonum` and numerals | |
| `Symbols.swift` | text `lib.rs` `symbol_*`, `map_symbol_bullet` | symbol fonts, Adobe Symbol encoding, bullet look-alikes |
| `DateTime.swift` | text `datetime.rs` | `DateTime`, `DateFields.fieldText`/`shortDate`/`isDateField`/`dateKinds` (Gregorian validity and weekday computed here; chrono isn't available) |
| `Bidi.swift` | text `bidi.rs` | `levels_lang` (PowerPoint's run-language rules), L1, L2 |
| `UnicodeProps.swift`, `UnicodeTables.generated.swift` | unicode-bidi 0.3.18, unicode-linebreak 0.1.5 | Bidi_Class ranges (1505), the UAX #14 trie and pair table; `Scripts/gen-unicode-tables.py` writes them from the cargo registry |
| `Script.swift` | fonts `script.rs` | scripts, slots, joining classes |
| `Shaper.swift` | fonts `shape.rs`, `shape` in `lib.rs` | CoreText shaping in HarfRust's terms (below). Public: `ShapedGlyph`, `Shaper.shape(face, text)` (deckcraft's `shape(face, text, &[], \|c\| c)`), `Shaper.shapeLogical`, and the per-item `Shaper.shape(face, scalars, rtl:kern:ligatures:lang:script:)`. Clusters are scalar indices, where deckcraft's are byte offsets |
| `FontFace.swift`, `SFNT.swift` | fonts `fontdb.rs` (`FontFace`, `make_face`) | metrics as skrifa reads them, names (`english_or_first`), GDEF mark classes, fvar instances |
| `FontDB.swift`, `Fallback.swift` | fonts `fontdb.rs`, `fallback.rs` | craft-fonts manifests, installed families, substitutes, Office twins, Calibri for missing fonts, per-cluster fallback |
| `EmbeddedFont.swift` | fonts `embedded_sfnt` | the font in an embedded-font part (EOT unwrapped) |

## Shaping: CoreText in HarfRust's terms

An item (one face, level, script, language, caps and kerning setting) is laid out with a `CTTypesetter`.
The typesetter's embedding level is forced to the item's direction. Kerning is turned off unless the run
asks for it (`kCTKernAttributeName` 0). Ligatures are turned off for Latin, Greek and Cyrillic without
emoji (`kCTLigatureAttributeName` 0), and the language comes from the run or the script's default. The
face's `emFont` is the font at its em size, so positions are in font units. The glyphs are then rewritten
the way HarfRust reports them:

- **Clusters.** CoreText gives each glyph the index of its character. These are merged to the start of
  the grapheme, then made monotone in the item's direction, which is HarfRust's `MonotoneGraphemes`
  cluster level.
- **Advances and offsets.** CoreText's per-glyph advances are nominal, while GPOS kerning, cursive
  attachment and mark placement show only in positions. So positions are read instead:
  - A mark has no advance and is offset from the pen. HarfRust's default, Arabic, Hebrew and Thai shapers
    zero GDEF marks, so in those scripts any GDEF class 3 glyph counts as a mark.
  - The Indic, Khmer, Myanmar, USE and Hangul shapers keep mark advances, so in those scripts only
    zero-width GDEF marks count (`Shaper.keepsMarkAdvances`).
  - Every other glyph advances to the next spacing glyph's position, and the last one by its own advance.
- **Control characters.** Tabs, line feeds and vertical tabs are shaped as spaces, because CoreText would
  treat them as breaks. The layout draws none of their glyphs.
- **Deleted glyphs.** Glyphs CoreText deletes (0xFFFF, absorbed into a ligature) are dropped.

Measured against HarfRust on the shaping samples in `vectors.json`, the glyph ids are identical for all 8
samples: Inter, Carlito, Montserrat, Noto Sans Arabic ×2, Hebrew, Thai and Devanagari.
- **Clusters.** They match except Thai and Devanagari, before the layout's grapheme merge.
- **Advances.** They match to the unit, except variable Montserrat: 16 991 against 16 986 units over 33
  glyphs.

## Parity (`OracleParityTests`, `Tools/oracle/text-vectors`)

`text-vectors` writes two things to `DeckCraftNative-Fixtures/text/`:
- every corpus deck's model, plus a synthetic deck of 20 bodies, all as `decks/*.json`;
- deckcraft's layout of each of the 122 text bodies (`vectors.json`).

The synthetic deck covers:
- wrapping at three widths;
- bullets and autonumbers;
- autofit overflow;
- Arabic in `ar-SA` and `en-US` runs, and Hebrew with justify;
- Japanese (kinsoku), Chinese and Korean;
- all four tab alignments;
- nine fonts mixed with bold and italic;
- fields;
- alignment and line and paragraph spacing;
- caps, superscript and subscript, underline and strike;
- `eaVert`;
- two columns;
- Thai and Devanagari.

Results on this machine (macOS 27.2, craft-fonts `aced4137`, Office installed):

| Set | Bodies | Line breaks identical | Font scale identical | Lines compared | Baseline Δ max / mean | Extent Δ max / mean | Runs: same family / glyph count |
|---|---|---|---|---|---|---|---|
| Latin corpus (asserted) | 102 | 102 | 102 | 120 | 0.000 / 0.000 pt | 0.000 / 0.000 pt | 138/138 · 138/138 |
| Synthetic (reported) | 20 | 20 | 20 | 148 | 0.000 / 0.000 pt | 0.038 / 0.000 pt | 212/212 · 212/212 |

What the test asserts:
- **Latin corpus.** Identical line breaks, and baselines and extents within **0.5 pt**.
- **Synthetic deck.** Reported only.
- **Shaping vectors.** For the Latin samples, glyph ids, clusters and widths are asserted, within one unit
  per glyph.

The vectors depend on the fonts installed. deckcraft reads installed Calibri and Cambria from Office's
folders when they are there, so regenerate the vectors with `Tools/oracle/text-vectors/run.sh` on the
machine that runs the tests.

## Divergences

1. **Shaper.** The shaper is CoreText, not HarfRust, with the output converted as described above. What
   remains:
   - **Variable fonts.** Advances can differ by a unit: CoreText applies HVAR and gvar its own way.
   - **No context across items.** HarfRust shapes an item with the rest of the paragraph as context;
     CoreText takes none. Arabic joining across an item boundary inside a word is lost: a word changing
     face, level, caps, language or kerning mid-word. Paint-only changes don't split items, so a colour
     change keeps the joining (tested).
   - **Unshaped faces.** deckcraft's fallback for a face it can't shape (one glyph per character from the
     cmap) doesn't exist here: CoreText shapes every face it can open.
2. **Explicit bidi embeddings.** Paragraphs holding LRE, RLE, LRO, RLO, PDF, LRI, RLI, FSI or PDI take
   their levels from a CoreText line (right-to-left runs 1; left-to-right runs 2 in a right-to-left
   paragraph, else 0) rather than from unicode-bidi's full UBA. Deeper nesting levels are flattened. Every
   other paragraph runs deckcraft's `levels_lang` with the exact Unicode tables.
3. **Graphemes.** Graphemes come from Swift's `Character` (the runtime's Unicode version), where deckcraft
   uses unicode-segmentation 1.13.3 (Unicode 16). They differ only on characters assigned after Unicode 16.
4. **Variable instances.** Named instances come from `fvar` and are applied with
   `kCTFontVariationAttribute`. Ascent, descent, underline and strikeout come from the default instance's
   tables; MVAR deltas are not applied, where skrifa applies them at the instance's location.
5. **Last-resort face.** It is Helvetica, where deckcraft uses Ubuntu Light from `epaint_default_fonts`.
   It's reached only when no bundled or installed face draws a cluster.
6. **System font catalog.** It comes from CoreText's family list. Faces load per family on first use and
   only into this process: they are created from descriptors or bytes, never registered.
   - **Office folders.** Office's folders, which CoreText doesn't list, are indexed on first need, as
     deckcraft's macOS scan reads them: `DFonts` in PowerPoint, Word and Excel, and the Office
     `CloudFonts` cache.
   - **Not ported.** deckcraft's Linux and Windows directory scans, fontconfig, FIFO-safe scanning and
     `with_font_dirs`. Their tests are not ported either.
7. **Ligature carets.** They come from `CTFontGetLigatureCaretPositions` (GDEF), not skrifa. They are
   identical where the font has GDEF carets.
8. **Not ported (fonts crate).**
   - `FontDb::outline`: renderers take glyph paths from CoreText (`CTFontCreatePathForGlyph` on
     `FontFace.ctFont(size:)`).
   - The Japanese UI font lists (`japanese_ui_fonts`, `japanese_document_fonts`) and `CraftFont`.
   - `fallback_for_filtered` and `set_system_fallback`: the filtered UI fallback.

## Port bugs found by the ported tests

- **Bidi_Class table.** The first generated table missed every range rustfmt had wrapped across two
  lines: 1087 of 1505 were read. "%" read as L, which broke `45.6%` in Hebrew runs. Fixed in the
  generator.
- **Concurrent family loads.** A family was marked loaded before its faces were in, so a thread asking
  while another loaded it fell back to another family. Loads are now serialised and marked afterwards,
  matching deckcraft's `concurrent_lookups_all_find_an_installed_family`, which is ported.
- **CoreText table tags.** `CTFontCopyAvailableTables` returns raw tags, not objects; bridging the array
  crashed. It is read with `CFArrayGetValueAtIndex`.

## Tests

110 tests in `Tests/DCTextTests`:
- `LayoutTests` (38) and `BidiAndStyleTests` (38), ported from text `tests.rs`. deckcraft's tests that
  need a font this machine lacks return early here too.
- `FontTests` (32): the fonts crate's tests, bidi, script, shaping and date fields.
- `OracleParityTests` (2).

Adaptations:
- `ligaturesStayForScriptsThatNeedThem` checks the (kern, ligatures) pair `shapingFeatures` now returns,
  in place of HarfRust feature lists.
- `craftFontsLatinWhenPresent` builds a database of the bundled faces alone, since an installed Calibri
  or Aptos would win.
- Font fixtures (`legacy-*.ttf`, `colr-squares.ttf`) are read from the deckcraft checkout (`DECKCRAFT_DIR`,
  else the research folder).
- The craft-fonts folder is `CRAFT_FONTS_DIR`, else `../craft-fonts` beside the repository.

Not ported:
- bidi `matches_the_reference_on_random_mixed_text`, which checks against a pre-#403 copy of the
  algorithm;
- the Linux and Windows font-directory tests;
- `faces_without_outlines_are_not_cataloged` (CoreText catalogs).

## Manifest

No change is needed: the target and tests build with the declared dependencies. `OracleParityTests` reads
the model JSON with DCModel's own decoder rather than DCFormat.

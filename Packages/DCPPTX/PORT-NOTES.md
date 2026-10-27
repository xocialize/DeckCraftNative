# DCPPTX — port notes

Port of deckcraft `crates/pptx` at the pin in `Tools/oracle/pin.env` (`27009cd9`). Status: **foundation
done** (Wave 3, part 1). The `read/` and `write/` ports build on it, and they add `PPTX.import`,
`importChecked`, `importTheme`, `export` and `exportAs` as extensions of `PPTX` in their own files.

It has 45 tests:

- every Rust `#[test]` in the foundation files, 33 in all;
- 8 more for quick-xml's behaviour, numbers, the builder, duplicate zip names, rels and content types,
  `mimeFor` and `sniff`;
- 4 oracle tests.

3 of the 45 are disabled. lib.rs's 2 `import_theme_tests` need read/write: their bodies sit behind
`#if PPTX_IMPORT_EXPORT`, so delete that and the `.disabled` trait when `export` and `importTheme`
exist. cfb.rs's `a_password_protected_presentation_is_named_as_such` needs DCEngine (Wave 4).

## What "byte-exact" means here

- **Everything the Rust modules write is byte-identical.** That covers the `W`/`A` builder, `esc`/
  `esc_attr`, `to_xml`, `tableStyles.xml`, the diagram parts, transitions, `a:custGeom`, the rels parts
  and the PNG. Numbers go through DCCore's `RustDisplayable` (`A.a(_:_:)` takes any), which is Rust's
  `{}`: `1.0` is `1`, `-0.0` is `-0`, and there's never an exponent. It matches Rust on 222,470 f64 and
  107,720 f32 values (see DCCore's notes for the one rounding fix that needed).
- **The parser is quick-xml 0.41.0 as xml.rs configures it.** It's hand-written over bytes, because
  Foundation's `XMLParser` is strict and quick-xml isn't. It gives the same tree, the same errors and
  messages, the same attribute splitting and normalisation, and the same entity and character-reference
  handling.
- **The zip around a written package isn't byte-identical.** Entries, names, order and contents match.
  The DEFLATE streams and timestamps don't, and DCZip stores a part when deflating doesn't make it
  smaller, which the zip crate would deflate anyway.

## Oracle

`Tools/oracle/pptx-vectors/run.sh` compiles the pinned crate's own module sources into a tool through
`#[path]`. `build.rs` copies `opc.rs` with `Package::open_within` made `pub`, and nothing else changes.
The tool writes `DECKCRAFT_FIXTURES/pptx/`. `OracleVectorsTests` compares each line, and all of them
match:

| File | Lines | What |
|---|---:|---|
| `xml.txt` | 30,207 | The parser over seeds, fragments, UTF-16, BOMs, the depth limit and 30,000 mutations (11,416 parse, 18,791 fail). Each line holds the tree dump, `to_xml`, and the answers to `attr` (10 names), `i64`/`i32`/`u32`/`f64`/`bool`, `text`, `find`, `findAll`, `local`, `prefix` and `nsDecls` |
| `corpus.txt` | 458 parts | Every part of the 9 corpus `.pptx` files through `Package`: bytes, content type, rels, original name. For XML parts, the tree and `to_xml` |
| `escape.txt` | 3,134 | `esc` and `esc_attr` over every ASCII character, U+FFFE/U+FFFF and random strings |
| `modules.txt` | 60,697 | opc path functions (`norm`, `dirOf`, `fileOf`, `relsPath`, `sidecarPart`, `resolve`, `relative`); rels parts; 200 packages under small budgets, with duplicate names, directories, stored and deflated entries and corrupted data; 400 hostile compound files; the PNG; transitions both ways; every subtype, preset and `presetFor`; 6,000 guide formulas; 1,500 generated `a:custGeom` read and re-written; `parsePath`; table style GUIDs and `tableStyles.xml`; dgm ids, `kindFor`, the layout, style and colour parts, 500 data models and their outlines |

For `to_xml` round trips: every XML part of the corpus that deckcraft parses, Swift parses to the same
tree, and `toXML()` gives Rust's bytes.

## File map

| Rust | Swift | Notes |
|---|---|---|
| `lib.rs` | `PPTX.swift` | `PPTX` (namespace: `sniff`, `isEncrypted`, `sectionExtURI`, `commentsExtURI`), `PPTXError`, `mimeFor`, `PPTXLog` (`log::warn!` → `os.Logger`, subsystem `DeckCraftNative`, category `pptx`). `import`/`export` are left to `read/`/`write/` |
| `xml.rs` | `XML.swift` | `XMLNode`, `XMLEl`, `XMLElements`, `XMLDoc`, `parseXML`; `XML` (constants, parser, `toXML`, escapes); `W`, `A`; the byte-wise string helpers |
| `opc.rs` | `OPC.swift` | `OPC` (constants and free functions), `Package`, `Rel`, `Rels`, `RelsOut`, `PackageOut`, `ByteKey` |
| `cfb.rs` | `CFB.swift` | `CFB.isEncrypted`, `CFB.directoryNames` |
| `png.rs` | `PNG.swift` | `PNG.transparent1x1` |
| `maps.rs` | `Maps.swift` | `Maps` |
| `custgeom.rs` | `CustGeom.swift` | `CustGeom`, `Guides`, `splitWhitespace` |
| `tables.rs` | `Tables.swift` | `Tables` |
| `dgm.rs` | `Dgm.swift` | `Dgm` |
| tests | `Tests/DCPPTXTests/` | `XMLTests`, `OPCTests` (with `CFBTests` and `PNGTests`), `MapsGeomTablesDgmTests`, `ImportThemeTests` (disabled), `OracleVectorsTests` |

Rust modules become caseless enums (`opc::norm` → `OPC.norm`), and their constants are lowerCamel
(`NS_A` → `OPC.nsA`, `RT_MEDIA` → `OPC.rtMedia`, `MAX_DEPTH` → `XML.maxDepth`).

## API for `read/` and `write/`

Public, because deckcraft re-exports it: `XMLDoc`, `XMLEl`, `XMLNode`, `parseXML`, `PPTX`, `PPTXError`.
Everything else is internal to DCPPTX, as it is `pub(crate)` in Rust. Tests use `@testable import`.

### XML (`xml::`)

- **`parseXML(_ bytes: [UInt8]) throws(PPTXError) -> XMLDoc`.** There's also `parseXML(_: String)`. It's
  the same as `XML.parse(_:)`, which is what `crate::xml::parse` reads as.
- **`XMLDoc`.**
  - `root: XMLEl`.
  - `nsDecls() -> [(key:, value:)]`.
- **`XMLEl`.**
  - Fields: `name`, `attrs: [(key: String, value: String)]` and `children: [XMLNode]`, all `var`, so
    `e.children.retain`-style code ports as `e.children.removeAll { … }`.
  - Equatable byte for byte.
  - Properties:

    | Swift | Rust |
    |---|---|
    | `local: Substring` | `local()` |
    | `prefix: Substring` | `prefix()` |
    | `text: String` | `text()` |
    | `elements: XMLElements` | `elements()` |

  - Methods: `is(_:)`, `attr(_:) -> String?`, `hasAttr`, `setAttr` (mutating), `i64`, `i32`, `u32`,
    `f64`, `bool`, `child`, `childrenNamed(_:) -> XMLElements`, `path(_: [String])`, `path(_:
    String...)`, `find`, `findAll(_:) -> [XMLEl]`, `findAll(_:into:)`, `childVal`, `toXML()`.
  - `elementsMut { (inout XMLEl) in … }` stands in for `elements_mut()`.
  - `e.is("sp")` needs no backticks at the call site.
  - Semantics are the Rust ones, including `str::parse` (a leading `+` is fine for integers, `1.` and
    `.5` are fine for floats, hex and `nan(…)` are not), `trim` (Unicode whitespace), and the
    `xmlns`-skipping and `r:id` lookup rules.
- **`XMLNode`.** `.el(XMLEl)` or `.text(String)`.
- **`XMLElements`.** A `Sequence` of `XMLEl`. Use `.prefix(n)` for `.take(n)` and `Array(…)` to index.
- **`XML`.**
  - `maxDepth` (256) and `maxNodes` (4,000,000).
  - `esc(_:)` and `escAttr(_:)`.
  - `parse(_:)`.
  - `lineEnds`, `parseNumber` and `decodeUTF16`, the internals.
- **`A`.**
  - `A()` (or `A.new()`).
  - `.a(k, v)`, where `v` is any `RustDisplayable` (String, Substring, every integer type, Double,
    Float, Bool, Character).
  - `.o(k, v?)`, `.b(k, Bool?)` (`1`/`0`) and `.t(k, Bool)` (only when true).
  - It's a value. Chain it, or `a = a.a(…)`.
- **`W`.**
  - `W.new()` starts with the declaration and a newline. `W.frag()` and `W()` start empty, as Rust's
    `W::default()` does.
  - `s: String`.
  - `open`, `open0`, `close`, `empty`, `empty0`, `val(name, v)`, `text`, `elt`, `raw`, and
    `finish() -> [UInt8]`.
  - Pass it `inout` where Rust passes `&mut W`.
- **String helpers.** These are Rust's semantics. Use them wherever the Rust compares or slices
  strings, because Swift's `==` and `hasPrefix` work on canonical equivalence:
  - `bytesEqual(a, b)` is `==`.
  - `hasBytePrefix` and `hasByteSuffix` are `starts_with` and `ends_with`.
  - `eqIgnoreASCIICase` is `eq_ignore_ascii_case`.
  - `rustParseUnsigned(_:as:)` is `parse::<u8/u32…>`.
  - `splitWhitespace` is `split_whitespace`.
  - `localOf`.
  - DCCore has the rest: `rustTrim`, `rustParseF64`, `rustASCIILowercase`, `rustHex`, `rustDisplay`,
    `rustSignum`.

### OPC (`opc::`)

- **`OPC` limits.** `maxPart`, `maxXMLPart`, `maxTotal`, `maxInflateWork` and `maxEntries`.
- **`OPC` constants.** `nsA`, `nsR`, `nsP`, `nsC`, `nsMC`, `nsP14`, `nsP15`, `nsP159`, `nsA14`,
  `nsP188`, `rtBase`, `rtMedia`, `rtModel3D` and `rtCore`.
- **`OPC` functions.**
  - `norm`, `sidecarPart`, `dirOf`, `fileOf`, `relsPath`, `resolve(base, target)` and
    `relative(from, to)`.
  - `relsFromBytes(bytes, part) -> Rels`.
  - `relsOf(doc, part)` and `percentDecode`.
- **`Package`.** A `final class`, `Sendable`.
  - `Package.open(bytes) throws(PPTXError)` and `Package.openWithin(bytes, maxPart:, maxTotal:,
    maxWork:)`.
  - `get(_:) -> [UInt8]?`, `xmlBytes`, `xml(_:) -> XMLDoc?`, `rels(_:) -> Rels`, `contentType(_:) ->
    String?` and `originalName(_:)`.
- **`Rel`.** `id`, `kind`, `ty`, `targetRaw`, `target` and `external`.
- **`Rels`.** `items`, `get(id)`, `target(id)`, `firstOf(kind)` and `allOf(kind) -> [Rel]`.
- **`RelsOut`.** `items: [(id:, ty:, target:, external:)]`, `add(kind, target, external) -> String`
  (mutating), `addNew` and `toXML() -> [UInt8]`.
- **`PackageOut`.** `files`, `defaults` and `overrides`, plus `xmlPart(name, ct, data)`, `rels(part,
  relsOut)`, `raw(name, data)`, `binary(name, ct, data)`, `contentTypesXML()` and `finish()
  throws(PPTXError) -> [UInt8]`.

### Everything else

- **`CFB`.** `isEncrypted(bytes)` and `directoryNames(bytes)`.
- **`PNG`.** `transparent1x1()`, `crc32` and `adler32`.
- **`Maps`.**
  - `transitionFromXML(el) -> (kind:, option:)?` and `transitionToXML(&w, kind, option) -> String?`
    (the prefix).
  - `optionFromSubtype(effect, sub)` and `subtypeFromOption(effect, option) -> UInt32?`.
  - `effectForPreset(class, preset) -> String?`, `fallbackEffect(class)` and `presetFor(animation) ->
    UInt32`.
  - The tables `simple`, `subtypes` and `invxLeft`.
- **`CustGeom`.**
  - `readCustGeom(cg, wEMU, hEMU) -> [CustomPath]` and `writeCustGeom(&w, paths)`.
  - `parsePath(d) -> [(Character, [Double])]`.
  - `finite`, `num`, `toRad`, `toAng` and `arcTo`.
- **`Guides`.** `Guides(w, h)`, `get`, `set` (mutating), `eval(fmla)` and `evalList(list)` (mutating).
- **`Tables`.**
  - `guid(text)`, `isOwnGUID`, `styleFromGUID` and `guidForStyle(style) -> (guid:, define:)`.
  - `tableStylesXML(used, defs) -> [UInt8]`.
  - `known` and `builtinWrite`.
- **`Dgm`.**
  - Constants: `nsDGM`, `nsDSP`, `ctData`, `ctLayout`, `ctStyle`, `ctColors`, `ctDrawing` and
    `rtDrawing`.
  - IDs: `qsID`, `styleFor`, `csID`, `colorsFor`, `layoutID` and `kindFor(layoutID, category)`.
  - Parts: `dataXML(diagram, seed, drawingRel, pics) -> [UInt8]`, `outline(data) -> [DiagramNode]`,
    `nodePictures(data) -> [(Int, String)]`, `layoutXML(kind)`, `styleXML(style)` and
    `colorsXML(colors)`.
- **`mimeFor(name)`.**
- **`PPTXLog.warn(_:)`.**

## Divergences from Rust

All of them are in reading damaged zip containers. None touch XML or anything written.

1. **DCZip parses the whole central directory, and every local header, when it opens an archive.** It
   refuses the archive if an entry is encrypted or a header is bad. The zip crate opens such an archive
   and fails only that entry's `by_index`, so deckcraft skips the entry. Here `Package.open` throws
   `.notPptx` and `PPTX.sniff` is false. DCZip can't be changed from this package, so this is left for
   DCZip.
2. **Entry names are always decoded as UTF-8, lossily.** The zip crate decodes a name without the
   UTF-8 flag as CP437. ASCII names, which are all OPC part names in practice, are the same either way.
3. **zip-open errors read differently.** The `.notPptx(…)` messages carry DCZip's wording, not the zip
   crate's.
4. **A DEFLATE stream cut off before its end marker fails to read.** miniz reads such a stream as
   ending there and lets the CRC decide, so deckcraft keeps the part when all its bytes came out before
   the cut. Apple's Compression can't tell a cut-off stream from a malformed one. A stream that fails
   charges the bytes Compression produced before failing to the inflate budget, where miniz charges
   its own count.
5. **Logging goes through `os.Logger`, not the `log` crate.**
6. **`PackageOut.finish`** stores rather than deflates a part when deflating doesn't make it smaller.
   That's a container difference only: the part bytes are equal.

## read/

Port of `crates/pptx/src/read/` (Wave 3, part 2): about 3,550 lines of Swift in seven files, plus 18 tests
ported from the in-file `#[test]`s and the import half of the oracle parity test. `PPTX.import`,
`PPTX.importChecked` and `PPTX.importTheme` are an extension of `PPTX` in `ReadMod.swift`; everything else
is internal, under the caseless enum `PPTXRead`.

### File map

| Rust | Swift | Notes |
|---|---|---|
| `read/mod.rs` | `ReadMod.swift` | `Imp` (a `final class`: Rust passes it `&mut` everywhere), `Part`, `importChecked`, `importTheme`, masters, layouts, slides, notes, comments, sections, custom shows, guides, show settings, notes and handout masters, properties, kept parts, embedded fonts, `inheritPlaceholderGeometry`, `defaultTextAnchor`, `headerFooter`, `resolveMC`, `relRefs`, `keepXML`; and the byte-wise string helpers the reader uses (`bytesLess`, `bytesContains`, `splitByte`, `stripBytePrefix`, `asciiUppercase`, `takeChars`, `remEuclid`, `totalLess`…) |
| `read/dml.rs` | `ReadDML.swift` | Colours, fills, lines, effects, `xfrm`, body/paragraph/run properties, hyperlinks, list styles, text bodies |
| `read/shapes.rs` | `ReadShapes.swift` | `IdCtx` (a `final class`), `spTree`, `sp`/`pic`/`grp`/`cxn`/`frame`, 3-D models, VML previews, SmartArt and its text rectangles, tables |
| `read/chart.rs` | `ReadChart.swift` | `readChartXML`, `chartFromEl` (`chart_from`), `chartWithin`, trendlines, `captureKept` |
| `read/chartex.rs` | `ReadChartEx.swift` | `readChartexXML`, `chartexFrom` |
| `read/theme.rs` | `ReadTheme.swift` | `readTheme` |
| `read/timing.rs` | `ReadTiming.swift` | `transition`, `animations`, `playsAsBuild` |
| in-file tests | `Tests/DCPPTXTests/ReadTests.swift` | `ReadDMLTests` (2), `ReadChartTests` (16) |
| — | `Tests/DCPPTXTests/PPTXImportOracleTests.swift` | Import parity over the 9 corpus decks |

Free functions become static members of `PPTXRead` (`read::rel_refs` → `PPTXRead.relRefs`,
`chart::chart_from` → `PPTXRead.chartFromEl`, as `read::` re-exports it). The writer calls `relRefs`,
`isRelAttr`, `hasRelRefs`, `keepXML`, `resolveMC(_:_:)`, `chartexFrom`, `chartFromEl`, `readChartexXML` and
`readChartXML`, with Rust's parameter and return shapes.

Two chart tests (`minorGridlinesAreReadAndWrittenBack`, `seriesPatternFillsAreReadAndWrittenBack`) write
with `write::chart::chart_xml`: their bodies sit behind `#if PPTX_WRITE` and they're disabled until
`PPTXWrite.chartXML` exists. `CT_COMMENTS_MODERN` is a `fileprivate` copy in `ReadMod.swift`, marked
`TODO(merge)`, until `PPTXWrite.ctCommentsModern` exists.

### Parity

Swift's import of each corpus `.pptx`, saved with DCFormat, gives deckcraft's `.from-pptx.deckcraft`
byte for byte: every media and chart entry, and `presentation.json` except the manifest's `generator`
(`"DeckCraftNative 0.1.0"`, DCFormat's, against `"DeckCraft 0.11.1"`). That one field is the whole
difference in all 9 decks: with it replaced, the raw `presentation.json` bytes are equal.
`PPTXImportOracleTests.importMatchesOracle` compares the raw bytes, generator included, so it fails on
that field alone until the test (or DCFormat) treats the generator the way `OracleRoundTripTests` does.

### Rust semantics kept

- Maps that Rust keys by `String` (part names, ids, authors, VML shape ids, axis ids) are keyed by
  `ByteKey`, so they compare byte for byte.
- Wherever Rust compares, prefixes, splits or sorts strings, the reader works on bytes
  (`bytesEqual`, `hasBytePrefix`, `bytesLess` for `sort`, a byte `split('&')`, `split_once(':')`).
  `split(['\u{b}', '\n'])` on run text splits Unicode scalars, since a CR LF is one Swift `Character`.
- `chars().take(n)` counts Unicode scalars. `str::parse::<f64>` is `rustParseF64` (no trimming unless
  the Rust trims), integers go through `rustParseUnsigned`, `to_ascii_uppercase` is ASCII-only.
- `sort_by(total_cmp)` for gradient stops is a stable sort on `totalLess` (`-0.0` before `0.0`).
- `collect::<Option<Vec<_>>>()` stops at the first `None` (an opaque frame's kept parts), so later parts
  are never read; `chunk_by` (paragraph builds) groups consecutive pairs; `rem_euclid`, `f64::max`
  (`rustMax`) and NaN-propagating `clamp` (`clamped`) are Rust's.
- The order of every media and id allocation follows the Rust, including the id `diagram_data`
  allocates before it finds the part has no content type.

### Divergences

1. **`chartex`'s `d.numbers.values().next()`.** When a series' data has none of the `val`, `size` and
   `colorVal` dimensions, Rust takes whichever entry its `HashMap` yields first, which isn't
   deterministic. The port takes the first dimension the data declares.
2. **`switch` on element names and attribute values** compares with Swift's `==`, which equates
   canonically equivalent strings. Against the ASCII literals matched here, that only differs for input
   with a singleton decomposition onto ASCII (U+212A KELVIN SIGN reads as `K`), which no real part uses.
   Comparisons of optional attributes (`attr(…) == Some(…)`) are byte-wise.
3. **Logging** goes through `PPTXLog.warn` (`os.Logger`), not the `log` crate.

## write/

Port of `crates/pptx/src/write/` (Wave 3, part 3): about 4,800 lines of Swift in six files, the 6 in-file
`#[test]`s, and the export half of the oracle parity test. `PPTX.export` and `PPTX.exportAs` are an
extension of `PPTX` in `WriteMod.swift`; everything else is internal, under the caseless enum `PPTXWrite`.

### File map

| Rust | Swift | Notes |
|---|---|---|
| `lib.rs` (`export`, `export_as`) and `write/mod.rs` | `WriteMod.swift` | `PPTXWrite`: the `CT_*`/`RT_*` constants (`ctPres`, `ctCommentsModern`…), `Exp` and `Out` (`final class`es: Rust passes them `&mut`), `extFor`, `sanitized`, `export`, masters, layouts, slides, notes, comments (legacy and modern), sections, embedded fonts, `presentation.xml`, props parts; and the string and number helpers the writer uses (`isASCIIAlnum`, `splitScalars`, `rsplitOnce`, `utf8Contains`, `byteSlice`, `at4`, `remEuclid`, `satAdd`, `satMul`) |
| `write/dml.rs` | `WriteDML.swift` | `PPTXWrite.DML`: `emu`, `pct`, `ang`, colours, fills, `blipFill`, lines, effects, `xfrm`, hyperlinks, body/paragraph/run properties, list styles, text bodies |
| `write/shapes.rs` | `WriteShapes.swift` | `PPTXWrite.Shapes`: `IdMap`, `Ctx` (a `final class`), every shape kind, SmartArt parts, ink, 3-D models, tables, media, kept objects and their OLE fallback |
| `write/chart.rs` | `WriteChart.swift` | `PPTXWrite.Charts` (`chartXML`, `chartexPart`, `chartexXML`, `buildChartex`, `writeKept`…); `PPTXWrite.chartXML` (Rust `write::chart::chart_xml`, which the reader's tests call) and `PPTXWrite.nsCX` sit on `PPTXWrite` itself |
| `write/theme.rs` | `WriteTheme.swift` | `PPTXWrite.Themes.themeXML` |
| `write/timing.rs` | `WriteTiming.swift` | `PPTXWrite.Timing`: `transition`, `timing` and the effect builders |
| in-file tests | `Tests/DCPPTXTests/WriteTests.swift` | `WriteDMLTests` (1), `WriteShapesTests` (1), `WriteChartRegionMapTests` (1), `WriteChartTests` (3); 4 of them read back through `PPTXRead` |
| — | `Tests/DCPPTXTests/PPTXExportOracleTests.swift` | Export parity, schema validation and deckcraft's read-back over the 9 corpus decks |

The writer calls these reader functions, with Rust's parameter and return shapes: `PPTXRead.relRefs`,
`isRelAttr`, `keepXML`, `resolveMC(_:_:)`, `chartexFrom` and `chartFromEl`. Rust's `has_rel_refs` is
`relRefs(…).isEmpty`.

### Parity

- `exportMatchesOracle`: for each of the 9 corpus decks, every part Swift writes equals deckcraft's byte
  for byte, under the same names. `exportValidates`: every covered part validates against ECMA-376
  Transitional. `oracleReadsSwiftPackage`: deckcraft reads each Swift package to the model it reads from
  its own.
- Beyond the corpus, Swift's and deckcraft's exports (`deckcraft-cli convert`) were compared part for
  part on the 9 `.from-pptx.deckcraft` models (kept charts compared and rewritten through the reader),
  two other PowerPoint files read by deckcraft, and two synthetic decks built to reach every branch the
  corpus doesn't: tags, hyperlinks of every action, sounds, linked and missing pictures, picture
  adjustments and artistic effects, tiles, gradients, patterns, every effect, custom dashes and line
  ends, warped text, every bullet kind, fields, OMML, groups with duplicate ids, connectors, tables with
  merges and borders, video, audio, ink, 3-D models, OLE objects, every chart group and combo, error
  bars, trendlines, Office 2016 charts, kept charts with workbooks and user shapes, comments with
  replies and bad dates, unknown transitions with kept XML, triggers and paragraph builds, sections,
  custom shows, guides, embedded fonts, kept parts, handout and notes masters, and a deck with no
  masters. All 300-odd parts were identical. Only the zip container differs (see the foundation's
  divergence 6).

### Rust semantics kept

- Maps keyed by a Rust `String` (comment authors, kept part names, relationship ids) use `ByteKey`;
  string comparisons against model data are byte-wise (`bytesEqual`, `hasBytePrefix`, `utf8Contains`).
- `split('\n')` and `split(['\n', '\u{b}'])` split Unicode scalars (a CR LF is one Swift `Character`);
  `chars().take(n)` and `is_alphabetic`/`is_ascii_alphanumeric`/`is_control` work on scalars;
  `str::get(a..b)` checks scalar boundaries (`byteSlice`).
- `format!("{v}")` for floats is `rustDisplay`, `{:.2}` is `rustFixed`, `as i64` is `Int64(rustCast:)`,
  `f64::min`/`max` are `rustMin`/`rustMax`, `clamp` is `clamped`, `rem_euclid` and `saturating_*` are
  ported, and the mean ink width folds from `-0.0` as Rust's `Sum` does.
- `collect::<Option<HashMap<_, _>>>()` over an opaque object's relationships stops at the first missing
  part, after the media it already added, as the Rust does. Every id, rId, part number and content-type
  entry is allocated in the Rust order.

### Divergences

1. **`switch` on model keywords** (effect names, options, show type, content types, preset names) uses
   Swift's `==`, which equates canonically equivalent strings. Against the ASCII literals matched here
   that differs only for input with a singleton decomposition onto ASCII (U+212A KELVIN SIGN), which no
   deck holds. `extFor` checks that the content type is ASCII before matching it.
2. **Fixed-size arrays.** Rust's `[f64; 4]` (crop, fill rect, gradient focus and tile, cell margins) and
   `[Option<Line>; 4]` (cell borders) are Swift arrays; a short one reads its missing entries as 0 or
   no line, where Rust can't be short.
3. **`Cow<Presentation>`** for the sanitized deck is a value copy.
4. **Logging** goes through `PPTXLog.warn` (`os.Logger`), not the `log` crate.
5. **`chartex_xml`** is `#[cfg(test)]` in Rust; `PPTXWrite.Charts.chartexXML` is always compiled.
6. **The supplied `PPTXExportOracleTests.swift`** nested one `#require` inside another, which Swift 6.2
   rejects ("recursive expansion of macro"). The copy here binds the inner `#require` to a `let` first;
   nothing else changed.

## Integration tests

Port of `crates/pptx/tests/` (Wave 3, part 4): the 114 tests of `tests/it/*.rs` (27 modules) and the 5 of
`tests/chart_data_labels.rs`, 119 in all. They're in `Tests/DCPPTXTests/`, one file and one suite per Rust
module (`it/roundtrip.rs` → `IntegrationRoundtripTests.swift`, `it/corpus_kinds.rs` →
`IntegrationCorpusKindsTests.swift`, `chart_data_labels.rs` → `IntegrationChartDataLabelsTests.swift`, and
so on). Each test keeps its Rust name in camelCase, with a `// Rust: it/<module>.rs::<name>` comment.
`IntegrationSupport.swift` holds the helpers the Rust modules each copy (`png`, `entries`, `rezip`,
`round`, `shape`, `new_slide`, `wav`) as `IT.*`, plus byte-wise `find`/`rfind`/slice/`replacen`/`matches`
on `String`. ImageIO stands in for the `image` crate, DCZip for the `zip` crate (`SimpleFileOptions::default()`
deflates, so `IT.zip` does too).

| Module | Tests | | Module | Tests |
|---|---:|---|---|---:|
| `roundtrip` | 45 | | `corpus_kinds` | 1 |
| `malformed` | 12 | | `corpus_elements` | 1 |
| `fills` | 7 | | `corpus_style` | 1 |
| `comments` | 6 | | `corpus_charts` | 1 |
| `chart_data_labels` | 5 | | `corpus` | 1 |
| `chart_embed` | 4 | | `kept_parts` | 1 |
| `locks` | 4 | | `smartart` | 1 |
| `corpus_media` | 3 | | `tags` | 1 |
| `ole` | 3 | | `anchor` | 1 |
| `ole_vml` | 3 | | `placeholders` | 1 |
| `transition_xml` | 3 | | `corpus_themes` | 2 |
| `math_ns` | 2 | | `notes` | 2 |
| `sample` | 2 | | `sniff` | 2 |
| `table_styles` | 2 | | `trigger_steps` | 2 |

Every assertion and tolerance is the Rust one. Tuple comparisons are split into several `#expect`s, and
direct indexing goes through `#require`, so a short list fails the test instead of trapping. Tests that
write files for manual inspection (`DECKCRAFT_PPTX_OUT`, `DECKCRAFT_PPTX_BISECT`,
`DECKCRAFT_PPTX_BISECT_SLIDE`) or read one (`DECKCRAFT_PPTX_IN`) do so only when the variable is set.
`comments.rs`'s `every_written_xml_part_binds_its_prefixes` used quick-xml's `NsReader`. The port parses
each part with `parseXML` and walks the tree for an in-scope `xmlns:` declaration of every element and
attribute prefix.

### Without the engine

`deckcraft_engine` is Wave 4. Its uses are handled like this:

- **`open_sample`** reads the corpus's `decks/sample.deckcraft` (deckcraft's own save of the sample at the
  pin) through DCFormat: `IT.sample()`. Those tests (`anchor`, `kept_parts`, `sample`, `sniff`, `tags`,
  `malformed::fuzz_mutations`) are `.enabled(if: IT.hasCorpus)`.
- **`place_slide`** is DCRender's `placeSlide`. DCPPTXTests depends on DCRender for `smartart.rs`.
- **`base64_encode`** isn't needed: the bytes go straight into the model.
- **Built directly** where the commands only build a model, each saying so in a comment:
  `textTransparencyRoundTrips`, `chartexWaterfallReadsAndRoundTrips`, `chartexNewChartsSaveAsTheirOwnType`,
  `chartexLevelsAndQuartilesRoundTrip`, `radarStockAndComboRoundTrip` (`insert.chart` is `Chart.sample` at
  15 %/70 % of the slide, `chart.options`/`chart.data` set fields as the engine does) and
  `chartOptionsDataLabelsOnOverridesSeriesOff`.
- **Partly ported.** `transitionSoundIsSetSavedAndRemoved` and `transitionSoundOptionsRoundTrip` build
  the transition sounds directly and check the save and read-back. Their command-only assertions are under
  `#if DCENGINE`: the `playable` result, No Sound, refusing a non-audio file, turning the loop off alone,
  and refusing an unknown built-in.
- **Disabled, `needs DCEngine (wave 4)`**, with their bodies ported under `#if DCENGINE`:
  - `reuseSlidesFromAnotherPresentation` (`slide.reuse`);
  - `compressPicturesShrinksTheFileAndKeepsSharedOriginals` (`picture.compress`, undo);
  - `zoomInsertsLinkedSlidePictures` (`insert.zoom`, undo).

  Port them when DCEngine lands.

### Library fix

`malformed::deep_nesting_is_bounded` (200 nested `p:grpSp`) overflowed the stack and killed the test
process. The reader recurses once per group level up to its 33-level cap, a level takes about 46 KiB of
stack in a debug build, and Swift concurrency threads have 512 KiB. Rust's test threads have 2 MiB.
`PPTX.import`, `importChecked`, `export` and `exportAs` now run on a dedicated thread with a 32 MiB stack
(`PPTX.onLargeStack` in `PPTX.swift`). `importTheme` is unchanged. The oracle
tests are unchanged and green.

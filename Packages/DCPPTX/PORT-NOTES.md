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
| — | `WriteChartexStyle.swift` | `PPTXWrite.ChartexStyle`: the style and colour style parts every `chartEx` part gets (divergence 7); DeckCraftNative's own |
| — | `WriteChartPatch.swift` | `PPTXWrite.Charts.patchedXML`: a `chart.options` edit (title, legend, data labels, gridlines) or a `chart.data` edit (categories, series, their names and values) written into the kept chart part, with the table of which command owns which element (divergence 8); DeckCraftNative's own |
| — | `WriteChartPatchAxes.swift` | `PPTXWrite.Charts.patchAxesAndSeries`: axis titles, minor gridlines, the value axis's scale and format, reversed categories, gap and overlap, up/down bars and each series' trendlines and error bars written into the kept chart part (divergence 12); DeckCraftNative's own |
| — | `WriteChartWorkbook.swift` | `PPTXWrite.Charts.book`, `freshBook`, `updatedWorkbook`: the embedded workbook of a chart whose data the writer wrote, the original updated in place or a new one-sheet workbook (divergence 9); DeckCraftNative's own |
| `write/timing.rs` | `WriteTiming.swift` | `PPTXWrite.Timing`: `transition`, `timing` and the effect builders |
| in-file tests | `Tests/DCPPTXTests/WriteTests.swift` | `WriteDMLTests` (1), `WriteShapesTests` (1), `WriteChartRegionMapTests` (1), `WriteChartTests` (3); 4 of them read back through `PPTXRead` |
| — | `Tests/DCPPTXTests/PPTXExportOracleTests.swift` | Export parity, schema validation and deckcraft's read-back over the 9 corpus decks |
| — | `Tests/DCPPTXTests/ChartexStyleTests.swift` | Divergence 7: the added parts byte for byte (`ChartexStyleExpected`, which the oracle test uses too) and their structure, for every Office 2016 kind, kept and rebuilt |

The writer calls these reader functions, with Rust's parameter and return shapes: `PPTXRead.relRefs`,
`isRelAttr`, `keepXML`, `resolveMC(_:_:)`, `chartexFrom` and `chartFromEl`. Rust's `has_rel_refs` is
`relRefs(…).isEmpty`.

### Parity

- `exportMatchesOracle`: for each of the 9 corpus decks, every part Swift writes equals deckcraft's byte
  for byte, under the same names, apart from divergence 7: `charts` gains a style and a colour style part
  and a relationships part per `chartEx` part, and their `[Content_Types].xml` overrides. Those are an
  explicit allow-list (`expectedDivergences`) checked byte for byte, and the test fails if any other part
  differs. `oracleReadsSwiftPackage` lets deckcraft keep the added parts as the chart's `kept` sidecar and
  nothing else. dccli's `convert` parity test (`Apps/dccliTests/ParityTests.swift`) allows the same parts by name. `exportValidates`: every covered part validates against ECMA-376
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
7. **Style parts for Office 2016 charts (2026-10-27, deliberate).** deckcraft writes a `chartEx` part with
   no relationships. Microsoft PowerPoint for Mac (16.114) then reports "found a problem with content" and
   its repair discards the whole slide. That held for every Office 2016 kind deckcraft writes (waterfall,
   funnel, treemap, sunburst, histogram, Pareto, box and whisker; region maps open) and for the corpus
   `charts.pptx`, with or without options, and whether the slide carries the `mc:AlternateContent` or the
   `cx:chart` frame alone. Found by bisecting copies with `Tools/pptx/powerpoint-check.sh`: removing the
   title, legend, axes, layout properties, series text or `uniqueId`, or adding `cx:f` references or an
   embedded workbook with `cx:externalData`, changed nothing. Adding a `chartStyle` and a `chartColorStyle`
   relationship (`http://schemas.microsoft.com/office/2011/relationships/…`) to schema-shaped
   `cs:chartStyle` and `cs:colorStyle` parts fixed it; either one alone, or either one empty, did not.
   PowerPoint also takes a chartEx's default fills and lines from those parts, so placeholder parts open
   but draw unfilled bars. `ChartexStyle.add` writes a full default style (series in the colour cycle,
   light gridlines, grey text) as `ppt/charts/styleN.xml` and `colorsN.xml` beside `chartExN.xml`,
   whenever the part has no style relationship of its own: a rebuilt chart, or a kept one from a file
   without them. A kept chart that had them keeps them. Plain `c:` charts are unchanged; PowerPoint opens
   them without style parts. This breaks byte identity with deckcraft for those parts only (PLAN.md §6).
   Spec basis: ECMA-376 has no chartEx; the `cs:chartStyle`/`cs:colorStyle` parts, their content types and
   relationship types are Office extensions ([MS-ODRAWXML], which `../pptx-swift-main/specifications` doesn't
   carry). Their contents use ECMA-376 Part 1 DrawingML: style matrix and font references (§20.1.4: `lnRef`,
   `fillRef`, `effectRef`, `fontRef` with `minor`), `a:schemeClr` with `lumMod`/`lumOff` (§20.1.2.3), and
   `a:ln`/`a:solidFill`/`a:noFill`. Nothing was copied from a PowerPoint-written file: the one repaired copy
   (made with the user's leave, kept in a scratch folder and deleted) blanked the whole slide and named no
   element. Checked with `Tools/pptx/powerpoint-check.sh`, which presses only Cancel and saves nothing.
8. **An edited chart keeps its part (2026-11-04, deliberate; AB-T-0433).** deckcraft reuses a chart's
   original XML only while the model read from it equals the current model, and its engine drops `raw` on
   any edit, so the first edit regenerates the part. Everything the model doesn't hold is then lost without
   a repair prompt: on six PowerPoint-saved charts, one title edit dropped the embedded workbook, the style
   and colour parts, `c14:style`, the data table, label positions, gradient fills, 3-D, of-pie, 100 % lines
   and a combo's secondary axis (`research/DeckCraftNative-charts-gaps/review.md`). Now `chart.options`
   keeps `raw` for a title, legend, data labels or gridlines (it still drops it for `textColor` and
   `palette`), and `Charts.patchedXML` writes the changed fields into the kept tree:
   - **title:** the text replaced, each line keeping the first paragraph's and run's formatting; a new
     title when there was none; or the title removed and `c:autoTitleDeleted` set;
   - **legend:** `c:legendPos` set, a legend added, or removed;
   - **data labels:** `c:showVal` set in every plot group's and series' `c:dLbls`, so positions and number
     formats stay; a series' deleted labels are dropped, since the series now follows the chart;
   - **gridlines:** `c:majorGridlines` added to or removed from the reader's primary value axis.

   `chart.data` keeps `raw` too (second half, the same day), and `Charts.patchData` writes the model's
   series into the plot groups' `c:ser`s position by position, as the engine keeps each position's
   formatting:
   - **names, categories, values:** each `c:tx`, `c:cat` and `c:val` (`c:xVal`, `c:yVal`, `c:bubbleSize`)
     cache rewritten, keeping the values' number format; a reference that already holds the data keeps its
     cache, so date or multi-level categories stay when only the values change;
   - **ranges:** every `c:f` becomes the generator's (`Sheet1!$A$2:$A$n` for categories, a column per
     series), since the workbook they pointed into goes;
   - **series removed:** the extra `c:ser`s; a plot group may be left empty;
   - **series added:** a copy of the last series, in its group, with a fresh `c:idx`/`c:order` and none of its
     look (fill, points, labels, trendlines, error bars, its extension list and PowerPoint's unique id). A
     scatter series without x values gets no `c:xVal`. In a combo chart the last group must be clustered
     columns (what the model's series without a type of its own is), otherwise the part is regenerated: the
     reader takes series in file order;
   - **the workbook:** taken out with `c:externalData` (`Charts.withoutWorkbook`): its cells would contradict
     the chart, and PowerPoint's Edit Data would bring the old numbers back. The style, colour and drawing
     parts stay. Since divergence 9 the writer links the original updated with the new data, or a new
     workbook, instead.

   `Charts.chartPart` returns the kept parts to write with the part (nil for a generated one), so
   `chartRel` writes the style parts without the workbook. The patched part is used only when reading it
   back gives the model, with these exceptions for values the reader derives from something no longer there:
   a removed title's size; the text size and colour taken from a removed legend; gridlines on a chart with no
   value axis; a scatter or bubble chart's categories (its x values: the generator doesn't write them
   either); a new bubble's size 1, which the generator writes too; a combo series without a type of its own,
   which is a clustered column; and the secondary axis's settings once no series is plotted on it. Anything
   else, including `chart.type`, category levels, an Office 2016 chart and a part with other prefixes, goes to
   the generator as before. Tests: `WriteChartPatchTests`; `Tools/pptx/chart-edit-sweep.py` over the review's
   PowerPoint fixtures, where every edit keeps every element and part apart from the one it removes (for
   `--data`, apart from the series' data elements and the workbook) and reads back with the data asked for,
   and `Tools/pptx/powerpoint-check.sh` opens all of them without a repair prompt. The ported
   `editingChartAfterNativeReopenDoesNotExportAStaleWorkbook` still checks that the stale workbook goes; it
   now also checks that the chart's drawing stays.
9. **A chart whose data the writer wrote has an embedded workbook (2026-11-05, deliberate; AB-T-0435).**
   deckcraft writes none: not for a new chart, and an edit drops the original's. PowerPoint then builds a
   sheet from the caches when asked to edit the data (O-31), so formulas, other sheets and formatting a user
   had are lost, and a new chart has nothing behind it. Now `Charts.chartPart` says when the data was written
   from the model (`fresh`: a generated part, or one patched by `chart.data`), and `chartRel` links that part
   to a workbook at `ppt/embeddings/Microsoft_Excel_WorksheetN.xlsx` (N the chart's), with
   `<c:externalData r:id=…><c:autoUpdate val="0"/>` after `c:txPr`, as PowerPoint writes it:
   - **the cells** are what the part's own ranges (`c:f`) and caches say (`Charts.rangeClaims`). Only the
     generator's ranges are read (one column of `Sheet1`); a part with others gets no workbook, with a
     warning. A range that would contradict an earlier one moves to a free column and its `c:f` follows:
     deckcraft gives every scatter series' x values column A, and a bubble series' sizes the next series'
     y column;
   - **the original, updated** when the chart had a workbook package whose ranges were the generator's for
     the chart as read (PowerPoint's own layout: the review's seven PowerPoint-made fixtures all are): the
     chart's cells set (numbers, inline strings; a cell keeps its style, loses its formula), cells only the
     old ranges covered cleared, a table over the data resized with its columns named from the header row,
     the calculation chain dropped, `fullCalcOnLoad` set so formulas reading the cells recalculate. Other
     sheets, other cells, shared strings, styles and the theme stay. A cell the data grows into is
     overwritten, as PowerPoint's Edit Data would;
   - **a new workbook** otherwise (`Charts.newWorkbook`: `Sheet1`, inline strings, a minimal style part, no
     table), with a warning when it replaces an original: ranges in another layout, an OLE object, a shared or
     array formula over the cells, a table not at A1 or with a totals row or calculated column, a header that
     can't name a column, or a package that doesn't read.

   An Office 2016 chart's fallback gets none (the `chartEx` part carries the data), and `chartEx` parts are
   unchanged: they still go without a workbook once edited. Untouched and `chart.options`-patched parts keep
   theirs as before. The export oracle applies the divergence to deckcraft's package (`expectedWorkbooks`:
   each plain chart Swift links is deckcraft's run through `Charts.freshBook`, byte for byte, and the others
   must be exactly the `chartEx` fallbacks); deckcraft reads the package back to its own model apart from the
   workbook it keeps. Three ported tests changed: `chartsRoundTrip` compares the kept workbook's bytes (it is
   renamed `keptN` on the next save, as every kept part is), `plainChartHasNoStyleParts` allows the workbook
   relationship, and `anEditedChartDoesNotWriteAStaleWorkbook` checks that the workbook written holds the
   edit; `IntegrationChartEmbedTests` strips the written workbook before adding its own. Tests:
   `WriteChartWorkbookTests` (every plain type's workbook agrees with its ranges; clashing ranges move; a
   PowerPoint-shaped workbook updated in place, grown and shrunk; each fallback; a deck round trip).
   `Tools/pptx/chart-edit-sweep.py --data` now also checks that every edited chart's workbook agrees with it
   and says whether it was updated, replaced or new; `Tools/pptx/excel-check.sh` opens workbooks in Excel.
   Excel opened all 107 workbooks of the sweep and the insert deck cleanly, and PowerPoint's Edit Data in
   Excel shows an edited chart's new values in its original table (2026-11-05).
10. **The chart types the reader knows are written back (2026-11-05, deliberate; AB-T-0434).** deckcraft's
    generator writes a surface chart as `c:areaChart` (so even a new one changes type on its first save), a 100 %
    stacked line as stacked, 3-D groups and `c:ofPieChart` flat, and every series of a combo on one pair of axes.
    Since divergence 8 an element edit keeps the original part, but anything that regenerates it (a palette or
    text colour, `chart.type`, a new chart) lost the type. With DCModel's new fields (its divergence section),
    the reader keeps them and the generator writes them, element order as in ECMA-376 §21.2.2:
    - **surface:** `c:surfaceChart` (a contour, with PowerPoint's top-down `c:view3D`: `rotX` 90, `rotY` 0,
      `rAngAx` 0, `perspective` 0), or `c:surface3DChart` when the chart has a 3-D view; `c:wireframe` first,
      a depth axis (`c:serAx`, id 50005), no `c:varyColors`, and series of `tx`, `spPr`, `cat` and `val` only
      (`CT_SurfaceSer`: no labels, markers, points, trendlines or error bars). The value axis crosses between
      categories as an area's does (`midCat`);
    - **100 % lines and areas:** `percentStacked` grouping and a `0%` value axis, read as `percentLine` and
      `percentArea` where the reader made them stacked;
    - **3-D:** a column, bar, line, area or pie chart with `threeD` is written as `c:bar3DChart`, `c:line3DChart`,
      `c:area3DChart` or `c:pie3DChart` with its `c:view3D` (each value clamped to the schema's range) and
      `c:gapDepth`; bars keep `c:shape` and lose `c:overlap`, a line its group `c:marker`, a pie its first slice
      angle, as the schema has it. A depth axis (always for a line; for bars and areas when `depthAxis`, which the
      reader sets when a group's axis is a `c:serAx`) gives grouping `standard` and a `c:serAx`; without one, 3-D
      bars and areas get a third axis id of 0, as PowerPoint writes them. The reader keeps a view only from a 3-D
      group, and none for a combo;
    - **of-pie:** a pie with `ofPie` is `c:ofPieChart` with `c:ofPieType`, `c:gapWidth` (the chart's),
      `c:splitType`, `c:splitPos`, `c:custSplit`, `c:secondPieSize` and an empty `c:serLines`; it is still drawn
      as one pie;
    - **a combo's secondary axis:** series with `secondaryAxis` form plot groups of their own on PowerPoint's
      second pair of axes (`c:valAx` 50004 on the right, crossing at the maximum, with `y2Min`, `y2Max`,
      `y2Major`, `y2Format` and `y2Hidden`; a deleted `c:catAx` 50003). Groups go by type and axis, so a column
      series on each axis makes two `c:barChart`s. When every series is on the secondary axis they share the
      primary pair, as before. A combo without one is written as deckcraft writes it.

    Formatting the model doesn't hold (floor and walls, band formats, the connector lines' look) is still lost on
    regeneration; an element edit keeps it (divergence 8). No corpus deck has one of these charts, so the export
    oracle is unchanged. Tests: `WriteChartTypesTests` (each type written, read back and saved again unchanged;
    PowerPoint-shaped plot groups read; hostile 3-D values bounded; the deck JSON without the fields as
    before). On the review's five PowerPoint fixtures (`pp-contour`, `pp-pctline`, `pp-col3d`, `pp-barofpie`,
    `pp-combo2`) a palette edit, which regenerates the part, now keeps `surfaceChart` with `view3D` and
    `wireframe`, `percentStacked`, `bar3DChart` with `view3D` and `shape`, `ofPieChart` with its split, and two
    `c:valAx`; a title edit keeps every element (`chart-edit-sweep.py`). Those ten files, a deck of all 29 chart
    types `insert.chart` makes and a deck of every 3-D, wireframe, of-pie and secondary-axis variant validate
    against the schemas (`validate.sh`), and PowerPoint 16.114 opened all twelve without a repair prompt.
11. **Chart builds (2026-11-05, deliberate; AB-T-0443).** deckcraft reads `p:spTgt` without its
   `p:graphicEl`, and writes no `p:bldGraphic`, so a PowerPoint chart built By Series came back as three whole
   chart effects with no build. Now:
   - **read** (`ReadTiming.animations`): each effect keeps the chart part it targets
     (`p:graphicEl/a:chart` `seriesIdx`, `categoryIdx`, `bldStep` → `chartElement`), and each `p:bldGraphic`'s
     `a:bldChart` (`bld`, `animBg`) is read. A run of one shape's part effects in one `grpId` with a
     `bldGraphic` becomes one animation with `chartBuild` when that build plays them exactly
     (`playsAsChartBuild`: one effect per step of `chartBuildSteps`, later steps on click, or after previous
     when the build doesn't start on click, the same settings); otherwise the effects stay, each with its part;
   - **write** (`WriteTiming.timing`): a build is one effect per step, all in one `grpId`, each targeting
     `p:graphicEl/a:chart` with PowerPoint's indices (-3 for the background, -4 for the index a step doesn't
     name), and a `p:bldGraphic` with `p:bldSub/a:bldChart` (`animBg="0"` when the background is left out). A
     shape's consecutive part effects share a `grpId` and one `bldGraphic` named after their kind. The
     `bldLst` entries keep animation order; PowerPoint sorts them by shape, which nothing depends on.

   What PowerPoint writes was measured on decks PowerPoint 16.114 saved (2026-11-05): By Series, By Category,
   By Element in Series and in Category, On Click and After Previous, two builds on one chart. Those decks
   round-trip with every step, delay, group and build entry. A chart without a build, and every deck in the
   oracle corpus, writes as before. Tests: `ChartBuildTimingTests`.

12. **The rest of a chart's elements are edited in the kept part, and a line chart has up/down bars (2026-11-05,
    deliberate; AB-T-0436).** `chart.options` now also sets axis titles, minor gridlines, the value axis's
    minimum, maximum, major unit, log base and number format, reversed categories, gap width and overlap, and a
    series' trendline and error bars (DCEngine PORT-NOTES). `WriteChartPatchAxes.swift` writes each into the kept
    part beside divergence 8's four, so a PowerPoint chart keeps what the edit doesn't touch; its table names the
    elements each setting owns. A replaced trendline or error bars keep the old one's `c:spPr`; a new vertical
    axis title gets PowerPoint's `a:bodyPr rot="-5400000" vert="horz"`. Up/down bars no longer regenerate the
    part. As before, the patched part is used only when reading it back gives the model; an axis set to follow
    the data reads back with the data's format (often `General`). The error bars' writer is one function now
    (`errorBars`), the generator's output unchanged. Beyond deckcraft, the reader takes a `c:lineChart`'s
    `c:upDownBars` (it read a stock chart's only) and the generator writes them for a flat line chart of two
    series or more, before `c:marker` (CT_LineChart); DCRender draws them. The generator also writes the primary
    value axis's `c:majorUnit` (deckcraft writes only a secondary axis's, so a new chart lost the unit it was
    given), and a trendline's `c:dispRSqr` and `c:dispEq` always, off or on: PowerPoint 16.114 reads a missing
    one as on, so every trendline deckcraft writes without them showed its equation and R² there (seen on a
    PowerPoint re-save, which wrote them `val="1"`). The reader still takes a missing one as off; a third-party
    file without them draws without the label here and with it in PowerPoint. Tests: `WriteChartPatchTests`
    (5 more).

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

## Pin move 88c2ceff → a3fbf029

Ported (2026-10-31), each with its Rust tests:

| Upstream | What | Swift |
|---|---|---|
| `ad97533a`, `04b0958b` | Gradient `flip` read and written (`a:gradFill flip`, before `rotWithShape`) | `ReadDML.gradient`, `WriteDML` `gradient`; `richDeck`'s Gradient Star flips `xy`; `gradientFlipModeSurvivesTwoPptxRoundTrips` |
| `727b682d`, `4408ff61` | Line `algn` (`ctr`/`in` only, through DCModel's `LineAlign(xml:)`) | `ReadDML.line`, `WriteDML.line`; `lineAlignmentSurvivesTwoPptxRoundTrips` |
| `479c3cc5`, `1de0101c` | `a:miter lim`, both the integer and the `200%` form, bounded by `Int32.max`; written only within it | `PPTXRead.parseMiterLimit`, `WriteDML.line`; `miterLimitAcceptsBothPercentageFormsWithSchemaBounds`, `lineMiterLimitSurvivesTwoPptxRoundTrips` |
| `8770fb90`, `0e3f4cd3` | `a:buFontTx`/`buClrTx`/`buSzTx` read as follow-text resets and written only when no explicit value is set | `ReadDML.ppr`, `WriteDML.ppr`; `bulletFollowTextResetsSurviveTwoPptxRoundTrips` (the inheritance half is DCModel's) |
| `c5994e16`, `8dfa6f19` | Auto-reverse also read when every behaviour `p:cBhvr/p:cTn` has `autoRev`, except for Color Pulse | `PPTXRead.behaviourAutoReverses`; new `IntegrationAnimAutoReverseTests` (2) |
| `964f4759` | Volume, mute, loop, hide while not playing and full screen read from `p:video`/`p:audio` `p:cMediaNode` in the timing tree | `PPTXRead.mediaSettings` (through DCModel's `mutateShape`), called after `animations` in `readSlide`; new `IntegrationMediaTimingTests` (2) |
| `1e842137` | Darken and Desaturate written as PowerPoint's HSL `p:animClr` shift on text, fill and line colour (preset ids 24/25 and the durations are DCModel's) | `WriteTiming`; `darkenAndDesaturateUsePowerpointsIds`, `darkenAndDesaturateWritePowerpointsHslShift`, `defaultDurationsMatchPowerpoint` |
| `1de7b44a`, `3bf35c80` | Custom geometry paths: `E` is an exponent when a digit (or a sign and a digit) follows a number, else the end command; `-` after `E` stays in the number | `CustGeom.parsePath`; `parsePathUppercaseExponent` |
| `939bd128`, `ba29b61f` | Zip entries named with `\`: keyed through `OPC.norm` and kept with `/` as the original name. This lives in `OPC.swift`, not DCZip, which is unchanged | `Package.openWithin`, `OPC.replacingBackslashes`; `backslashZipEntryNamesAreFound` |
| `1705712a` | A picture without geometry in a placeholder takes its layout's shape | `ReadShapes.pic` (`markInheritedGeometry`); `aPicturePlaceholderWithoutGeometryTakesItsLayouts` |
| `58968594` | Charts: `c:tickLblPos val="none"` hides axis labels like `c:delete`; a gridline whose `c:spPr/a:ln` is `a:noFill` isn't drawn | `ReadChart` (`deleted`, `grid`); `hiddenLabelsAndUnfilledGridlinesAreRead` |

No port needed: `8e4d0e6b` (Clippy refactor of `read.rs`, `read/chart.rs`, `write/chart.rs` and the
corpus tests: functions split, no behaviour change), `505a6f28` (its `read/dml.rs`
part turns `br`/`fld` into match guards, which fall through to `_ => {}` as before), the `flip: None`
lines added to `fills.rs` and `corpus_style.rs` (Swift's `Gradient` init defaults `flip` to nil), and the
merge commits (conflict resolution only).

Export parity, schema validation and deckcraft's read-back over the regenerated corpus
(`oracle/a3fbf029/`) stay green; the chartEx style parts remain the only divergence.

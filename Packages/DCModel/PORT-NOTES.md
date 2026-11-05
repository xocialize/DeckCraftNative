# DCModel — port notes

Port of deckcraft `crates/model` at the pin in `Tools/oracle/pin.env`. Status: **done** (Wave 1). It has 96
tests: all 95 Rust `#[test]`s across the module's files, plus a check of the JSON shape serde writes.

## How it is built

- **Types are generated.** `Types.generated.swift` is written by `Tools/port/serde2swift.py`; run it through
  `Tools/port/generate.sh`. It holds every `#[derive(Serialize)]` struct and enum in `lib.rs`, `style.rs`,
  `text.rs`, `theme.rs`, `table.rs`, `anim.rs` and `chart.rs`: 100 types, each with JSON coding that follows
  its serde attributes exactly. Never edit it by hand. The generator's docstring describes the mapping.
- **Behaviour is hand-ported** into one Swift file per Rust module. Those files also provide the pieces the
  generated code names:
  - `static var default`, for each manual `impl Default`
  - the custom `skip_serializing_if` predicates (`isDefaultProps`, `isDefaultPara`, `isTextKind`,
    `ChartKept.isEmpty`, `ListStyle.isEmpty`)
  - `lenientSize`
- **Parity is measured by the oracle.** Every `.deckcraft` in the corpus loads, and saving it writes
  byte-identical `presentation.json` (DCFormat's `OracleRoundTripTests`).

## Divergences: the port's own model fields

The chart and animation models have fields deckcraft doesn't (decision 1 of
`research/DeckCraftNative-charts-gaps/review.md`: optional fields that serialise as before). They are patches over deckcraft's `chart.rs` and `anim.rs`,
`Tools/port/divergence/model-*.patch`, which `Tools/port/generate.sh` applies to a copy of the pinned sources
before generating, so `Types.generated.swift` stays generated and the pinned checkout is never changed. A pin
move that touches the same lines stops the script until the patch is redone. The patched Rust is input to the
generator only; it isn't built.

- **`ChartType.percentLine` and `percentArea`** (2026-11-05, AB-T-0434): 100 % stacked line and area, which the
  reader read as stacked. `stacked` and `percent` include them; `isArea` is new (the area kinds and filled radar).
- **`Chart.threeD: Chart3D?`**: a chart drawn in 3-D, its `c:view3D` (`rotX`, `hPercent`, `rotY`,
  `depthPercent`, `rAngAx`, `perspective`) and its group's `gapDepth`, `shape` and `depthAxis`.
- **`Chart.wireframe`**: a surface chart's `c:wireframe`.
- **`Chart.ofPie: OfPie?`**: a pie chart's second plot (`c:ofPieChart`): `bar`, `splitType`, `splitPos`,
  `custom`, `secondSize`, `seriesLines`.
- **`Chart.bubbleScale: Double?` and `Chart.bubbleSizeWidth`** (AB-T-0437): a bubble chart's `c:bubbleScale`
  (percent of the default size) and `c:sizeRepresents val="w"` (sizes give the bubble's width, not its area).

Each is skipped when unset (`None`, `false`), so every deck without them writes the same `presentation.json`;
the corpus round trip is unchanged. A deck that uses them is one deckcraft reads with the fields ignored, and
the two new types not at all. Their behaviour is in DCPPTX (divergence 10), DCEngine and DCRender.

### Chart builds (AB-T-0443)

deckcraft animates a chart as one object. PowerPoint can build it a series, a category or a point at a time
(Effect Options › Sequence), and a deck that had a build lost it on a round trip. The animation model gains
three fields (`Tools/port/divergence/model-anim.patch`):

- **`Animation.chartBuild: ChartBuild?`**: `bySeries`, `byCategory`, `bySeriesElement`, `byCategoryElement`
  (nil: as one object). One animation, which the writer and the timeline expand into one effect per step, as
  `textBuild` is for paragraphs.
- **`Animation.chartNoBackground`**: the build has no background step (`a:bldChart animBg="0"`).
- **`Animation.chartElement: ChartElement?`**: the part one effect animates (`step`: `background`, `series`,
  `category`, `seriesPoint`, `categoryPoint`, with its `series` and `category`), for a file's steps that don't
  play back as a build of the first, as `paragraph` is for text.

All three are skipped when unset, so every deck without a build writes the same `presentation.json`.
`ChartBuild.swift` (hand-written) has the file values and `chartBuildSteps(chart, build, background:)`, the
step list the reader, the writer and the timeline share: the background, then each series, category or point
(points series by series, or category by category, PowerPoint's orders), at most `maxChartBuildSteps` (1,000).
`Chart.playsBuildByParts` says which kinds the renderer draws part by part (not radar, stock, box and whisker,
histogram, Pareto, waterfall or the Office 2016 charts), and `takesBuild(_:)` which builds the app and
`animation.options` offer: those kinds, with data and no more than the step cap. A build read from a file is kept
on any chart. Their behaviour is in DCPPTX (divergence 11), DCAnim, DCRender, DCEngine and DCApp.

## File map

| Rust | Swift | Notes |
|---|---|---|
| `lib.rs` | `Model.swift` (+ generated types) | `find_shape_mut` → `mutateShape(_:_:_:)`; `sibling_list_mut` → `mutateSiblings` (closure-taking, over an index path); `Arc<Slide>`/`Arc<Master>` → plain values (Swift arrays share storage copy-on-write) |
| `style.rs` | `Style.swift` | |
| `text.rs` | `Text.swift` | `chars().count()` → `String.charCount` (Unicode scalars) |
| `theme.rs` | `Theme.swift` | Built-in themes are deckcraft's own colours and names |
| `defaults.rs` | `Defaults.swift` | `new_presentation`, `blank_presentation`, `build_master`, `new_slide`, `layout_of_kind` |
| `resolve.rs` | `Resolve.swift` | Free functions → `Resolve.*`; `Ctx` holds value copies of the presentation, master and layout |
| `edit.rs` | `Edit.swift` | `TextEdit.*`; `Pos` → `TextPos` (a tuple) |
| `words.rs` | `Words.swift` | `Words.*`; grapheme clusters are Swift `Character`s |
| `bidi.rs` | `Bidi.swift` | |
| `anim.rs` | `Anim.swift` | `TRANSITIONS`/`ANIMATIONS` → `transitions`/`animations` arrays of info structs |
| `chart.rs` | `Chart.swift` | Ported by a parallel session. Non-serde types `Bin`, `BoxStats`, `TreeNode` declared by hand; `Chart.axisScale` calls the free function as `DCModel.axisScale` |
| `trendline.rs` | `Trendline.swift` | |
| `numfmt.rs` | `NumFmt.swift` | `NumFmt.format(code, v, lang)`. Also the shared helpers: `rsPowi` (LLVM `__powidf2`), `rsSum` (folds from `-0.0`), `rsDisplay` (Rust `{}` for f64), `rsExp` (`{:.Ne}`), `rsTotalLess` |
| `table.rs` | `Table.swift` | `Table::new` → `Table(rows:cols:width:rowHeight:)`; negative indices clamp (Rust's `usize` can't be negative) |
| `tests.rs` + in-file tests | `Tests/DCModelTests/*` | 96 tests in 10 suites |

## Rust semantics kept

- **Rust's `None` variant** becomes Swift `none_`, so that `Fill.none_` and `Optional.none` can't be
  confused.
- **Text offsets** count Unicode scalars, as Rust's `chars()` does.
- **String comparison** uses `rustEqual` (DCCore), which compares scalar for scalar, wherever a Rust `==`
  decides behaviour; Swift's `==` treats canonically equivalent strings as equal.
- **Case mapping** uses `rustLowercase` and `rustUppercase`, which include Greek final sigma, as Rust's
  `to_lowercase` does.
- **`Paragraph.normalize`** compares `RunProps` with the synthesized `==`. Its strings compare by canonical
  equivalence, so two runs whose properties differ only in Unicode normalisation would merge here and not in
  Rust. That's harmless, and it's recorded here.

## Not ported

Nothing.

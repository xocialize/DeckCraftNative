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

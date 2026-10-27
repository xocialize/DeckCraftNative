# DCFormat — port notes

Port of deckcraft `crates/format` at the pin in `Tools/oracle/pin.env`. Status: **done** (Wave 1). It has 42
tests: all 39 Rust tests (22 from `lib.rs`, 9 from `rtf.rs`, 8 from `chart_parts_tests.rs`), plus 3 oracle
round-trip tests.

## What "byte-compatible" means here

- **`presentation.json` is byte-identical.** Every deck in the oracle corpus (`oracle/<pin>/decks/*.deckcraft`,
  `.from-pptx` re-reads included) loads in Swift, and re-saving writes exactly the JSON the Rust app wrote.
  The manifest's `generator` field is the one exception: it names the writing app (`DeckCraftNative 0.1.0`).
- **The deckcraft-cli at the pin opens our files.** `deckcraft-cli info` on our save of each deck prints what
  it printed for the original, apart from the file path.
- **The zip around the JSON is not byte-identical.** Entries, names, order, contents and store/deflate choices
  match. The DEFLATE streams (Apple Compression vs miniz) and timestamps don't.

## File map

| Rust | Swift | Notes |
|---|---|---|
| `lib.rs` (save, load, sniff, budgets, manifest) | `Format.swift` | `DeckFormat.*`. ZIP from DCZip, with last-wins lookup of duplicate names, as the Rust `zip` crate does |
| `lib.rs` (`parse_manifest`) | `Format.swift` | Rust patches `null` → `0` and re-parses, guided by serde's error positions. Here a `null` where a float is required reads as 0 (DCCore `JSONDecoding.nullFloatsAsZero`). The result is the same presentation, and `Option` floats still read `null` as nil |
| `lib.rs` (`repair`, `sane_*`) | `Repair.swift` | |
| `lib.rs` (outline, Markdown) | `Outline.swift` | `str::lines` → DCCore `rustLines` |
| `finite.rs` | `JSONWriter(nonFiniteAsZero: true)` | |
| `chart_parts.rs` | `ChartParts.swift` | Index parse is `UInt`, as Rust's `usize` (Swift `Int` would accept `chart-parts/-1`) |
| `rtf.rs` | `RTF.swift` | Byte-level parser over UTF-8, as the Rust one is |
| tests | `Tests/DCFormatTests/FormatTests.swift`, `OracleRoundTripTests.swift` | Archive surgery uses DCZip in place of `zip::raw_copy_file` |

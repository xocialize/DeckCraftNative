# DCFoundation — port notes

DCGeometry ports deckcraft `crates/geom` at the pin (`Tools/oracle/pin.env`, deckcraft `27009cd9`) together
with the parts of kurbo 0.13.1 it uses. DCColor (`crates/color`) is ported separately, by the main Wave 1
session.

## Status

**DCGeometry: done.** Every function of `crates/geom` is ported, and all of geom's 62 `#[test]`s are ported
as Swift Testing tests. There are 8 new tests: serde shapes, Rust float semantics, `rustDisplay`, and five
oracle suites. The total is 70, all green in debug and release.

**Oracle parity: bit-identical.** `Tools/oracle/geom-vectors` writes deckcraft-geom's outputs, every float
as its f64 bit pattern, into `../DeckCraftNative-Fixtures/geom/`. `OracleTests.swift` rebuilds each file and
compares it line by line. Every line matches, with no tolerance anywhere:

| File | What it covers |
|---|---|
| `presets.txt` | Full dumps of every catalog preset (187) at 100×100 and 216×108 with default adjusts: sub-paths, text rect, handles with `valueAt`, sites, exact bounding box, signed area, `presetFlatten` output, `nearPath` |
| `preset-hashes.txt` | FNV-1a hashes of the same dump for 187 presets × 5 sizes (including 0×0) × 6 adjust sets (defaults, zeros, 100 000s, mixed, ±1e12, NaN/±∞): 5,610 cases |
| `warps.txt` | All 40 warps × 2 rects (one inverted) × 3 adjust sets: guide lengths, `at`, `offset`, handles, mapper zoom and `map` for fill and follow bands, `bandOfLine` |
| `morphs.txt` | 7 preset pairs at t = 0, 0.37, 1 with scaling: paths, fades, text rect, and the raw `align` contours |
| `misc.txt` | Squircle path text (9 inputs, NaN and 1e21 included), `Unit.parse` and `format`, `ptToEmu`, `Xfrm.affine`, `bounds`, `rotNorm`, `groupChildAffine` |

To debug a hash mismatch: `geom-vectors --dump NAME W H SET` prints one case's full dump.

## File map

| Rust | Swift | Notes |
|---|---|---|
| `lib.rs` | `Geometry.swift` | Units, `Unit`, `Xfrm` (+ serde JSON), `groupChildAffine`, `distToSegment`, `nearPath`, `snap`, `presetFlatten` |
| `preset.rs` | `Preset.swift` | `FillMode` (top level, serde JSON); `enum Preset` namespaces Rust's module: `SubPath`, `Handle`, `Geometry`, `Category`, `Info`, `catalog`, `info`, `mitredByDefault`, `isLineLike`, `build`; `Pb` (path builder) |
| `preset/extra.rs` | `PresetExtra.swift` | `Preset.buildExtra` and its helpers |
| `warp.rs` | `Warp.swift` | `struct Warp` namespaces the module: `Warp.Guide`, `Band`, `LineAnchor`, `PresetInfo`/`catalog`, `Handle`, `Line` (Rust `WarpLine`), `Mapper`; `Warp.make` is Rust's `warp()` |
| `warp/tests.rs` | `Tests/…/WarpTests.swift` | |
| `morph.rs` | `Morph.swift` | `enum Morph` (`Contour`, `contours`, `toPath`, `align`, `Fade`) and `GeometryMorph` |
| `squircle.rs` | `Squircle.swift` | `Squircle.pathD`; `rustDisplay` reproduces Rust's `{}` for floats |
| kurbo `point.rs`, `vec2.rs`, `size.rs`, `rect.rs`, `insets.rs`, `affine.rs` | `Kurbo.swift` | `Point`, `Vec2`, `Size`, `Rect`, `Affine`; serde JSON for `Point`, `Vec2`, `Size`, `Rect` (plain derives) |
| kurbo `bezpath.rs`, `arc.rs`, `line.rs`, `quadbez.rs`, `cubicbez.rs`, `common.rs`, `param_curve.rs` | `KurboPath.swift` | `PathEl`, `BezPath`, `PathSeg`, `LineSeg` (kurbo `Line`, renamed because the model declares `Line`), `QuadBez`, `CubicBez`, `Arc`, `flatten`, `solveQuadratic`, exact bounding boxes, signed area |

Not ported, because geom doesn't use them: kurbo's `nearest` (geom calls it only in tests; the Swift tests
use a sampled nearest-point search instead), winding numbers, arc length, offset curves and stroking.

## What it took to be bit-identical

These are Rust and LLVM behaviours that Swift doesn't share. Each one changed real outputs until it was
matched.

1. **`f64::min`/`max` order signed zeros.**
   - On AArch64 they lower to `fminnm`/`fmaxnm`, which treat -0 as less than +0 and ignore a NaN operand.
     Swift's `min`/`max` don't order signed zeros that way.
   - `fmin`/`fmax` in `Kurbo.swift` reproduce the Rust behaviour.
   - `f64::clamp` passes -0 and NaN through unchanged; that is `Double.clamp(_:_:)`.
2. **kurbo's `Vec2::hypot` is `hypot2().sqrt()`, not libm `hypot`.**
   - geom's own `w.hypot(h)` on two floats does call libm, and stays `Darwin.hypot`.
3. **`D.powi(4)` on a constant is folded with the host `pow`.**
   - This happens in `approx_parabola_integral`, which is used by `flatten`.
   - Writing it as `(d*d)*(d*d)` was 1 ULP off. The port uses `pow(0.67, 4)`.
4. **A sine and cosine of the same value become one `__sincos_stret` call.**
   - In release builds LLVM merges the pair, and `__sincos_stret` differs from separate `sin`/`cos` for
     about 0.14% of inputs (measured: 2,798 of 2,000,000).
   - Every site where the Rust takes both of one value goes through `sinCos(_:)`.
   - Constant arguments (`45f64.to_radians().cos()`) are folded by LLVM with separate calls, so those
     sites stay `Darwin.sin`/`Darwin.cos`.
   - Swift results are the same in debug and release.
5. **Float `sum()` starts from -0.0.**
   - So an empty path's area is -0.0. `BezPath.area` reduces from -0.0.
6. **Saturating casts.** `as usize` saturates and maps NaN to 0. `asUsize(_:)` reproduces it, and the arc
   and flattening subdivision counts use it.
7. **`Vec2 / f64` multiplies by the reciprocal**, as kurbo does.

## Divergences from deckcraft

- `kurboSegments` skips a path that begins with `closePath`; kurbo would panic there. deckcraft's own paths
  never do this.
- The never-crash rules hold throughout: there are no force unwraps or traps; indices that come from input
  go through `.at(_:)` or are bounds-checked; casts saturate.

## DCColor

`crates/color/src/lib.rs` → `Sources/DCColor/Color.swift`. **Done.** All 7 Rust tests are ported, plus a check
of the JSON shape serde writes (8 tests).

- **Renames.** `apply` → `applyTransforms`, `preset` → `presetColor`, `PRESET_NAMES`/`SYSTEM_NAMES` →
  `presetColorNames`/`systemColorNames`. `ColorScheme.colors` is a `[Rgba]` that holds exactly 12 colours,
  length-checked on read.
- **Rust semantics.** `as u8` → `UInt8(rustCast:)`; `f64::clamp` → DCCore `clamped`; `str::trim` → DCCore
  `rustTrim`.
- **Signed zeros.** DCCore's `clamped`, `rustMin` and `rustMax` now treat signed zeros as Rust does on Apple
  silicon. The geometry port found the gap, and DCGeometry still uses its own copies, which agree.

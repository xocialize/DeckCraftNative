# DCRender — port notes

Port of deckcraft `crates/render` and `crates/pdf` at the pin in `Tools/oracle/pin.env`, onto CoreGraphics.
Status: **Wave 2**, with transitions and Morph (`transition.rs`, `morph_path.rs`, `morph_text.rs` and
`render_blend`) added in Wave 4. See "Transitions and Morph" below.

## How it draws

- **`Canvas`** is vello_cpu's `RenderContext` model on CoreGraphics. It has a current transform, paint, paint
  transform, fill rule and stroke. It fills and strokes kurbo paths, and its layers carry a clip, a mix and
  compose mode, an opacity and a Gaussian blur. Because of that, the ported drawing code reads as the Rust
  does.
  - Every layer is its own premultiplied RGBA8 bitmap, as in vello. A compose mode inside a layer
    (`DestIn`/`DestOut` for soft edges) therefore reaches only that layer's content.
  - Layers are composited back through CoreGraphics blend modes, over the whole canvas for the modes that
    change the backdrop where the layer is empty.
  - Blur is a true Gaussian (`vImageConvolve_PlanarF`), where vello decimates.
- **Strokes** are outlined in user space, as kurbo does before the transform. To keep curves smooth, the path
  is first scaled up by the transform's larger scale and then back down. Dashes come from CoreGraphics, not
  kurbo.
- **Text** glyphs are CoreText outlines (`CTFontCreatePathForGlyph`) filled like any path. Colour glyphs
  (COLR, sbix, CBDT, SVG) are drawn with `CTFontDrawGlyphs`, so `colr.rs` isn't ported.
- **Metafiles** (WMF/EMF) are parsed by DCMetafile and drawn by `MetafileRender`, which `Images.metafile`
  uses by default.
- **Pictures** decode with ImageIO and resample with vImage.

## Vector output (`DisplayList`): a departure from deckcraft

deckcraft's PDF is a raster of each slide with invisible text over it (its issue #14). Here a `Canvas` can
record instead of drawing (`Canvas(recordingWidth:height:)`, then `recording()`). The recording replays two
ways:

- **onto a raster canvas at any scale.** This is bit-identical to drawing directly; a test checks it.
- **into a CoreGraphics context as vectors.** Layers become transparency groups.

PDF can't express everything:

- A layer that **blurs**, or has a **compose mode inside it**, is drawn as a raster of its own content at the
  export's dpi.
- A layer that **composes onto the backdrop** (a top-level `DestOut`) makes the whole slide one raster.

The renderer records with `RenderOpts.record` (`recordSlide`). It records at the raster scale, so anything
the renderer itself draws as pixels (pictures, metafiles) keeps the detail the dpi asks for.

## PDF (`PDF`, `PDFWriter`, `PDF.export`)

- **Written by `CGPDFContext`.** Bookmarks use `CGPDFContextSetOutline`. Links are `setURL` and named
  destinations, one per page. Title, author and creator go in the info dictionary. CoreGraphics writes its
  own Producer and creation date, where deckcraft writes `DeckCraft` and none.
- **The text layer.** Each laid-out run is drawn as a CoreText line of its own characters, stretched over the
  run's extent: invisible over slides, visible for notes and handout master text. Drawn that way, CoreGraphics
  writes a correct ToUnicode map. Drawing bare glyph ids makes it guess from the cmap: Inter's shared ι/ɩ
  glyph came back as Latin ɩ. The glyphs are reshaped by CoreText, so a run's selection box matches the slide
  but the invisible glyphs may differ from the drawn ones (ligatures, contextual forms).
- **Fonts CoreGraphics can't embed.** deckcraft's `unembeddable_font_returns_error…` test has no counterpart:
  a font CoreText loads, CoreGraphics embeds.
- **Same as deckcraft:**
  - paper sizes, notes pages and handouts;
  - master header, date, footer and page-number text;
  - selection and hidden slides;
  - the `safeURL` filter on links.

## File map

| Rust | Swift |
|---|---|
| `lib.rs` (render entry points, `Renderer`, effects, groups, backgrounds) | `Render.swift` |
| `lib.rs` (text drawing, decorations, text effects), `warp.rs` | `TextDraw.swift` |
| `lib.rs` (small helpers) | `Helpers.swift` |
| `extent.rs` | `Extent.swift` |
| `placed.rs` | `Placed.swift` |
| `paint.rs` | `Paint.swift` |
| line drawing in `lib.rs` | `Stroke.swift` |
| `compound.rs` | `Compound.swift` (`CompoundLine`) |
| `ramp.rs`, `pattern.rs`, `pathgrad.rs` | `Ramp.swift`, `Pattern.swift`, `PathGradient.swift` |
| `images.rs`, image decoding in `lib.rs` | `Images.swift` |
| `metafile.rs` | `MetafileRender.swift` |
| `table.rs`, `chart.rs`, `chartex.rs`, `radar.rs` | `Table.swift`, `Chart.swift`, `ChartEx.swift`, `Radar.swift` |
| `camera.rs`, `light.rs`, `bevel.rs`, `extrude.rs` | `Camera.swift`, `Light.swift`, `Bevel.swift`, `Extrude.swift` |
| `colr.rs` | not ported (CoreText draws colour glyphs) |
| vello_cpu `RenderContext` | `Canvas.swift`, `DisplayList.swift` |
| `crates/pdf/src/lib.rs` | `PDF.swift` (plan, layout, writer), `PDFExport.swift` (export) |
| `transition.rs`, `render_blend` and `Renderer::blend` in `lib.rs` | `Transition.swift` |
| `morph_path.rs` | `MorphPath.swift` |
| `morph_text.rs` | `MorphText.swift` |

## Parity

`RenderParityTests` renders every slide of every corpus deck at scale 2 and scores it with SSIMULACRA2
(media-bridge MediaMeasureCore) against the oracle's PNG. Each deck writes
`.build-parity/render-parity/report-<deck>.json`. Slides within 20 points of the threshold also leave both
PNGs there, so they can be compared side by side.

Measured 2026-10-26 over the 90 slides of the 18 corpus decks: 9 decks and their `.pptx` round trips. Wave 3
added the charts, SmartArt, effects, motion and review decks.

| Deck | Slides | SSIMULACRA2 min | Mean |
|---|---:|---:|---:|
| sample | 8 | 90.6 | 91.3 |
| content | 5 | 90.6 | 94.1 |
| shapes | 2 | 91.6 | 95.8 |
| text | 4 | 92.1 | 94.6 |
| charts | 6 | 89.8 | 92.5 |
| smartart | 6 | 91.3 | 94.1 |
| effects | 3 | 89.2 | 93.4 |
| motion | 4 | 91.1 | 94.7 |
| review | 5 | 92.8 | 93.9 |

The `.from-pptx` copies score the same as their originals. Text and edge anti-aliasing account for most of the
remaining difference. The test's floor is 88.

The effects deck first scored 57.4 on its picture slide. It stretches an 8 px picture across hundreds of
pixels. CoreGraphics quantises its interpolation weights to about eighths of a source pixel, which showed as
soft blocks. The raster canvas now enlarges a picture magnified 2× or more with exact bilinear sampling
(`Upscale.swift`) before drawing it.

Run it in release, since SSIMULACRA2 in a debug build takes minutes per deck:

```bash
swift test -c release -Xswiftc -enable-testing --filter RenderParityTests --scratch-path .build-parity-run
```

## Divergences

- Anti-aliasing, the image filters (vImage and CoreGraphics interpolation) and Gaussian blur differ from
  vello at the pixel level. Pixel tests keep the Rust tolerances except where noted at the test.
- Pictures magnified 2× or more are enlarged by exact bilinear sampling before CoreGraphics draws them
  (`Upscale`); PDF output keeps the original image.
- Pattern fills sample their tile in Swift (bilinear, as vello does), because CoreGraphics area-averages
  sub-pixel cells into other colours.
- The image cache is keyed by the media bytes' storage plus the exact adjustments, not by a hash.

## Transitions and Morph (Wave 4)

These sit on DCAnim, which computes the transition layers, meshes and Morph frames.

### What's here

- **The CPU compositor.** `compositeTransition(old, new, parts, layers)` draws DCAnim's `transitionFrame` over
  black: every layer's `layerMesh` triangles, sampled bilinearly from premultiplied RGBA8 and blended source-over.
  The arithmetic is deckcraft's: f64 edge functions with its pixel-centre nudge, then f32 sampling and blending.
  `SlideParts` holds the background and content renders of both slides (`renderSlidePart`) for the transitions
  that move contents over backgrounds (`usesSlideParts`).
  - `renderTransition(pres, index, t, opts)` gives one frame. It is the headless twin of the show's Metal
    compositor, which draws the same meshes.
  - DCRender re-exports `Layer`, `Source`, `transitionFrame`, `transitionLayers` and `usesSlideParts`, as
    deckcraft-render re-exports them.
- **Morph frames.** `renderBlend(pres, old, new, mix, shapes, text, paths, opts)` does what `render_blend` does:
  1. it cross-fades the two backdrops;
  2. it draws DCAnim's `MorphFrame` shapes, each resolved against its own slide;
  3. it draws text pairs (`TextMorph`) by words or characters (`MorphTextDraw`);
  4. it morphs outlines (`PathMorph`): DCGeometry's `GeometryMorph`, with a fade per sub-path for fills and lines
     only one side has.
  `renderTransition` uses it for Morph, as deckcraft does.
- **Changes to `Render.swift`.** Outline morphs reach into the shape renderer, as in the Rust, so Wave 4 added
  three things there:
  - the `paths` and `morphs` the `Renderer` keeps;
  - the morph-aware geometry at the top of `geometryShape`;
  - a per-sub-path `fade` passed to `fillGeometry`, the fill overlay and `drawOutline`. These pass the opacity the
    Wave 2 code already took as `1`.

  Nothing changes for a shape that isn't morphing.

### Divergences

- **The outline-morph cache is shared.** deckcraft keeps aligned outlines in each thread's long-lived renderer. A
  `Renderer` here lives for one frame, so `MorphPathCache.shared` keeps them across frames, under a lock, swept at
  the end of each `blend` as in the Rust. It is capped at 256 entries.
- **No panic guard.** `render_blend` and `render_slide_part` catch panics and draw a blank or the new slide.
  Swift has no unwinding. The ported code checks its input instead (indices, sizes, non-finite numbers).
- **Unchecked pointers, checked indices.** The compositor's per-pixel loop reads and writes through unsafe buffer
  pointers, but checks every index against the buffer first. Unoptimised, Swift's generic conversions and SIMD
  subscripts made it about twice as slow.

### Parity

- **The compositor is bit-identical to deckcraft-render's `composite_transition`** (`CompositeVectorTests`). The
  test covers 3,720 frames: every transition and option at 5 times, composited from generated images with and
  without an old slide and with and without slide parts. The anim-vectors tool writes the hashes
  (DCAnim/PORT-NOTES.md).
- **Frames against the oracle's PNGs** (`TransitionParityTests`):
  - all 45 transition frames of the corpus (sample, content and motion decks, at 0.25, 0.5 and 0.75, scale 2),
    Morph included;
  - 112 frames of `Tools/oracle/engine-scripts/transitions.cmds`: every transition kind on slides with their own
    backgrounds and contents, and Morph by objects, words and characters. Drawn by anim-vectors/run.sh with
    `render-transition --width 640`, at 0.35 and 0.65.

  Measured 2026-10-26 (SSIMULACRA2, and the largest share of pixels more than 8 levels apart):

  | Deck | Frames | Min | Mean | Differing ≤ |
  |---|---:|---:|---:|---:|
  | sample | 24 | 90.2 | 91.9 | 0.56% |
  | content | 12 | 90.6 | 93.6 | 0.13% |
  | motion | 9 | 91.1 | 94.7 | 0.08% |
  | transitions | 112 | 89.0 | 92.6 | 0.47% |

  The floors are 88 for the corpus and 87 for the transitions deck. The Morph frames score 89.9–93.6; its words and
  characters frames score 89.9–93.2. As with slides, the rest is anti-aliasing: the compositing itself is exact.
  Run it in release:

  ```bash
  swift test -c release -Xswiftc -enable-testing --filter TransitionParityTests --scratch-path .build-anim-rel
  ```

  The report is `.build-parity/transition-parity/report-<deck>.json`.
- **Tests.** All 6 in-file tests of `transition.rs` are ported (`TransitionRenderTests`): compositing, the
  PowerPoint probes, every transition starting old and ending new, and dynamic content. So are the 6 Morph tests of
  `tests.rs` that Wave 2 skipped: `render_blend` ends and backdrops, text tokens, text and path morph ends, fill
  fades, and aligning once per transition.

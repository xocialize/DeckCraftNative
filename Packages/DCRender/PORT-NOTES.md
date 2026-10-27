# DCRender — port notes

Port of deckcraft `crates/render` and `crates/pdf` at the pin in `Tools/oracle/pin.env`, onto CoreGraphics.
Status: **Wave 2**. Morph, transitions and animation frames (`morph_path.rs`, `morph_text.rs`,
`transition.rs`) belong to Wave 4.

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

## Parity

`RenderParityTests` renders every slide of every corpus deck at scale 2 and scores it with SSIMULACRA2
(media-bridge MediaMeasureCore) against the oracle's PNG. Each deck writes
`.build-parity/render-parity/report-<deck>.json`. Slides within 20 points of the threshold also leave both
PNGs there, so they can be compared side by side.

Measured 2026-10-26 over the 38 slides of the 8 corpus decks (4 decks and their `.pptx` round trips):

| Deck | Slides | SSIMULACRA2 min | Mean |
|---|---:|---:|---:|
| sample | 8 | 90.6 | 91.3 |
| content | 5 | 90.6 | 94.1 |
| shapes | 2 | 91.6 | 95.8 |
| text | 4 | 92.1 | 94.6 |

The `.from-pptx` copies score the same as their originals. At most 0.56% of a slide's pixels differ by more
than 8 levels: anti-aliasing and text edges. The test's floor is 88.

Run it in release, since SSIMULACRA2 in a debug build takes minutes per deck:

```bash
swift test -c release -Xswiftc -enable-testing --filter RenderParityTests --scratch-path .build-parity-run
```

## Divergences

- Anti-aliasing, the image filters (vImage and CoreGraphics interpolation) and Gaussian blur differ from
  vello at the pixel level. Pixel tests keep the Rust tolerances except where noted at the test.
- Pattern fills sample their tile in Swift (bilinear, as vello does), because CoreGraphics area-averages
  sub-pixel cells into other colours.
- The image cache is keyed by the media bytes' storage plus the exact adjustments, not by a hash.

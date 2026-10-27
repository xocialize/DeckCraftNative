# Attribution

Every third-party asset DeckCraftNative ships in its app bundle or DMG, with its author, source and licence.
Code ported from deckcraft and craft-libs names its source file and licence in each file's header (README,
"Attribution"); this file lists assets.

DeckCraftNative contains **no ArtCraft marks** (the ArtCraft name as a brand, wordmark or logo; deckcraft
`docs/brand/LICENSE-brand.txt`). As that licence allows a work based on DeckCraft, About says in plain text that
DeckCraftNative is based on DeckCraft by the ArtCraft team. It contains no Microsoft, Adobe, Avid or Autodesk
iconography, images, fonts, themes or templates.

## Shipped in the app

| Asset | Author | Source | Licence | Used for |
|---|---|---|---|---|
| `Apps/DeckCraftNative/App/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512}.png` | DeckCraft contributors | deckcraft `assets/app-icon/hicolor/<n>x<n>/apps/ai.storyteller.deckcraft.png` at pin `27009cd9`, unmodified (deckcraft `ATTRIBUTION.md`: rendered by DeckCraft from `assets/app-icon/icon-source.deckcraft`, shapes only) | MIT OR Apache-2.0 (deckcraft `LICENSE-MIT`, `LICENSE-APACHE`; © 2026 ArtCraft Team and the DeckCraft contributors) | The app icon (placeholder presentation board, as in deckcraft) |
| `Apps/DeckCraftNative/App/Assets.xcassets/AppIcon.appiconset/icon_1024.png` | DeckCraft contributors | deckcraft `assets/app-icon/deckcraft-1024.png` at pin `27009cd9`, unmodified | MIT OR Apache-2.0 (as above) | The app icon at 512 pt @2x |

## Considered and not shipped

| Asset | Why not |
|---|---|
| deckcraft `packaging/macos/dmg/background.{svg,tiff}` and `dmg-layout.DS_Store` (@XusBadia, MIT OR Apache-2.0) | The licence allows it, but the artwork's title reads "DeckCraft" (outlined glyphs, so it can't be retitled without regenerating it with resvg and Inter), and the Finder layout is bound to a volume named `DeckCraft` and an app named `DeckCraft.app`. The DMG is plain (the app and an Applications link) until a DeckCraftNative background is drawn. |

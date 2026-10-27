// swift-tools-version: 6.2
// DeckCraftNative — deckcraft on Swift (macOS 26+, Apple Silicon). The one manifest for the whole
// repository: every package under `Packages/` is a group of targets here, each exported as a product,
// so other repos can depend on this one by URL (SwiftPM can't consume a package from a repo's subfolder).
//
// Targets keep their sources at `Packages/<package>/{Sources,Tests}/<target>` and follow deckcraft's
// crate layers (PLAN.md §3–4): a target depends only on lower layers, and nothing here imports AppKit
// or SwiftUI — the app is its own Xcode target (wave 5). Ports deckcraft (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors); every ported file names its source and licence.
//
// Fleet packages come by versioned URL in the wave that needs them: media-bridge's MediaMeasureCore
// (SSIMULACRA2, test support only) since Wave 2; media-bridge for DCMedia and modelcontextprotocol/swift-sdk
// for DCAutomation in Wave 4. Test data stays outside git, at `DECKCRAFT_FIXTURES`
// (default `../DeckCraftNative-Fixtures`); tests that need it skip without it.
import PackageDescription

/// `Packages/<package>/Sources/<target>`.
func sources(_ package: String, _ target: String) -> String { "Packages/\(package)/Sources/\(target)" }
/// `Packages/<package>/Tests/<target>`.
func tests(_ package: String, _ target: String) -> String { "Packages/\(package)/Tests/\(target)" }

let package = Package(
    name: "DeckCraftNative",
    platforms: [.macOS(.v26)],
    products: [
        // L0
        .library(name: "DCCore", targets: ["DCCore"]),
        .library(name: "DCZip", targets: ["DCZip"]),
        .library(name: "DCGeometry", targets: ["DCGeometry"]),
        .library(name: "DCColor", targets: ["DCColor"]),
        .library(name: "DCMetafile", targets: ["DCMetafile"]),
        // L1
        .library(name: "DCModel", targets: ["DCModel"]),
        // L2
        .library(name: "DCText", targets: ["DCText"]),
        .library(name: "DCAnim", targets: ["DCAnim"]),
        .library(name: "DCFormat", targets: ["DCFormat"]),
        .library(name: "DCMedia", targets: ["DCMedia"]),
        // L3–L4
        .library(name: "DCRender", targets: ["DCRender"]),
        .library(name: "DCPPTX", targets: ["DCPPTX"]),
        // L5–L6
        .library(name: "DCEngine", targets: ["DCEngine"]),
        .library(name: "DCAutomation", targets: ["DCAutomation"]),
        .executable(name: "dccli", targets: ["dccli"]),
        // Tests' access to the fixtures and the upstream pin
        .library(name: "DCTestSupport", targets: ["DCTestSupport"]),
    ],
    dependencies: [
        // SSIMULACRA2 for render parity (DCTestSupport only): media-bridge's dependency-free metric core.
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.40.0"),
    ],
    targets: [
        // MARK: DCCore — serde_json-compatible JSON (value, writer, parser, serde-style coding) and
        // Rust's numeric semantics (saturating casts, NaN-propagating clamp). Every package builds on it.
        .target(name: "DCCore", path: sources("DCCore", "DCCore")),
        .testTarget(name: "DCCoreTests", dependencies: ["DCCore", "DCTestSupport"], path: tests("DCCore", "DCCoreTests")),

        // MARK: DCZip — ZIP (ZIP64 included) and raw DEFLATE through Apple's Compression framework, from
        // PhotoCraftNative. Used by DCFormat and DCPPTX.
        .target(name: "DCZip", path: sources("DCZip", "DCZip")),
        .testTarget(name: "DCZipTests", dependencies: ["DCZip"], path: tests("DCZip", "DCZipTests")),

        // MARK: DCFoundation — EMU/pt units, transforms, preset shapes, warps (deckcraft-geom);
        // RGB/HSL and DrawingML colour transforms (deckcraft-color). Wave 1.
        .target(name: "DCGeometry", dependencies: ["DCCore"], path: sources("DCFoundation", "DCGeometry")),
        .testTarget(name: "DCGeometryTests", dependencies: ["DCGeometry", "DCCore", "DCTestSupport"], path: tests("DCFoundation", "DCGeometryTests")),
        .target(name: "DCColor", dependencies: ["DCCore"], path: sources("DCFoundation", "DCColor")),
        .testTarget(name: "DCColorTests", dependencies: ["DCColor", "DCCore"], path: tests("DCFoundation", "DCColorTests")),

        // MARK: DCMetafile — EMF, EMF+ and WMF read into a neutral vector model (deckcraft-metafile). Wave 2.
        .target(name: "DCMetafile", dependencies: ["DCCore"], path: sources("DCMetafile", "DCMetafile")),
        .testTarget(name: "DCMetafileTests", dependencies: ["DCMetafile", "DCCore", "DCTestSupport"], path: tests("DCMetafile", "DCMetafileTests")),

        // MARK: DCModel — presentation, masters, layouts, slides, shapes, text, tables, charts,
        // animations, placeholder inheritance (deckcraft-model). Wave 1.
        .target(name: "DCModel", dependencies: ["DCCore", "DCGeometry", "DCColor"], path: sources("DCModel", "DCModel")),
        .testTarget(name: "DCModelTests", dependencies: ["DCModel", "DCCore", "DCGeometry", "DCColor", "DCTestSupport"], path: tests("DCModel", "DCModelTests")),

        // MARK: DCText — CoreText layout under deckcraft's autofit, bullets, columns, caret and field
        // rules; the font substitutes (deckcraft-text, -fonts). Wave 2.
        .target(name: "DCText", dependencies: ["DCCore", "DCModel", "DCGeometry", "DCColor"], path: sources("DCText", "DCText")),
        .testTarget(name: "DCTextTests", dependencies: ["DCText", "DCModel", "DCGeometry", "DCColor", "DCCore", "DCTestSupport"], path: tests("DCText", "DCTextTests")),

        // MARK: DCAnim — timeline, show state machine, transition frames, Morph (deckcraft-anim). Wave 4.
        .target(name: "DCAnim", dependencies: ["DCModel", "DCGeometry"], path: sources("DCAnim", "DCAnim")),

        // MARK: DCFormat — `.deckcraft` (zip + JSON + media), outline text, RTF (deckcraft-format). Wave 1.
        .target(name: "DCFormat", dependencies: ["DCCore", "DCZip", "DCModel"], path: sources("DCFormat", "DCFormat")),
        .testTarget(name: "DCFormatTests", dependencies: ["DCFormat", "DCModel", "DCCore", "DCZip", "DCTestSupport"], path: tests("DCFormat", "DCFormatTests")),

        // MARK: DCMedia — AVFoundation and media-bridge in place of deckcraft-media and its codec
        // crates. Wave 4.
        .target(name: "DCMedia", path: sources("DCMedia", "DCMedia")),

        // MARK: DCRender — the CoreGraphics slide renderer, PDF through CGPDFContext, Metal transition
        // compositing (deckcraft-render, -pdf). Wave 2.
        .target(
            name: "DCRender",
            dependencies: ["DCCore", "DCGeometry", "DCColor", "DCMetafile", "DCModel", "DCAnim", "DCText"],
            path: sources("DCRender", "DCRender")
        ),
        .testTarget(
            name: "DCRenderTests",
            dependencies: ["DCRender", "DCText", "DCModel", "DCFormat", "DCGeometry", "DCColor", "DCCore", "DCTestSupport"],
            path: tests("DCRender", "DCRenderTests")
        ),

        // MARK: DCPPTX — PPTX read and write from ECMA-376 (deckcraft-pptx). Wave 3.
        .target(name: "DCPPTX", dependencies: ["DCModel", "DCGeometry", "DCColor", "DCZip", "DCCore"], path: sources("DCPPTX", "DCPPTX")),
        .testTarget(
            name: "DCPPTXTests",
            dependencies: ["DCPPTX", "DCModel", "DCFormat", "DCRender", "DCGeometry", "DCColor", "DCZip", "DCCore", "DCTestSupport"],
            path: tests("DCPPTX", "DCPPTXTests")
        ),

        // MARK: DCEngine — Session, history, the command registry, tools, keys, AutoRecover, the
        // sample deck (deckcraft-engine). Wave 4.
        .target(
            name: "DCEngine",
            dependencies: ["DCGeometry", "DCColor", "DCModel", "DCText", "DCRender", "DCFormat", "DCPPTX", "DCMedia"],
            path: sources("DCEngine", "DCEngine")
        ),

        // MARK: DCAutomation — the JSON control channel and the MCP server (deckcraft-mcp,
        // ui-egui's control.rs). Wave 4.
        .target(name: "DCAutomation", dependencies: ["DCEngine", "DCRender"], path: sources("DCAutomation", "DCAutomation")),
        .executableTarget(name: "dccli", dependencies: ["DCEngine", "DCAutomation"], path: "Apps/dccli"),

        // MARK: DCTestSupport — the fixtures root and the upstream pin, for every test target.
        .target(
            name: "DCTestSupport",
            dependencies: [.product(name: "MediaMeasureCore", package: "media-bridge")],
            path: sources("DCTestSupport", "DCTestSupport")
        ),
        .testTarget(name: "DCTestSupportTests", dependencies: ["DCTestSupport"], path: tests("DCTestSupport", "DCTestSupportTests")),
    ]
)

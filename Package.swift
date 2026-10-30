// swift-tools-version: 6.2
// DeckCraftNative — deckcraft on Swift (macOS 26+, Apple Silicon). The one manifest for the whole
// repository: every package under `Packages/` is a group of targets here, each exported as a product,
// so other repos can depend on this one by URL (SwiftPM can't consume a package from a repo's subfolder).
//
// Targets keep their sources at `Packages/<package>/{Sources,Tests}/<target>` and follow deckcraft's
// crate layers (PLAN.md §3–4): a target depends only on lower layers, and nothing below the app layer
// imports AppKit or SwiftUI. The app's code is the `DCApp` library (L7) so it builds and tests with
// `swift test`; `Apps/DeckCraftNative` is a thin Xcode wrapper around it, and `DeckCraftDev` runs it unbundled. Ports deckcraft (MIT OR Apache-2.0,
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
    // The app's user-visible strings are in String Catalogs (`Resources/*.xcstrings` in DCAppModel and DCApp);
    // English is the source language.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        // L0
        .library(name: "DCCore", targets: ["DCCore"]),
        .library(name: "DCZip", targets: ["DCZip"]),
        .library(name: "DCCFB", targets: ["DCCFB"]),
        .library(name: "DCGeometry", targets: ["DCGeometry"]),
        .library(name: "DCColor", targets: ["DCColor"]),
        .library(name: "DCMetafile", targets: ["DCMetafile"]),
        // L1
        .library(name: "DCModel", targets: ["DCModel"]),
        .library(name: "DCOffCrypto", targets: ["DCOffCrypto"]),
        // L2
        .library(name: "DCText", targets: ["DCText"]),
        .library(name: "DCAnim", targets: ["DCAnim"]),
        .library(name: "DCFormat", targets: ["DCFormat"]),
        .library(name: "DCMedia", targets: ["DCMedia"]),
        // L3–L4
        .library(name: "DCRender", targets: ["DCRender"]),
        .library(name: "DCPPTX", targets: ["DCPPTX"]),
        .library(name: "DCPPT", targets: ["DCPPT"]),
        // L5–L6
        .library(name: "DCEngine", targets: ["DCEngine"]),
        .library(name: "DCAutomation", targets: ["DCAutomation"]),
        .executable(name: "dccli", targets: ["dccli"]),
        // L7: the app. DCAppModel is its window-free state and UI commands; DCApp is AppKit and SwiftUI.
        .library(name: "DCAppModel", targets: ["DCAppModel"]),
        .library(name: "DCApp", targets: ["DCApp"]),
        .executable(name: "DeckCraftDev", targets: ["DeckCraftDev"]),
        // L7: the app's Quick Look and Spotlight extensions (the appex targets in Apps/DeckCraftNative link these).
        .library(name: "DCQuickLook", targets: ["DCQuickLook"]),
        .library(name: "DCSpotlight", targets: ["DCSpotlight"]),
        // L7: the file intents the App Intents extension runs (and the app lists).
        .library(name: "DCIntentsKit", targets: ["DCIntentsKit"]),
        // Tests' access to the fixtures and the upstream pin
        .library(name: "DCTestSupport", targets: ["DCTestSupport"]),
    ],
    dependencies: [
        // SSIMULACRA2 for render parity (DCTestSupport only): media-bridge's dependency-free metric core.
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.40.0"),
        // The official MCP Swift SDK (DCAutomation), at the version PhotoCraftNative uses.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        // dccli's subcommands.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // The fleet's design vocabulary (AB-D-0042): tokens and shared components for the app's UI.
        .package(url: "https://github.com/xocialize/DesignScaffold.git", from: "0.25.0"),
        // VP9 and VP8 decoding (libvpx, BSD-3), plugged into DCMedia's external-decoder seam by the app and dccli.
        // DCMedia itself stays free of it (PLAN.md §10.4, decided 2026-10-27).
        .package(url: "https://github.com/xocialize/vpx-swift.git", from: "0.3.1"),
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

        // MARK: DCCFB — the Compound File Binary format ([MS-CFB]), read and written: the container of password-
        // protected OOXML and of legacy .ppt (Docs/plans/Legacy-PPT-and-Encryption.md, E1). No dependencies.
        .target(name: "DCCFB", path: sources("DCCFB", "DCCFB")),
        .testTarget(name: "DCCFBTests", dependencies: ["DCCFB", "DCTestSupport"], path: tests("DCCFB", "DCCFBTests")),

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
        // MARK: DCOffCrypto — password-protected OOXML ([MS-OFFCRYPTO]): Agile and Standard encryption, read
        // (and, from E3, written) through CommonCrypto (Docs/plans/Legacy-PPT-and-Encryption.md, E2).
        .target(name: "DCOffCrypto", dependencies: ["DCCFB"], path: sources("DCOffCrypto", "DCOffCrypto")),
        .testTarget(name: "DCOffCryptoTests", dependencies: ["DCOffCrypto", "DCCFB", "DCTestSupport"], path: tests("DCOffCrypto", "DCOffCryptoTests")),

        .target(name: "DCModel", dependencies: ["DCCore", "DCGeometry", "DCColor"], path: sources("DCModel", "DCModel")),
        .testTarget(name: "DCModelTests", dependencies: ["DCModel", "DCCore", "DCGeometry", "DCColor", "DCTestSupport"], path: tests("DCModel", "DCModelTests")),

        // MARK: DCText — CoreText layout under deckcraft's autofit, bullets, columns, caret and field
        // rules; the font substitutes (deckcraft-text, -fonts). Wave 2.
        .target(name: "DCText", dependencies: ["DCCore", "DCModel", "DCGeometry", "DCColor"], path: sources("DCText", "DCText")),
        .testTarget(name: "DCTextTests", dependencies: ["DCText", "DCModel", "DCGeometry", "DCColor", "DCCore", "DCTestSupport"], path: tests("DCText", "DCTextTests")),

        // MARK: DCAnim — timeline, show state machine, transition frames, Morph (deckcraft-anim). Wave 4.
        .target(name: "DCAnim", dependencies: ["DCModel", "DCGeometry", "DCColor", "DCCore"], path: sources("DCAnim", "DCAnim")),
        .testTarget(
            name: "DCAnimTests",
            dependencies: ["DCAnim", "DCModel", "DCGeometry", "DCColor", "DCCore", "DCFormat", "DCTestSupport"],
            path: tests("DCAnim", "DCAnimTests")
        ),

        // MARK: DCFormat — `.deckcraft` (zip + JSON + media), outline text, RTF (deckcraft-format). Wave 1.
        .target(name: "DCFormat", dependencies: ["DCCore", "DCZip", "DCModel"], path: sources("DCFormat", "DCFormat")),
        .testTarget(name: "DCFormatTests", dependencies: ["DCFormat", "DCModel", "DCCore", "DCZip", "DCTestSupport"], path: tests("DCFormat", "DCFormatTests")),

        // MARK: DCMedia — AVFoundation and media-bridge in place of deckcraft-media and its codec
        // crates. Wave 4.
        .target(
            name: "DCMedia",
            dependencies: ["DCCore", .product(name: "MediaImport", package: "media-bridge")],
            path: sources("DCMedia", "DCMedia")
        ),
        .testTarget(name: "DCMediaTests", dependencies: ["DCMedia", "DCCore", "DCTestSupport"], path: tests("DCMedia", "DCMediaTests")),

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
        // MARK: DCPPT — legacy binary PowerPoint (.ppt, [MS-PPT] and [MS-ODRAW]) read into DCModel (Docs/plans/
        // Legacy-PPT-and-Encryption.md, P1–P6); its compound file is DCCFB's and its encryption DCOffCrypto's.
        .target(name: "DCPPT", dependencies: ["DCModel", "DCGeometry", "DCColor", "DCCore", "DCCFB", "DCOffCrypto"], path: sources("DCPPT", "DCPPT")),
        .testTarget(name: "DCPPTTests", dependencies: ["DCPPT", "DCModel", "DCGeometry", "DCCFB", "DCOffCrypto", "DCTestSupport"], path: tests("DCPPT", "DCPPTTests")),

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
            dependencies: ["DCCore", "DCGeometry", "DCColor", "DCModel", "DCText", "DCRender", "DCFormat", "DCPPTX", "DCMedia", "DCZip", "DCOffCrypto", "DCPPT"],
            path: sources("DCEngine", "DCEngine")
        ),
        .testTarget(
            name: "DCEngineTests",
            dependencies: ["DCEngine", "DCAnim", "DCCore", "DCGeometry", "DCColor", "DCModel", "DCText", "DCRender", "DCFormat", "DCPPTX", "DCMedia", "DCZip", "DCTestSupport"],
            path: tests("DCEngine", "DCEngineTests")
        ),

        // MARK: DCAutomation — the JSON control channel and the MCP server (deckcraft-mcp,
        // ui-egui's control.rs). Wave 4.
        .target(
            name: "DCAutomation",
            dependencies: ["DCEngine", "DCRender", "DCModel", "DCGeometry", "DCColor", "DCCore", .product(name: "MCP", package: "swift-sdk")],
            path: sources("DCAutomation", "DCAutomation")
        ),
        .testTarget(
            name: "DCAutomationTests",
            dependencies: ["DCAutomation", "DCEngine", "DCCore", "DCTestSupport", .product(name: "MCP", package: "swift-sdk")],
            path: tests("DCAutomation", "DCAutomationTests")
        ),
        .executableTarget(
            name: "dccli",
            dependencies: [
                "DCEngine", "DCAutomation", "DCRender", "DCAnim", "DCMedia", "DCModel", "DCCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "VpxSwift", package: "vpx-swift"),
            ],
            path: "Apps/dccli"
        ),
        .testTarget(
            name: "dccliTests",
            dependencies: [
                "dccli", "DCAutomation", "DCEngine", "DCRender", "DCModel", "DCCore", "DCZip", "DCTestSupport",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Apps/dccliTests"
        ),

        // MARK: DCAppModel — the app's state without a window (ui-egui's SlideApp logic): UiState, the UI-only
        // commands, the menu tree, the palette, and routing between them and the engine. No AppKit. Wave 5.
        .target(
            name: "DCAppModel",
            dependencies: ["DCEngine", "DCAutomation", "DCRender", "DCAnim", "DCMedia", "DCFormat", "DCModel", "DCText", "DCGeometry", "DCColor", "DCCore"],
            path: sources("DCApp", "DCAppModel"),
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DCAppModelTests",
            dependencies: ["DCAppModel", "DCEngine", "DCAutomation", "DCModel", "DCCore", "DCTestSupport"],
            path: tests("DCApp", "DCAppModelTests")
        ),

        // MARK: DCApp — the Mac app: NSDocument windows, the canvas, navigator and inspector, menus and toolbar,
        // the slide show, the control server's host (ui-egui, apps/deckcraft). Wave 5.
        .target(
            name: "DCApp",
            dependencies: [
                "DCAppModel", "DCEngine", "DCAutomation", "DCRender", "DCAnim", "DCMedia", "DCModel", "DCGeometry", "DCCore",
                "DCIntentsKit", "DCSpotlight",
                .product(name: "DesignScaffold", package: "DesignScaffold"),
                .product(name: "VpxSwift", package: "vpx-swift"),
                .product(name: "DesignScaffoldPicker", package: "DesignScaffold"),
            ],
            path: sources("DCApp", "DCApp"),
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DCAppTests",
            dependencies: ["DCApp", "DCAppModel", "DCEngine", "DCAutomation", "DCRender", "DCModel", "DCCore", "DCTestSupport", "DCIntentsKit", "DCSpotlight"],
            path: tests("DCApp", "DCAppTests")
        ),
        // The app run from SwiftPM, without a bundle: what agents and tests launch (`swift run DeckCraftDev
        // --control 4242 --sample`). The Xcode wrapper has the same one-line entry point.
        .executableTarget(name: "DeckCraftDev", dependencies: ["DCApp"], path: "Apps/DeckCraftDev"),

        // MARK: DCExtensions — the Quick Look preview and thumbnail and the Spotlight importer: reading a file within
        // an extension's budget (DCExtensionKit), the PDF preview and the first-slide thumbnail (DCQuickLook), the
        // attributes and text Spotlight indexes (DCSpotlight). No AppKit. Wave 6.
        .target(
            name: "DCExtensionKit",
            dependencies: ["DCEngine", "DCFormat", "DCPPTX", "DCText", "DCModel", "DCZip", "DCCore"],
            path: sources("DCExtensions", "DCExtensionKit")
        ),
        .target(
            name: "DCQuickLook",
            dependencies: ["DCExtensionKit", "DCEngine", "DCRender", "DCModel", "DCCore"],
            path: sources("DCExtensions", "DCQuickLook"),
            resources: [.process("Resources")]
        ),
        .target(name: "DCSpotlight", dependencies: ["DCExtensionKit", "DCModel", "DCCore"], path: sources("DCExtensions", "DCSpotlight")),
        .testTarget(
            name: "DCExtensionsTests",
            dependencies: ["DCQuickLook", "DCSpotlight", "DCExtensionKit", "DCEngine", "DCRender", "DCModel", "DCZip", "DCCore", "DCTestSupport"],
            path: tests("DCExtensions", "DCExtensionsTests")
        ),
        // The file intents (Export Presentation, Get Outline, Get Slide Count) as an App Intents package: the App
        // Intents extension runs them without launching the app, and DCApp includes them so the app's App
        // Shortcuts can name them. No AppKit. Wave 6.
        .target(
            name: "DCIntentsKit",
            dependencies: ["DCExtensionKit", "DCEngine", "DCCore"],
            path: sources("DCExtensions", "DCIntentsKit"),
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DCIntentsKitTests",
            dependencies: ["DCIntentsKit", "DCEngine", "DCCore", "DCTestSupport"],
            path: tests("DCExtensions", "DCIntentsKitTests")
        ),

        // MARK: DCTestSupport — the fixtures root and the upstream pin, for every test target.
        .target(
            name: "DCTestSupport",
            dependencies: [.product(name: "MediaMeasureCore", package: "media-bridge")],
            path: sources("DCTestSupport", "DCTestSupport")
        ),
        .testTarget(name: "DCTestSupportTests", dependencies: ["DCTestSupport"], path: tests("DCTestSupport", "DCTestSupportTests")),
    ]
)

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
        .library(name: "DCGeometry", targets: ["DCGeometry"]),
        .library(name: "DCColor", targets: ["DCColor"]),
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
        // The base packages shared with Marquee Documents (moved out of this repo 2026-11-01): CNCore, CNZip,
        // CNCFB, CNOffCrypto, CNMetafile.
        .package(url: "https://github.com/xocialize/CraftNativeKit.git", from: "0.1.0"),
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
        // CNCore (serde_json-compatible JSON, Rust semantics), CNZip, CNCFB, CNOffCrypto and CNMetafile were targets
        // here until 2026-11-01; they are CraftNativeKit's products now (its README; history up to the move is in
        // PORT-STATUS.md).

        // MARK: DCFoundation — EMU/pt units, transforms, preset shapes, warps (deckcraft-geom);
        // RGB/HSL and DrawingML colour transforms (deckcraft-color). Wave 1.
        .target(name: "DCGeometry", dependencies: [.product(name: "CNCore", package: "CraftNativeKit")], path: sources("DCFoundation", "DCGeometry")),
        .testTarget(name: "DCGeometryTests", dependencies: ["DCGeometry", .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport"], path: tests("DCFoundation", "DCGeometryTests")),
        .target(name: "DCColor", dependencies: [.product(name: "CNCore", package: "CraftNativeKit")], path: sources("DCFoundation", "DCColor")),
        .testTarget(name: "DCColorTests", dependencies: ["DCColor", .product(name: "CNCore", package: "CraftNativeKit")], path: tests("DCFoundation", "DCColorTests")),

        // MARK: DCModel — presentation, masters, layouts, slides, shapes, text, tables, charts,
        // animations, placeholder inheritance (deckcraft-model). Wave 1.
        .target(name: "DCModel", dependencies: [.product(name: "CNCore", package: "CraftNativeKit"), "DCGeometry", "DCColor"], path: sources("DCModel", "DCModel")),
        .testTarget(name: "DCModelTests", dependencies: ["DCModel", .product(name: "CNCore", package: "CraftNativeKit"), "DCGeometry", "DCColor", "DCTestSupport"], path: tests("DCModel", "DCModelTests")),

        // MARK: DCText — CoreText layout under deckcraft's autofit, bullets, columns, caret and field
        // rules; the font substitutes (deckcraft-text, -fonts). Wave 2.
        .target(name: "DCText", dependencies: [.product(name: "CNCore", package: "CraftNativeKit"), "DCModel", "DCGeometry", "DCColor"], path: sources("DCText", "DCText")),
        .testTarget(name: "DCTextTests", dependencies: ["DCText", "DCModel", "DCGeometry", "DCColor", .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport"], path: tests("DCText", "DCTextTests")),

        // MARK: DCAnim — timeline, show state machine, transition frames, Morph (deckcraft-anim). Wave 4.
        .target(name: "DCAnim", dependencies: ["DCModel", "DCGeometry", "DCColor", .product(name: "CNCore", package: "CraftNativeKit")], path: sources("DCAnim", "DCAnim")),
        .testTarget(
            name: "DCAnimTests",
            dependencies: ["DCAnim", "DCModel", "DCGeometry", "DCColor", .product(name: "CNCore", package: "CraftNativeKit"), "DCFormat", "DCTestSupport"],
            path: tests("DCAnim", "DCAnimTests")
        ),

        // MARK: DCFormat — `.deckcraft` (zip + JSON + media), outline text, RTF (deckcraft-format). Wave 1.
        .target(name: "DCFormat", dependencies: [.product(name: "CNCore", package: "CraftNativeKit"), .product(name: "CNZip", package: "CraftNativeKit"), "DCModel"], path: sources("DCFormat", "DCFormat")),
        .testTarget(name: "DCFormatTests", dependencies: ["DCFormat", "DCModel", .product(name: "CNCore", package: "CraftNativeKit"), .product(name: "CNZip", package: "CraftNativeKit"), "DCTestSupport"], path: tests("DCFormat", "DCFormatTests")),

        // MARK: DCMedia — AVFoundation and media-bridge in place of deckcraft-media and its codec
        // crates. Wave 4.
        .target(
            name: "DCMedia",
            dependencies: [.product(name: "CNCore", package: "CraftNativeKit"), .product(name: "MediaImport", package: "media-bridge")],
            path: sources("DCMedia", "DCMedia")
        ),
        .testTarget(name: "DCMediaTests", dependencies: ["DCMedia", .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport"], path: tests("DCMedia", "DCMediaTests")),

        // MARK: DCRender — the CoreGraphics slide renderer, PDF through CGPDFContext, Metal transition
        // compositing (deckcraft-render, -pdf). Wave 2.
        .target(
            name: "DCRender",
            dependencies: [.product(name: "CNCore", package: "CraftNativeKit"), "DCGeometry", "DCColor", .product(name: "CNMetafile", package: "CraftNativeKit"), "DCModel", "DCAnim", "DCText"],
            path: sources("DCRender", "DCRender")
        ),
        .testTarget(
            name: "DCRenderTests",
            dependencies: ["DCRender", "DCText", "DCModel", "DCFormat", "DCGeometry", "DCColor", .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport"],
            path: tests("DCRender", "DCRenderTests")
        ),

        // MARK: DCPPTX — PPTX read and write from ECMA-376 (deckcraft-pptx). Wave 3.
        // MARK: DCPPT — legacy binary PowerPoint (.ppt, [MS-PPT] and [MS-ODRAW]) read into DCModel (Docs/plans/
        // Legacy-PPT-and-Encryption.md, P1–P6); its compound file is CNCFB's and its encryption CNOffCrypto's.
        .target(name: "DCPPT", dependencies: ["DCModel", "DCGeometry", "DCColor", .product(name: "CNCore", package: "CraftNativeKit"), .product(name: "CNCFB", package: "CraftNativeKit"), .product(name: "CNOffCrypto", package: "CraftNativeKit"), .product(name: "CNZip", package: "CraftNativeKit"), "DCPPTX"], path: sources("DCPPT", "DCPPT")),
        .testTarget(name: "DCPPTTests", dependencies: ["DCPPT", "DCModel", "DCGeometry", "DCColor", .product(name: "CNCFB", package: "CraftNativeKit"), .product(name: "CNOffCrypto", package: "CraftNativeKit"), "DCPPTX", "DCEngine", "DCRender", "DCAnim", .product(name: "CNZip", package: "CraftNativeKit"), "DCTestSupport"], path: tests("DCPPT", "DCPPTTests")),

                .target(name: "DCPPTX", dependencies: ["DCModel", "DCGeometry", "DCColor", .product(name: "CNZip", package: "CraftNativeKit"), .product(name: "CNCore", package: "CraftNativeKit")], path: sources("DCPPTX", "DCPPTX")),
        .testTarget(
            name: "DCPPTXTests",
            dependencies: ["DCPPTX", "DCModel", "DCFormat", "DCRender", "DCGeometry", "DCColor", .product(name: "CNZip", package: "CraftNativeKit"), .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport"],
            path: tests("DCPPTX", "DCPPTXTests")
        ),

        // MARK: DCEngine — Session, history, the command registry, tools, keys, AutoRecover, the
        // sample deck (deckcraft-engine). Wave 4.
        .target(
            name: "DCEngine",
            dependencies: [.product(name: "CNCore", package: "CraftNativeKit"), "DCGeometry", "DCColor", "DCModel", "DCText", "DCRender", "DCFormat", "DCPPTX", "DCMedia", .product(name: "CNZip", package: "CraftNativeKit"), .product(name: "CNOffCrypto", package: "CraftNativeKit"), "DCPPT"],
            path: sources("DCEngine", "DCEngine")
        ),
        .testTarget(
            name: "DCEngineTests",
            dependencies: ["DCEngine", "DCAnim", .product(name: "CNCore", package: "CraftNativeKit"), "DCGeometry", "DCColor", "DCModel", "DCText", "DCRender", "DCFormat", "DCPPTX", "DCPPT", "DCMedia", .product(name: "CNZip", package: "CraftNativeKit"), "DCTestSupport"],
            path: tests("DCEngine", "DCEngineTests")
        ),

        // MARK: DCAutomation — the JSON control channel and the MCP server (deckcraft-mcp,
        // ui-egui's control.rs). Wave 4.
        .target(
            name: "DCAutomation",
            dependencies: ["DCEngine", "DCRender", "DCModel", "DCGeometry", "DCColor", .product(name: "CNCore", package: "CraftNativeKit"), .product(name: "MCP", package: "swift-sdk")],
            path: sources("DCAutomation", "DCAutomation")
        ),
        .testTarget(
            name: "DCAutomationTests",
            dependencies: ["DCAutomation", "DCEngine", .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport", .product(name: "MCP", package: "swift-sdk")],
            path: tests("DCAutomation", "DCAutomationTests")
        ),
        .executableTarget(
            name: "dccli",
            dependencies: [
                "DCEngine", "DCAutomation", "DCRender", "DCAnim", "DCMedia", "DCModel", .product(name: "CNCore", package: "CraftNativeKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "VpxSwift", package: "vpx-swift"),
            ],
            path: "Apps/dccli"
        ),
        .testTarget(
            name: "dccliTests",
            dependencies: [
                "dccli", "DCAutomation", "DCEngine", "DCRender", "DCModel", .product(name: "CNCore", package: "CraftNativeKit"), .product(name: "CNZip", package: "CraftNativeKit"), "DCTestSupport",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Apps/dccliTests"
        ),

        // MARK: DCAppModel — the app's state without a window (ui-egui's SlideApp logic): UiState, the UI-only
        // commands, the menu tree, the palette, and routing between them and the engine. No AppKit. Wave 5.
        .target(
            name: "DCAppModel",
            dependencies: ["DCEngine", "DCAutomation", "DCRender", "DCAnim", "DCMedia", "DCFormat", "DCModel", "DCText", "DCGeometry", "DCColor", .product(name: "CNCore", package: "CraftNativeKit")],
            path: sources("DCApp", "DCAppModel"),
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DCAppModelTests",
            dependencies: ["DCAppModel", "DCEngine", "DCAutomation", "DCModel", .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport"],
            path: tests("DCApp", "DCAppModelTests")
        ),

        // MARK: DCApp — the Mac app: NSDocument windows, the canvas, navigator and inspector, menus and toolbar,
        // the slide show, the control server's host (ui-egui, apps/deckcraft). Wave 5.
        .target(
            name: "DCApp",
            dependencies: [
                "DCAppModel", "DCEngine", "DCAutomation", "DCRender", "DCAnim", "DCMedia", "DCModel", "DCGeometry", .product(name: "CNCore", package: "CraftNativeKit"), "DCText",
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
            dependencies: ["DCApp", "DCAppModel", "DCEngine", "DCAutomation", "DCRender", "DCModel", .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport", "DCIntentsKit", "DCSpotlight"],
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
            dependencies: ["DCEngine", "DCFormat", "DCPPTX", "DCText", "DCModel", .product(name: "CNZip", package: "CraftNativeKit"), .product(name: "CNCore", package: "CraftNativeKit")],
            path: sources("DCExtensions", "DCExtensionKit")
        ),
        .target(
            name: "DCQuickLook",
            dependencies: ["DCExtensionKit", "DCEngine", "DCRender", "DCModel", .product(name: "CNCore", package: "CraftNativeKit")],
            path: sources("DCExtensions", "DCQuickLook"),
            resources: [.process("Resources")]
        ),
        .target(name: "DCSpotlight", dependencies: ["DCExtensionKit", "DCModel", .product(name: "CNCore", package: "CraftNativeKit")], path: sources("DCExtensions", "DCSpotlight")),
        .testTarget(
            name: "DCExtensionsTests",
            dependencies: ["DCQuickLook", "DCSpotlight", "DCExtensionKit", "DCEngine", "DCRender", "DCModel", .product(name: "CNZip", package: "CraftNativeKit"), .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport"],
            path: tests("DCExtensions", "DCExtensionsTests")
        ),
        // The file intents (Export Presentation, Get Outline, Get Slide Count) as an App Intents package: the App
        // Intents extension runs them without launching the app, and DCApp includes them so the app's App
        // Shortcuts can name them. No AppKit. Wave 6.
        .target(
            name: "DCIntentsKit",
            dependencies: ["DCExtensionKit", "DCEngine", .product(name: "CNCore", package: "CraftNativeKit")],
            path: sources("DCExtensions", "DCIntentsKit"),
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DCIntentsKitTests",
            dependencies: ["DCIntentsKit", "DCEngine", .product(name: "CNCore", package: "CraftNativeKit"), "DCTestSupport"],
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

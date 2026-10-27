// DCApp — the app's entry point and launch arguments. Port of `startup` and the launch in deckcraft
// `apps/deckcraft/src/main.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Usage: `DeckCraftNative [--control PORT] [--sample] [--show] [FILE...]`. `--control` (or
// `DECKCRAFT_CONTROL_PORT`) starts the loopback JSON-lines control server that `dccli app` and
// `dccli mcp --connect` drive. The Xcode app and `DeckCraftDev` both call `DeckCraftApp.main()`.
import AppKit

/// What the command line asked for (`Startup::Run`).
public struct Launch: Equatable, Sendable {
    public var controlPort: UInt16?
    public var files: [String] = []
    public var sample = false
    public var show = false

    /// `startup`: `--control PORT`, `--sample`, `--show` and files, in any order; `controlPort` starts as
    /// the environment's. Arguments AppKit adds itself (`-NSDocumentRevisionsDebugMode YES`, `-psn_…`)
    /// are skipped.
    public init(arguments: [String], environmentPort: UInt16? = nil) {
        controlPort = environmentPort
        var it = arguments.makeIterator()
        while let a = it.next() {
            switch a {
            case "--control": controlPort = it.next().flatMap { UInt16($0) }
            case "--sample": sample = true
            case "--show": show = true
            default:
                if a.hasPrefix("-psn_") { continue }
                if a.hasPrefix("-NS") || a.hasPrefix("-Apple") {
                    _ = it.next()
                    continue
                }
                files.append(a)
            }
        }
    }
}

public enum DeckCraftApp {
    /// Strong references AppKit only holds weakly.
    @MainActor static var delegate: AppDelegate?

    /// Run the app. Never returns.
    @MainActor public static func main() {
        let env = ProcessInfo.processInfo.environment["DECKCRAFT_CONTROL_PORT"].flatMap { UInt16($0) }
        let launch = Launch(arguments: Array(CommandLine.arguments.dropFirst()), environmentPort: env)
        Codecs.registerExternalDecoders()
        let app = NSApplication.shared
        // The document controller must exist before anything asks for `NSDocumentController.shared`.
        _ = DocumentController()
        let d = AppDelegate(launch: launch)
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
    }
}

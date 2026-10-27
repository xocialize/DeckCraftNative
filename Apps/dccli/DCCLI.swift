// dccli — the entry point and subcommand table, on swift-argument-parser. Port of deckcraft
// apps/deckcraft-cli/src/main.rs `main` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// ArgumentParser holds the subcommand table and routes to the subcommand; each subcommand takes its
// arguments as they come (`captureForPassthrough`) and reads them as deckcraft-cli does, so its flags,
// messages and exit codes stay deckcraft-cli's (exit 1 on any failure, where ArgumentParser would use 64).
// `help`, `--help`, `--version` and an unknown or missing subcommand are answered before parsing, in
// deckcraft-cli's order. Everything runs on a thread with a 32 MiB stack: engine commands recurse once
// per group level.
import ArgumentParser
import DCAutomation
import DCMedia
import Darwin
import VpxSwift

/// A subcommand that hands its arguments to `body`.
protocol PassthroughCommand: ParsableCommand {
    var args: [String] { get }
    static func body(_ args: [String]) throws(CLIFailure)
}

extension PassthroughCommand {
    func run() throws {
        try Self.body(args)
    }
}

struct InfoCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "print a presentation's slides, layouts and theme as JSON", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.info(args) }
}

struct BenchCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "bench", abstract: "time opening, drawing, saving and exporting a presentation", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.bench(args) }
}

struct RenderCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "render", abstract: "draw slides as PNG images", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.render(args) }
}

struct RenderTransitionCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "render-transition", abstract: "draw frames of the transition into a slide as PNG images", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.renderTransition(args) }
}

struct ConvertCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "convert", abstract: "save a presentation in the format OUT's extension names", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.convert(args) }
}

struct RunCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "run commands on a presentation, then save or export it", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.run(args) }
}

struct CommandsCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "commands", abstract: "list the commands run can use, one per line", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { CLI.commands(args) }
}

struct DescribeCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "describe", abstract: "explain one command and its parameters", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.describe(args.first) }
}

struct AppCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "app", abstract: "run a command in the DeckCraft app started with --control", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.app(args) }
}

struct MCPCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "serve the commands to an agent over MCP on stdio", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { try CLI.mcp(args) }
}

struct LinksCommand: PassthroughCommand {
    static let configuration = CommandConfiguration(commandName: "links", abstract: "print the DeckCraft community and project links", helpNames: [])
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    static func body(_ args: [String]) throws(CLIFailure) { CLI.links() }
}

@main
struct DCCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deckcraft-cli",
        abstract: "deckcraft-cli works on DeckCraft presentations (.deckcraft, .pptx) without a window.",
        subcommands: [
            InfoCommand.self, RenderCommand.self, RenderTransitionCommand.self, ConvertCommand.self, RunCommand.self,
            CommandsCommand.self, DescribeCommand.self, AppCommand.self, MCPCommand.self, BenchCommand.self, LinksCommand.self,
        ],
        helpNames: []
    )

    static func main() {
        // A closed stdout is an error to handle (deckcraft exits 0), not a signal that kills the process.
        signal(SIGPIPE, SIG_IGN)
        // VP9 and VP8 through libvpx, as the app has them (video posters on insert, renders of video frames).
        Media.register(externalDecoder: VpxVideoDecoder())
        let args = Array(CommandLine.arguments.dropFirst())
        let code = EngineThread.onLargeStack { DCCLI.main(args) } ?? 1
        Darwin.exit(code)
    }

    /// deckcraft-cli's `main` on `args` (without the program name); the exit code.
    static func main(_ args: [String]) -> Int32 {
        let rest = Array(args.dropFirst())
        if let first = args.first, rest.contains(where: CLI.isHelp), let page = Help.page(first) {
            Out.line(page)
            return 0
        }
        switch args.first {
        case nil:
            return CLI.usage()
        case "help"?, "--help"?, "-h"?:
            guard let name = rest.first else {
                Out.line(Help.overview())
                return 0
            }
            guard let page = Help.page(name) else { return CLI.unknown(name) }
            Out.line(page)
            return 0
        case "--version"?, "-V"?, "version"?:
            Out.line("deckcraft-cli \(CLI.version)")
            return 0
        case let sub?:
            let command: ParsableCommand
            do { command = try parseAsRoot(args) } catch { return CLI.unknown(sub) }
            guard let passthrough = command as? any PassthroughCommand else { return CLI.unknown(sub) }
            return CLI.report { () throws(CLIFailure) in try runPassthrough(passthrough) }
        }
    }

    private static func runPassthrough(_ c: some PassthroughCommand) throws(CLIFailure) {
        try type(of: c).body(c.args)
    }
}

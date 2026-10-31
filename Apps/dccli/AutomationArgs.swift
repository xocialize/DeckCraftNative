// dccli — `--automation-read-root` / `--automation-write-root`, parsed before the server starts. A
// malformed flag must not silently remove a root and leave the server unconfined. Port of deckcraft
// apps/deckcraft-cli/src/automation_args.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).

struct AutomationArgs {
    var readRoots: [String]
    var writeRoots: [String]

    init(readRoot: String? = nil, writeRoot: String? = nil) {
        readRoots = readRoot.map { [$0] } ?? []
        writeRoots = writeRoot.map { [$0] } ?? []
    }

    /// Whether `arg` is a root flag (taking its value from `args` when it isn't inline). Both spellings
    /// (`--flag DIR` and `--flag=DIR`) may be repeated.
    mutating func consume(_ arg: String, _ args: inout ArgStream) throws(CLIFailure) -> Bool {
        let flag: String
        let inline: String?
        if let eq = arg.firstIndex(of: "=") {
            flag = String(arg[..<eq])
            inline = String(arg[arg.index(after: eq)...])
        } else {
            flag = arg
            inline = nil
        }
        let read: Bool
        switch flag {
        case "--automation-read-root": read = true
        case "--automation-write-root": read = false
        default: return false
        }
        let value: String
        if let inline {
            value = inline
        } else {
            guard let v = args.next() else { throw CLIFailure("\(flag) needs a folder") }
            if v.hasPrefix("-") { throw CLIFailure("\(flag) needs a folder; use \(flag)=<dir> for a folder starting with '-'") }
            value = v
        }
        if value.isEmpty { throw CLIFailure("\(flag) needs a non-empty folder") }
        if read { readRoots.append(value) } else { writeRoots.append(value) }
        return true
    }
}

/// The arguments still to read (Rust's argument iterator).
struct ArgStream {
    private var items: [String]
    private var index = 0

    init(_ items: [String]) { self.items = items }

    mutating func next() -> String? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

// dccli — `--automation-read-root` / `--automation-write-root`, parsed before the server starts. A
// malformed flag must not silently remove a root and leave the server unconfined. Port of deckcraft
// apps/deckcraft-cli/src/automation_args.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).

struct AutomationArgs {
    var readRoot: String?
    var writeRoot: String?
    private var readGiven = false
    private var writeGiven = false

    init(readRoot: String? = nil, writeRoot: String? = nil) {
        self.readRoot = readRoot
        self.writeRoot = writeRoot
    }

    /// Whether `arg` is a root flag (taking its value from `args` when it isn't inline). A second
    /// occurrence of a flag is an error, including when the two spellings (`--flag DIR`, `--flag=DIR`) are
    /// mixed.
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
        if read ? readGiven : writeGiven { throw CLIFailure("\(flag) given twice") }
        let value: String
        if let inline {
            value = inline
        } else {
            guard let v = args.next() else { throw CLIFailure("\(flag) needs a folder") }
            if v.hasPrefix("-") { throw CLIFailure("\(flag) needs a folder; use \(flag)=<dir> for a folder starting with '-'") }
            value = v
        }
        if value.isEmpty { throw CLIFailure("\(flag) needs a non-empty folder") }
        if read {
            readRoot = value
            readGiven = true
        } else {
            writeRoot = value
            writeGiven = true
        }
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

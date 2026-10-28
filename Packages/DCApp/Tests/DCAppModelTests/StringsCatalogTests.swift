// DCAppModelTests — the String Catalogs stay complete (WAVE6-PLAN.md, "String Catalogs"): the Commands catalog
// matches the registry, the UI commands and the menu tree (and is generated from them: `Tools/l10n/commands.sh`);
// every localized literal in DCAppModel and DCApp has a catalog entry, and every entry is used or marked
// stale (the catalogs are filled by `Tools/l10n/sync.sh`); no SwiftUI title literal looks in the main bundle;
// and DCAppModel's compiled bundle holds every key, so the strings come from the catalog.
import DCEngine
import Foundation
import Testing
@testable import DCAppModel

/// Where the catalogs and the sources are, from this file.
enum StringsPaths {
    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let sources = tests.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    static let root = sources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let app = root.appendingPathComponent("Apps/DeckCraftNative/App")
    /// DCIntentsKit (the file intents) and the App Intents extension that runs them: the kit's run-time text is in
    /// its own catalog, its App Intents metadata in the extension's (and the app's: both bundles list the intents).
    static let intentsKit = root.appendingPathComponent("Packages/DCExtensions/Sources/DCIntentsKit")
    static let intentsExtension = root.appendingPathComponent("Apps/DeckCraftNative/Extensions/Intents")
    static func catalog(_ module: String, _ table: String = "Localizable") -> URL {
        module == "App" ? app.appendingPathComponent("\(table).xcstrings")
            : sources.appendingPathComponent("\(module)/Resources/\(table).xcstrings")
    }
}

/// A String Catalog read as JSON: its keys, each key's English value and whether it is stale.
struct Catalog {
    struct Entry { var value: String?; var comment: String?; var stale: Bool; var other: [String: Any] }
    var entries: [String: Entry] = [:]

    init(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = root["strings"] as? [String: Any] ?? [:]
        for (key, raw) in strings {
            let e = raw as? [String: Any] ?? [:]
            let locs = e["localizations"] as? [String: Any] ?? [:]
            let en = (locs["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            entries[key] = Entry(
                value: en?["value"] as? String, comment: e["comment"] as? String,
                stale: (e["extractionState"] as? String) == "stale", other: locs.filter { $0.key != "en" }
            )
        }
    }

    var liveKeys: [String] { entries.filter { !$0.value.stale }.map(\.key).sorted() }
}

// MARK: - Source scan

/// A localized literal in the source: its text with each interpolation as a hole.
struct LocalizedLiteral: CustomStringConvertible {
    var file: String
    var line: Int
    var parts: [String]  // literal text; holes sit between parts
    var mainBundle: Bool

    var description: String { "\(file):\(line) \(parts.joined(separator: "\\(…)").debugDescription)" }

    /// Whether catalog key `key` is this literal's: the compiler writes a hole as a format specifier and,
    /// when there is one, a literal `%` as `%%`.
    func matches(_ key: String) -> Bool {
        if parts.count == 1 { return key == parts[0] }
        var pattern = "^"
        for (i, p) in parts.enumerated() {
            // A format specifier; in an App Intents summary, Xcode's `${parameter}`.
            if i > 0 { pattern += "(?:%(?:\\d+\\$)?(?:lld|llu|ld|lu|d|u|@|lf|f|hhd|hd|c)|\\$\\{[A-Za-z0-9_]+\\})" }
            pattern += NSRegularExpression.escapedPattern(for: p.replacingOccurrences(of: "%", with: "%%"))
        }
        return key.range(of: pattern + "$", options: .regularExpression) != nil
    }
}

enum SourceScan {
    /// The calls whose first argument, when a literal, is a key: `String(localized: "…"`, `L10n.text("…"`,
    /// SwiftUI's `Text("…", bundle: .module)`, `LocalizedStringResource("…"`, `AttributedString(localized: "…"`.
    /// App Intents' `Summary("…")` is extracted by Xcode into the main bundle's table.
    static let callHeads = ["String(localized: ", "L10n.text(", "Text(", "LocalizedStringResource(", "AttributedString(localized: ", "Summary("]

    /// The index past `head` at `chars[i]`, any whitespace and line breaks after `(` and around `localized:`
    /// allowed (`String(\n    localized: "…"`); nil when it isn't there.
    static func headEnd(_ chars: [Unicode.Scalar], _ i: Int, _ head: String) -> Int? {
        var j = i
        for c in head.unicodeScalars {
            if c == " " { while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }; continue }
            guard j < chars.count, chars[j] == c else { return nil }
            j += 1
            if c == "(" { while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 } }
        }
        return j
    }

    static func swiftFiles(_ dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let u = e?.nextObject() as? URL { if u.pathExtension == "swift" { out.append(u) } }
        return out.sorted { $0.path < $1.path }
    }

    /// Every localized literal in `files`.
    static func literals(_ files: [URL]) -> [LocalizedLiteral] {
        var out: [LocalizedLiteral] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let chars = Array(text.unicodeScalars)
            var i = 0
            var line = 1
            while i < chars.count {
                if chars[i] == "\n" { line += 1 }
                if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {  // a comment: skip the line
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                // Other literals aren't skipped: a localizing call can sit in one's interpolation.
                if i == 0 || !isIdent(chars[i - 1]), let (head, after) = callHeads.lazy.compactMap({ h in headEnd(chars, i, h).map { (h, $0) } }).first {
                    let q = after
                    if q < chars.count, chars[q] == "\"" {
                        let (parts, end) = parse(chars, q)
                        let tail = callTail(chars, end)
                        let isText = head == "Text("
                        // SwiftUI's Text without `bundle:` is the source scan's other test; here only the keys.
                        let main = (head == "LocalizedStringResource(" && !tail.contains("bundle:")) || head == "Summary("
                        if !isText || tail.contains("bundle:") {
                            out.append(LocalizedLiteral(file: url.lastPathComponent, line: line, parts: parts, mainBundle: main))
                        }
                        line += chars[i ..< end].filter { $0 == "\n" }.count
                        i = end
                        continue
                    }
                }
                i += 1
            }
        }
        return out
    }

    static func isIdent(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "." || CharacterSet.alphanumerics.contains(c) }

    static func starts(_ chars: [Unicode.Scalar], _ i: Int, _ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard i + u.count <= chars.count else { return false }
        return Array(chars[i ..< i + u.count]) == u
    }

    /// The literal starting at `chars[q]` (a quote): its parts and the index past it.
    static func parse(_ chars: [Unicode.Scalar], _ q: Int) -> ([String], Int) {
        if starts(chars, q, "\"\"\"") {  // multi-line: not used for keys here; skip it
            var j = q + 3
            while j < chars.count, !starts(chars, j, "\"\"\"") { j += 1 }
            return ([""], min(chars.count, j + 3))
        }
        var parts = [""]
        var j = q + 1
        while j < chars.count {
            let c = chars[j]
            if c == "\"" { return (parts, j + 1) }
            if c == "\n" { return (parts, j) }
            if c == "\\", j + 1 < chars.count {
                let n = chars[j + 1]
                switch n {
                case "(":
                    var depth = 1
                    j += 2
                    while j < chars.count, depth > 0 {
                        if chars[j] == "\"" { j = parse(chars, j).1; continue }
                        if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
                        j += 1
                    }
                    parts.append("")
                    continue
                case "n": parts[parts.count - 1] += "\n"
                case "t": parts[parts.count - 1] += "\t"
                case "0": parts[parts.count - 1] += "\0"
                case "u":
                    var k = j + 3
                    var hex = ""
                    while k < chars.count, chars[k] != "}" { hex.unicodeScalars.append(chars[k]); k += 1 }
                    if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { parts[parts.count - 1].unicodeScalars.append(s) }
                    j = k + 1
                    continue
                default: parts[parts.count - 1].unicodeScalars.append(n)
                }
                j += 2
                continue
            }
            parts[parts.count - 1].unicodeScalars.append(c)
            j += 1
        }
        return (parts, j)
    }

    /// The rest of the call after the literal that ends at `i`, up to the `)` that closes it.
    static func callTail(_ chars: [Unicode.Scalar], _ i: Int) -> String {
        var depth = 0
        var j = i
        var out = ""
        while j < chars.count {
            let c = chars[j]
            if c == "\"" {
                let end = parse(chars, j).1
                j = end
                continue
            }
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            if c == ")" || c == "]" || c == "}" {
                if depth == 0 { break }
                depth -= 1
            }
            out.unicodeScalars.append(c)
            j += 1
        }
        return out
    }

    /// SwiftUI title literals with no `bundle:`: they look the key up in the main bundle, where it isn't.
    static let swiftUITitles = [
        "Text", "Button", "Toggle", "Picker", "TextField", "SecureField", "Label", "Section", "Menu", "LabeledContent",
        "Stepper", "DisclosureGroup", "GroupBox", "ProgressView", "ControlGroup", "ColorPicker", "Link", "Gauge",
        ".help", ".accessibilityLabel", ".accessibilityHint", ".accessibilityValue", ".navigationTitle", ".alert",
        ".confirmationDialog", ".badge", "Tab",
    ]

    static func mainBundleTitles(_ files: [URL]) -> [String] {
        var out: [String] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for name in swiftUITitles {
                    let pattern = (name.hasPrefix(".") ? "\\" : "(?<![A-Za-z0-9_.])") + name + "\\(\""
                    guard let r = code.range(of: pattern, options: .regularExpression) else { continue }
                    let chars = Array(code.unicodeScalars)
                    let q = code.unicodeScalars.distance(from: code.unicodeScalars.startIndex, to: r.upperBound.samePosition(in: code.unicodeScalars) ?? code.unicodeScalars.endIndex) - 1
                    let end = parse(chars, q).1
                    if !callTail(chars, end).contains("bundle:") { out.append("\(url.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))") }
                }
            }
        }
        return out
    }
}

@Suite struct StringsCatalogTests {
    static let modelFiles = SourceScan.swiftFiles(StringsPaths.sources.appendingPathComponent("DCAppModel"))
    static let appFiles = SourceScan.swiftFiles(StringsPaths.sources.appendingPathComponent("DCApp"))
    static let intentsKitFiles = SourceScan.swiftFiles(StringsPaths.intentsKit)

    // MARK: Commands

    /// English labels the app shows in place of the registry's: the registry keeps deckcraft's (parity), but
    /// the app's own name is DeckCraftNative (WAVE6-PLAN.md, "Decided").
    static let appNameLabels = ["app.about": "About DeckCraftNative", "menu.About DeckCraft": "About DeckCraftNative"]

    /// The Commands catalog the registry, the UI commands and the menu tree make: key → (English, comment).
    static func expectedCommands() -> [String: (String, String)] {
        var out: [String: (String, String)] = [:]
        for spec in commandSpecs() where out[spec.id] == nil {
            let place = spec.menu.isEmpty ? "" : " (\(spec.menu.joined(separator: " › ")))"
            out[spec.id] = (spec.label, "The label of command \(spec.id)\(place)")
        }
        for c in UICommands.all where out[c.id] == nil {
            out[c.id] = (c.label, "The label of the app's command \(c.id)")
        }
        for m in MenuTree.menus {
            if out["menu.\(m.title)"] == nil { out["menu.\(m.title)"] = (m.title, "A menu in the menu bar") }
            for case .command(let label, let id) in m.entries where out["menu.\(label)"] == nil {
                out["menu.\(label)"] = (label, "An item of the \(m.title) menu (runs \(id))")
            }
        }
        for (key, label) in appNameLabels {
            if let (_, comment) = out[key] { out[key] = (label, comment + "; the app's own name, not deckcraft's") }
        }
        return out
    }

    /// Writes Commands.xcstrings from `expectedCommands()`, keeping the translations of keys still there
    /// (`Tools/l10n/commands.sh` runs this with DC_L10N_WRITE=1).
    static func writeCommands() throws {
        let url = StringsPaths.catalog("DCAppModel", "Commands")
        let old = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
        var strings: [String: Any] = [:]
        for (key, (value, comment)) in expectedCommands() {
            var locs = ((old[key] as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
            locs["en"] = ["stringUnit": ["state": "translated", "value": value]]
            strings[key] = ["comment": comment, "extractionState": "manual", "localizations": locs]
        }
        // A key that's gone keeps its translations, marked stale.
        for (key, raw) in old where strings[key] == nil {
            guard var e = raw as? [String: Any], let locs = e["localizations"] as? [String: Any], locs.keys.contains(where: { $0 != "en" }) else { continue }
            e["extractionState"] = "stale"
            strings[key] = e
        }
        let catalog: [String: Any] = ["sourceLanguage": "en", "version": "1.0", "strings": strings]
        var data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url)
    }

    @Test func commandsCatalogMatchesTheRegistry() throws {
        if ProcessInfo.processInfo.environment["DC_L10N_WRITE"] == "1" { try Self.writeCommands() }
        let catalog = try Catalog(StringsPaths.catalog("DCAppModel", "Commands"))
        let expected = Self.expectedCommands()
        var problems: [String] = []
        for (key, (value, _)) in expected.sorted(by: { $0.key < $1.key }) {
            guard let e = catalog.entries[key] else { problems.append("missing \(key)"); continue }
            if e.value != value { problems.append("\(key): catalog \(e.value ?? "nil") ≠ \(value)") }
            if e.stale { problems.append("\(key) is marked stale") }
        }
        for key in catalog.liveKeys where expected[key] == nil { problems.append("unused \(key)") }
        #expect(problems.isEmpty, "Commands.xcstrings is out of date (run Tools/l10n/commands.sh): \(problems.prefix(20))")
    }

    @Test func everyCommandHasACommandsEntry() throws {
        let catalog = try Catalog(StringsPaths.catalog("DCAppModel", "Commands"))
        let engine = Set(commandSpecs().map(\.id))
        #expect(engine.count >= 330, "the registry has \(engine.count) commands")
        let ids = engine.union(UICommands.all.map(\.id))
        let missing = ids.filter { catalog.entries[$0] == nil }.sorted()
        #expect(missing.isEmpty, "commands without a Commands entry: \(missing)")
        let menus = MenuTree.menus.flatMap { m in
            [m.title] + m.entries.compactMap { if case .command(let label, _) = $0 { label } else { nil } }
        }
        let missingMenus = menus.filter { catalog.entries["menu.\($0)"] == nil }
        #expect(missingMenus.isEmpty, "menu titles without a Commands entry: \(missingMenus)")
    }

    /// The labels the app shows come from the Commands catalog, and in English they are the registry's.
    @Test func commandLabelsComeFromTheCatalog() {
        let sentinel = "\u{1}missing"
        var missing: [String] = []
        for spec in commandSpecs() {
            if Bundle.module.localizedString(forKey: spec.id, value: sentinel, table: "Commands") == sentinel { missing.append(spec.id) }
        }
        #expect(missing.isEmpty, "not in the compiled Commands table: \(missing.prefix(10))")
        // Every duplicate id has one label, so the palette (which lists every spec) shows each as the registry does.
        for spec in commandSpecs() { #expect(findCommand(spec.id)?.label == spec.label, "\(spec.id)") }
        for spec in commandSpecs() where Self.appNameLabels[spec.id] == nil {
            #expect(L10n.commandLabel(spec.id, "\u{1}") == spec.label)
        }
        for c in UICommands.all where findCommand(c.id) == nil && Self.appNameLabels[c.id] == nil {
            #expect(L10n.commandLabel(c.id, "\u{1}") == c.label)
        }
        for m in MenuTree.menus { #expect(L10n.menuTitle(m.title) == m.title) }
        #expect(L10n.commandLabel("app.about", "About DeckCraft") == "About DeckCraftNative")
        #expect(L10n.menuTitle("About DeckCraft") == "About DeckCraftNative")
    }

    // MARK: Localizable

    /// Every localized literal has its key in its catalog: DCAppModel's, DCApp's, or the app's (App Intents
    /// metadata, which the main bundle looks up).
    @Test(arguments: ["DCAppModel", "DCApp"])
    func everyLiteralHasACatalogEntry(_ module: String) throws {
        let files = module == "DCApp" ? Self.appFiles : Self.modelFiles
        let literals = SourceScan.literals(files)
        #expect(literals.count > 300, "\(module): only \(literals.count) localized literals found")
        let own = try Catalog(StringsPaths.catalog(module)).entries.filter { !$0.value.stale }.map(\.key)
        let main = try Catalog(StringsPaths.catalog("App")).entries.filter { !$0.value.stale }.map(\.key)
        let missing = literals.filter { lit in !(lit.mainBundle ? main : own).contains(where: lit.matches) }
        #expect(missing.isEmpty, "literals with no catalog entry (run Tools/l10n/sync.sh): \(missing.prefix(20))")
    }

    /// Every entry is used by the code, or marked stale.
    @Test(arguments: ["DCAppModel", "DCApp"])
    func everyCatalogEntryIsUsed(_ module: String) throws {
        let literals = SourceScan.literals(module == "DCApp" ? Self.appFiles : Self.modelFiles).filter { !$0.mainBundle }
        let catalog = try Catalog(StringsPaths.catalog(module))
        let unused = catalog.liveKeys.filter { key in !literals.contains { $0.matches(key) } }
        #expect(unused.isEmpty, "\(module) entries no code uses (run Tools/l10n/sync.sh to mark them stale): \(unused.prefix(20))")
    }

    /// The app catalog's entries are used by DCApp/Intents' main-bundle literals, the app target's files, or
    /// Xcode's App Shortcuts extraction (parameter summaries, `${…}`).
    @Test func everyAppCatalogEntryIsUsed() throws {
        let literals = SourceScan.literals(Self.appFiles + Self.intentsKitFiles + SourceScan.swiftFiles(StringsPaths.app)).filter(\.mainBundle)
        let catalog = try Catalog(StringsPaths.catalog("App"))
        let unused = catalog.liveKeys.filter { key in !literals.contains { $0.matches(key) } }
        #expect(unused.isEmpty, "app catalog entries no code uses: \(unused)")
    }

    /// DCIntentsKit's literals: run-time text (`bundle:`) in its own catalog; App Intents metadata (no `bundle:`, the
    /// main bundle's) in both the App Intents extension's catalog and the app's, since each bundle lists the file
    /// intents and looks their metadata up in itself. And every entry of the kit's and the extension's catalogs is used.
    @Test func intentsKitAndExtensionCatalogs() throws {
        let literals = SourceScan.literals(Self.intentsKitFiles + SourceScan.swiftFiles(StringsPaths.intentsExtension))
        #expect(literals.count > 30, "only \(literals.count) localized literals found in DCIntentsKit")
        let kitURL = StringsPaths.intentsKit.appendingPathComponent("Resources/Localizable.xcstrings")
        let extURL = StringsPaths.intentsExtension.appendingPathComponent("Localizable.xcstrings")
        let kit = try Catalog(kitURL), ext = try Catalog(extURL), app = try Catalog(StringsPaths.catalog("App"))
        for (name, catalog, wanted) in [("DCIntentsKit", kit, literals.filter { !$0.mainBundle }),
                                        ("the extension's", ext, literals.filter(\.mainBundle)),
                                        ("the app's", app, literals.filter(\.mainBundle))] {
            let keys = catalog.liveKeys
            let missing = wanted.filter { lit in !keys.contains(where: lit.matches) }
            #expect(missing.isEmpty, "\(name) catalog lacks (run Tools/l10n/sync.sh): \(missing.prefix(20))")
        }
        for (name, catalog, used) in [("DCIntentsKit", kit, literals.filter { !$0.mainBundle }), ("the extension's", ext, literals.filter(\.mainBundle))] {
            let unused = catalog.liveKeys.filter { key in !used.contains { $0.matches(key) } }
            #expect(unused.isEmpty, "\(name) catalog entries no code uses: \(unused)")
        }
        // The summaries Xcode extracts for the extension (`${…}`), and the plural variations of the kit's counts.
        #expect(ext.entries["Export ${file} as ${format}"]?.value != nil)
        #expect(json(kitURL).contains("Exported %lld file."))
    }

    private func json(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Every App Shortcuts phrase in the app target is in AppShortcuts.xcstrings (Xcode's string sets).
    @Test func appShortcutsCatalogHasEveryPhrase() throws {
        let url = StringsPaths.app.appendingPathComponent("DeckCraftIntentShortcuts.swift")
        let chars = Array(try String(contentsOf: url, encoding: .utf8).unicodeScalars)
        var phrases: [LocalizedLiteral] = []
        var i = 0
        while i < chars.count {
            guard let open = SourceScan.headEnd(chars, i, "phrases: [") else { i += 1; continue }
            var j = open
            while j < chars.count, chars[j] != "]" {
                if chars[j] == "\"" {
                    let (parts, end) = SourceScan.parse(chars, j)
                    phrases.append(LocalizedLiteral(file: url.lastPathComponent, line: 0, parts: parts, mainBundle: true))
                    j = end
                } else { j += 1 }
            }
            i = j
        }
        #expect(phrases.count >= 7)
        let data = try Data(contentsOf: StringsPaths.catalog("App", "AppShortcuts"))
        let strings = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: [String: Any]] ?? [:]
        let values = strings.values.flatMap { e -> [String] in
            let en = (e["localizations"] as? [String: Any])?["en"] as? [String: Any]
            return (en?["stringSet"] as? [String: Any])?["values"] as? [String] ?? []
        }
        let missing = phrases.filter { p in !values.contains(where: p.matches) }
        #expect(missing.isEmpty, "phrases not in AppShortcuts.xcstrings (run Tools/l10n/sync.sh): \(missing)")
    }

    /// InfoPlist.xcstrings names every document type and exported/imported type the app declares.
    @Test func infoPlistCatalogNamesTheDocumentTypes() throws {
        let plistURL = StringsPaths.app.deletingLastPathComponent().appendingPathComponent("Support/Info.plist")
        let info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        var names = (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).compactMap { $0["CFBundleTypeName"] as? String }
        for group in ["UTExportedTypeDeclarations", "UTImportedTypeDeclarations"] {
            names += (info[group] as? [[String: Any]] ?? []).compactMap { $0["UTTypeDescription"] as? String }
        }
        #expect(names.count >= 4)
        let catalog = try Catalog(StringsPaths.catalog("App", "InfoPlist"))
        for key in names + ["CFBundleDisplayName", "NSHumanReadableCopyright"] {
            #expect(catalog.entries[key]?.value != nil, "\(key)")
        }
    }

    /// No SwiftUI title literal without `bundle:` in DCApp: it would look in the main bundle.
    @Test func noSwiftUILiteralWithoutBundle() {
        let found = SourceScan.mainBundleTitles(Self.appFiles.filter { !$0.path.contains("/Intents/") })
        #expect(found.isEmpty, "SwiftUI literals without bundle: .module: \(found)")
    }

    /// Every `String(localized:)` in the two modules names its bundle (DCAppModel's `L10n.text` does so itself).
    @Test func everyLocalizedStringNamesItsBundle() {
        var found: [String] = []
        for url in Self.modelFiles + Self.appFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let chars = Array(text.unicodeScalars)
            for i in chars.indices {
                guard let q = SourceScan.headEnd(chars, i, "String(localized: ") else { continue }
                // `String(localized: resource)` takes a LocalizedStringResource, which carries its bundle.
                guard q < chars.count, chars[q] == "\"" else { continue }
                let tail = SourceScan.callTail(chars, q)
                if !tail.contains("bundle:") { found.append("\(url.lastPathComponent): String(localized: \(tail.prefix(40))") }
            }
        }
        #expect(found.isEmpty, "String(localized:) without bundle: \(found)")
    }

    /// The compiled bundle holds every DCAppModel key, plural ones included: the strings come from the catalog.
    @Test func modelBundleHasEveryKey() throws {
        let sentinel = "\u{1}missing"
        let catalog = try Catalog(StringsPaths.catalog("DCAppModel"))
        let missing = catalog.liveKeys.filter { Bundle.module.localizedString(forKey: $0, value: sentinel, table: "Localizable") == sentinel }
        #expect(missing.isEmpty, "keys not in DCAppModel's compiled bundle: \(missing.prefix(20))")
        #expect(catalog.liveKeys.count > 300)
    }

    /// A plural variation picks the singular, through the code that shows it.
    @Test func pluralVariations() {
        #expect(L10n.text("Handouts (\(1) Slides per Page)") == "Handouts (1 Slide per Page)")
        #expect(L10n.text("Handouts (\(6) Slides per Page)") == "Handouts (6 Slides per Page)")
        // The substitution shape, with the plural argument second.
        #expect(L10n.text("\("Pitch") (\(1) slides)") == "Pitch (1 slides)")
        #expect(L10n.text("\("Pitch") (\(3) slides)") == "Pitch (3 slides)")
    }
}

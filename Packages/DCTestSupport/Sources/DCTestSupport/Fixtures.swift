// DCTestSupport — where tests find the fixtures repository and which upstream commit it was built
// from. The pin lives in Tools/oracle/pin.env, shared with oracle.sh, so a test and the corpus it
// reads can't silently disagree about the upstream they describe.
import Foundation

/// The upstream commits this port follows, read from `Tools/oracle/pin.env`.
public struct UpstreamPin: Sendable, Equatable {
    public var deckcraftCommit: String
    public var deckcraftDate: String
    public var craftFontsCommit: String

    /// The first eight characters of the deckcraft commit, which name the corpus folder.
    public var short: String { String(deckcraftCommit.prefix(8)) }

    public enum ParseError: Error, Equatable {
        case missing(String)
        case notACommit(String)
    }

    /// Reads `KEY=VALUE` lines; blank lines and `#` comments are skipped.
    public init(envFile text: String) throws(ParseError) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }
        func value(_ key: String) throws(ParseError) -> String {
            guard let v = values[key], !v.isEmpty else { throw .missing(key) }
            return v
        }
        func commit(_ key: String) throws(ParseError) -> String {
            let v = try value(key)
            guard v.count == 40, v.allSatisfy(\.isHexDigit) else { throw .notACommit(key) }
            return v
        }
        deckcraftCommit = try commit("DECKCRAFT_COMMIT")
        deckcraftDate = try value("DECKCRAFT_DATE")
        craftFontsCommit = try commit("CRAFT_FONTS_COMMIT")
    }

    /// The pin of this checkout, or nil when `pin.env` can't be read or parsed.
    public static func current() -> UpstreamPin? {
        guard let text = try? String(contentsOf: Fixtures.repositoryRoot.appending(path: "Tools/oracle/pin.env"), encoding: .utf8) else {
            return nil
        }
        return try? UpstreamPin(envFile: text)
    }
}

/// The fixtures repository: `DECKCRAFT_FIXTURES`, else `../DeckCraftNative-Fixtures` beside this one.
public enum Fixtures {
    /// This repository's root, found from this file's path.
    public static var repositoryRoot: URL {
        // …/Packages/DCTestSupport/Sources/DCTestSupport/Fixtures.swift
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    public static var root: URL {
        if let env = ProcessInfo.processInfo.environment["DECKCRAFT_FIXTURES"], !env.isEmpty {
            return URL(filePath: env, directoryHint: .isDirectory)
        }
        return repositoryRoot.deletingLastPathComponent().appending(path: "DeckCraftNative-Fixtures", directoryHint: .isDirectory)
    }

    /// The oracle corpus for the current pin: `<root>/oracle/<short commit>/`, or nil when it hasn't
    /// been generated (`Tools/oracle/oracle.sh corpus`). Tests that need it skip on nil.
    public static var oracleCorpus: URL? {
        guard let pin = UpstreamPin.current() else { return nil }
        let dir = root.appending(path: "oracle/\(pin.short)", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: dir.appending(path: "manifest.json").path) ? dir : nil
    }
}

// DCAppModelTests — every translation in every String Catalog keeps its English text's format arguments
// (`Tools/l10n/translations.py` checks the same when it writes them). A translation that drops `%lld` or turns
// `%@` into `%d` would format the wrong argument or crash; one that reorders arguments must name their positions.
import Foundation
import Testing

@Suite struct TranslationsTests {
    static let catalogs: [URL] = [
        StringsPaths.catalog("DCAppModel"), StringsPaths.catalog("DCAppModel", "Commands"), StringsPaths.catalog("DCAppModel", "Ribbon"),
        StringsPaths.catalog("DCApp"), StringsPaths.catalog("App"), StringsPaths.catalog("App", "InfoPlist"),
        StringsPaths.catalog("App", "AppShortcuts"),
        StringsPaths.intentsKit.appendingPathComponent("Resources/Localizable.xcstrings"),
        StringsPaths.intentsKit.deletingLastPathComponent().appendingPathComponent("DCQuickLook/Resources/Localizable.xcstrings"),
        StringsPaths.intentsExtension.appendingPathComponent("Localizable.xcstrings"),
    ]

    static let spec = try? NSRegularExpression(pattern: #"%#@[A-Za-z0-9_]+@|%arg|%%|%(?:\d+\$)?[-+#0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]|\$\{[A-Za-z]+\}"#)

    static func specs(_ text: String) -> [String] {
        guard let spec else { return [] }
        return spec.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// The argument without its position: `%2$@` and `%@` are the same kind.
    static func kinds(_ text: String) -> [String] {
        specs(text).map { $0.replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression) }
    }

    /// A localization's text by form: "" for a plain string, "one"/"other" for plural forms, and "phrase N".
    static func forms(_ loc: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        if let unit = loc["stringUnit"] as? [String: Any], let v = unit["value"] as? String { out["value"] = v }
        func plural(_ node: [String: Any]?) {
            guard let p = (node?["variations"] as? [String: Any])?["plural"] as? [String: Any] else { return }
            for (form, raw) in p {
                if let v = ((raw as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String { out[form] = v }
            }
        }
        plural(loc)
        for sub in (loc["substitutions"] as? [String: Any] ?? [:]).values { plural(sub as? [String: Any]) }
        return out
    }

    @Test func everyTranslationKeepsItsFormatArguments() throws {
        var problems: [String] = []
        var checked = 0
        for url in Self.catalogs {
            let data = try Data(contentsOf: url)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            for (key, raw) in root["strings"] as? [String: Any] ?? [:] {
                let locs = (raw as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                let en = (locs["en"] as? [String: Any]).map(Self.forms) ?? ["value": key]
                for (lang, loc) in locs where lang != "en" {
                    guard let loc = loc as? [String: Any] else { continue }
                    if let set = loc["stringSet"] as? [String: Any] {
                        let phrases = set["values"] as? [String] ?? []
                        if phrases.contains(where: { !$0.contains("${applicationName}") }) { problems.append("\(lang) \(key): a phrase without ${applicationName}") }
                        continue
                    }
                    for (form, text) in Self.forms(loc) {
                        // A plural form missing in English (French "many") is checked against "other".
                        guard let english = en[form] ?? en["other"] ?? en["value"] else { continue }
                        checked += 1
                        let (a, b) = (Self.kinds(english), Self.kinds(text))
                        if a.sorted() != b.sorted() {
                            problems.append("\(lang) \(url.lastPathComponent) \(key) [\(form)]: \(Self.specs(english)) vs \(Self.specs(text))")
                        } else if a != b, !Self.specs(text).contains(where: { $0.range(of: #"^%\d+\$"#, options: .regularExpression) != nil }) {
                            problems.append("\(lang) \(url.lastPathComponent) \(key) [\(form)]: arguments reordered without positions")
                        }
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(20))")
        // The four preview languages' plain strings and plural forms, at least.
        #expect(checked > 10_000, "only \(checked) translations checked")
    }
}

// DCAppTests — DCApp's strings come from its String Catalog (WAVE6-PLAN.md, "String Catalogs"): the compiled
// bundle holds every key of `DCApp/Resources/Localizable.xcstrings`, and the menu bar's titles are the Commands
// catalog's. The source-level checks (every literal has an entry, no SwiftUI literal without `bundle:`) are
// DCAppModelTests' StringsCatalogTests.
import AppKit
import DCAppModel
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite(.serialized) struct StringsTests {
    static let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/DCApp/Resources/Localizable.xcstrings")

    /// The catalog's keys that the code still uses (not stale).
    static func liveKeys() throws -> [String] {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = root["strings"] as? [String: [String: Any]] ?? [:]
        return strings.filter { ($0.value["extractionState"] as? String) != "stale" }.map(\.key).sorted()
    }

    @Test func bundleHasEveryKey() throws {
        let sentinel = "\u{1}missing"
        let keys = try Self.liveKeys()
        #expect(keys.count > 300)
        let missing = keys.filter { Bundle.module.localizedString(forKey: $0, value: sentinel, table: "Localizable") == sentinel }
        #expect(missing.isEmpty, "keys not in DCApp's compiled bundle: \(missing.prefix(20))")
    }

    /// A plural variation picks the singular, and the substitution shape keeps the other arguments in place.
    @Test func pluralVariations() {
        #expect(String(localized: "\(1) Columns", bundle: .module) == "1 Column")
        #expect(String(localized: "\(2) Columns", bundle: .module) == "2 Columns")
        #expect(String(localized: "\(1) spelling problems on this slide", bundle: .module) == "1 spelling problem on this slide")
        #expect(String(localized: "Compressed \(2) picture(s): \("10") KB → \("4") KB", bundle: .module) == "Compressed 2 picture(s): 10 KB → 4 KB")
    }

    /// The menu bar's menus and items carry the Commands catalog's titles; the app and Window menus DCApp's.
    @Test func menuBarTitlesComeFromTheCatalogs() throws {
        _ = NSApplication.shared
        let app = AppController()
        app.syncSuspended += 1
        let main = MenuBuilder.mainMenu(target: app)
        for m in MenuTree.menus {
            let menu = try #require(main.items.first { $0.title == L10n.menuTitle(m.title) }?.submenu, "\(m.title)")
            for case .command(let label, let id) in m.entries {
                #expect(menu.items.contains { $0.title == L10n.menuTitle(label) && $0.representedObject as? String == id }, "\(m.title) › \(label)")
            }
        }
        let sentinel = "\u{1}missing"
        for key in ["Settings…", "Services", "Hide Others", "Show All", "Window", "Minimize", "Zoom", "Bring All to Front", "About %@", "Hide %@", "Quit %@"] {
            #expect(Bundle.module.localizedString(forKey: key, value: sentinel, table: "Localizable") != sentinel, "\(key)")
        }
        #expect(main.items.contains { $0.title == String(localized: "Window", bundle: .module, comment: "The Window menu") })
    }
}

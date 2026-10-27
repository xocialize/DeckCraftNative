// DCAppModel — the app's localized strings. User-visible text lives in String Catalogs:
// - `Resources/Localizable.xcstrings` in each app target, for the text written in its code:
//   `String(localized: "Slide Sorter", bundle: .module)`, `Text("Notes", bundle: .module)`;
// - `Resources/Commands.xcstrings` here, for the registry's labels and the menu titles, keyed by command id
//   (`slide.new`) and by `menu.<Title>`. The engine keeps deckcraft's English labels (scripts, `dccli describe`
//   and the oracle compare them byte for byte); the app translates them when it shows them.
// English is the source language (`defaultLocalization` in Package.swift).
import Foundation

public enum L10n {
    /// The label to show for command `id`: its Commands catalog entry, else the registry's English label.
    public static func commandLabel(_ id: String, _ english: String) -> String {
        Bundle.module.localizedString(forKey: id, value: english, table: "Commands")
    }

    /// The title to show for the menu deckcraft's `menu_tree` calls `english`.
    public static func menuTitle(_ english: String) -> String {
        Bundle.module.localizedString(forKey: "menu.\(english)", value: english, table: "Commands")
    }

    /// A string from DCAppModel's own catalog (status messages, dialog fields), for code in this target.
    static func text(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }
}

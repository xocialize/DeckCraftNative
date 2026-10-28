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

    /// A colour's name to show: DCColor's English names for theme slots (`SchemeSlot.label`), theme shades
    /// (`themeVariants`) and standard colours (`standardColors`), from the catalog. Anything else stays as given.
    public static func colorLabel(_ english: String) -> String {
        switch english {
        case "Text/Background - Dark 1": String(localized: "Text/Background - Dark 1", bundle: .module, comment: "A theme colour slot")
        case "Text/Background - Light 1": String(localized: "Text/Background - Light 1", bundle: .module, comment: "A theme colour slot")
        case "Text/Background - Dark 2": String(localized: "Text/Background - Dark 2", bundle: .module, comment: "A theme colour slot")
        case "Text/Background - Light 2": String(localized: "Text/Background - Light 2", bundle: .module, comment: "A theme colour slot")
        case "Accent 1": String(localized: "Accent 1", bundle: .module, comment: "A theme colour slot")
        case "Accent 2": String(localized: "Accent 2", bundle: .module, comment: "A theme colour slot")
        case "Accent 3": String(localized: "Accent 3", bundle: .module, comment: "A theme colour slot")
        case "Accent 4": String(localized: "Accent 4", bundle: .module, comment: "A theme colour slot")
        case "Accent 5": String(localized: "Accent 5", bundle: .module, comment: "A theme colour slot")
        case "Accent 6": String(localized: "Accent 6", bundle: .module, comment: "A theme colour slot")
        case "Hyperlink": String(localized: "Hyperlink", bundle: .module, comment: "A theme colour slot")
        case "Followed Hyperlink": String(localized: "Followed Hyperlink", bundle: .module, comment: "A theme colour slot")
        case "Placeholder colour": String(localized: "Placeholder colour", bundle: .module, comment: "A theme colour slot")
        case "Lighter 90%": String(localized: "Lighter 90%", bundle: .module, comment: "A shade of a theme colour")
        case "Lighter 80%": String(localized: "Lighter 80%", bundle: .module, comment: "A shade of a theme colour")
        case "Lighter 75%": String(localized: "Lighter 75%", bundle: .module, comment: "A shade of a theme colour")
        case "Lighter 60%": String(localized: "Lighter 60%", bundle: .module, comment: "A shade of a theme colour")
        case "Lighter 50%": String(localized: "Lighter 50%", bundle: .module, comment: "A shade of a theme colour")
        case "Lighter 40%": String(localized: "Lighter 40%", bundle: .module, comment: "A shade of a theme colour")
        case "Lighter 25%": String(localized: "Lighter 25%", bundle: .module, comment: "A shade of a theme colour")
        case "Lighter 10%": String(localized: "Lighter 10%", bundle: .module, comment: "A shade of a theme colour")
        case "Darker 5%": String(localized: "Darker 5%", bundle: .module, comment: "A shade of a theme colour")
        case "Darker 15%": String(localized: "Darker 15%", bundle: .module, comment: "A shade of a theme colour")
        case "Darker 25%": String(localized: "Darker 25%", bundle: .module, comment: "A shade of a theme colour")
        case "Darker 35%": String(localized: "Darker 35%", bundle: .module, comment: "A shade of a theme colour")
        case "Darker 50%": String(localized: "Darker 50%", bundle: .module, comment: "A shade of a theme colour")
        case "Dark Red": String(localized: "Dark Red", bundle: .module, comment: "A standard colour")
        case "Red": String(localized: "Red", bundle: .module, comment: "A standard colour")
        case "Orange": String(localized: "Orange", bundle: .module, comment: "A standard colour")
        case "Yellow": String(localized: "Yellow", bundle: .module, comment: "A standard colour")
        case "Light Green": String(localized: "Light Green", bundle: .module, comment: "A standard colour")
        case "Green": String(localized: "Green", bundle: .module, comment: "A standard colour")
        case "Light Blue": String(localized: "Light Blue", bundle: .module, comment: "A standard colour")
        case "Blue": String(localized: "Blue", bundle: .module, comment: "A standard colour")
        case "Dark Blue": String(localized: "Dark Blue", bundle: .module, comment: "A standard colour")
        case "Purple": String(localized: "Purple", bundle: .module, comment: "A standard colour")
        default: english
        }
    }
}

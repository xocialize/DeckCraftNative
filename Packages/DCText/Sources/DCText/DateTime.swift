// DCText — date and time fields (`a:fld type="datetime…"`): the text each field type shows for a moment,
// and the local clock. Port of deckcraft crates/text/src/datetime.rs (MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors).
//
// The field types and their formats follow ECMA-376 Part 1, §21.1.2.2.4 (`fld`): `datetime1` to
// `datetime13`, written as in PowerPoint's English (United States) Date and Time list. `datetime` and
// `datetimeFigureOut` show the language's short date. Numeric dates follow the run's language; formats
// with month or day names, or AM/PM, are only computed for English, so other languages keep the text the
// file was saved with.
import DCCore
import Foundation

/// A local date and time: what the clock read, or a fixed moment (tests, deterministic output).
public struct DateTime: Sendable, Hashable {
    public var year: Int32
    /// 1–12.
    public var month: UInt32
    /// 1–31.
    public var day: UInt32
    /// 0–23.
    public var hour: UInt32
    public var minute: UInt32
    public var second: UInt32

    public init(_ year: Int32, _ month: UInt32, _ day: UInt32, _ hour: UInt32, _ minute: UInt32, _ second: UInt32) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// The local date and time now (the user's time zone).
    public static func nowLocal() -> DateTime? {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
        guard let y = c.year, let mo = c.month, let d = c.day, let h = c.hour, let mi = c.minute, let s = c.second else { return nil }
        return DateTime(Int32(clamping: y), UInt32(clamping: mo), UInt32(clamping: d), UInt32(clamping: h), UInt32(clamping: mi), UInt32(clamping: s))
    }

    private static func isLeap(_ y: Int32) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    /// A real (proleptic Gregorian) calendar date and time of day.
    var isValid: Bool {
        guard (1 ... 9999).contains(year), (1 ... 12).contains(month) else { return false }
        let days: [UInt32] = [31, Self.isLeap(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= days[Int(month) - 1] else { return false }
        return hour < 24 && minute < 60 && second < 61
    }

    /// Day of the week, 0 = Sunday (Sakamoto's method; valid dates only).
    var weekday: Int {
        guard isValid else { return 0 }
        let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        var y = Int(year)
        if month < 3 { y -= 1 }
        return (y + y / 4 - y / 100 + y / 400 + t[Int(month) - 1] + Int(day)) % 7
    }
}

private let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
private let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

public enum DateFields {
    /// Is field `kind` a date/time field?
    public static func isDateField(_ kind: String) -> Bool { kind.hasPrefix("datetime") }

    /// The date and time field types PowerPoint's Header and Footer and Insert ▸ Date & Time offer, in the
    /// order the dialogs list them.
    public static let dateKinds = (1 ... 13).map { "datetime\($0)" }

    /// The text date/time field `kind` shows at `now` in a run of language `lang` (BCP 47). nil when `kind`
    /// isn't a date/time type this knows, `now` isn't a real date, or the format needs names in a language
    /// other than English: the field keeps its saved text.
    public static func fieldText(_ kind: String, _ lang: String?, _ now: DateTime) -> String? {
        guard now.isValid else { return nil }
        let trimmed = lang.map { String(rustTrim($0)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "en-US"
        let lang = rustASCIILowercase(trimmed)
        let english = lang == "en" || lang.hasPrefix("en-")
        let month = monthNames[Int(now.month) - 1]
        let mon = String(month.prefix(3))
        let day = dayNames[now.weekday]
        let (d, y) = (now.day, now.year)
        let yy = ((Int(y) % 100) + 100) % 100
        let h12 = now.hour % 12 == 0 ? 12 : now.hour % 12
        let ampm = now.hour < 12 ? "AM" : "PM"
        let (mi, s) = (now.minute, now.second)
        let short = shortDate(lang, now)
        func two(_ v: some BinaryInteger) -> String { v < 10 ? "0\(v)" : "\(v)" }
        func named(_ text: String) -> String? { english ? text : nil }
        switch kind {
        case "datetime", "datetimeFigureOut", "datetime1": return short
        case "datetime2": return named("\(day), \(month) \(d), \(y)")
        case "datetime3": return named("\(d) \(month) \(y)")
        case "datetime4": return named("\(month) \(d), \(y)")
        case "datetime5": return named("\(d)-\(mon)-\(two(yy))")
        case "datetime6": return named("\(month) \(two(yy))")
        case "datetime7": return named("\(mon)-\(two(yy))")
        case "datetime8": return named("\(short) \(h12):\(two(mi)) \(ampm)")
        case "datetime9": return named("\(short) \(h12):\(two(mi)):\(two(s)) \(ampm)")
        case "datetime10": return "\(now.hour):\(two(mi))"
        case "datetime11": return "\(now.hour):\(two(mi)):\(two(s))"
        case "datetime12": return named("\(h12):\(two(mi)) \(ampm)")
        case "datetime13": return named("\(h12):\(two(mi)):\(two(s)) \(ampm)")
        default: return nil
        }
    }

    /// The short (numeric) date of language `lang` (lower case), US order unless the language is known to
    /// write its dates another way.
    static func shortDate(_ lang: String, _ t: DateTime) -> String {
        let (y, m, d) = (t.year, t.month, t.day)
        func two(_ v: UInt32) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let primary = String(lang.split(separator: "-", omittingEmptySubsequences: false).first?.split(separator: "_", omittingEmptySubsequences: false).first ?? "")
        switch lang {
        case "en-gb", "en-au", "en-nz", "en-ie", "en-in": return "\(two(d))/\(two(m))/\(y)"
        case "en-ca", "fr-ca", "en-za": return "\(y)-\(two(m))-\(two(d))"
        default: break
        }
        switch primary {
        case "fr", "es", "it", "pt", "el", "ca", "vi": return "\(two(d))/\(two(m))/\(y)"
        case "de", "ru", "pl", "cs", "sk", "tr", "fi", "nb", "nn", "no", "da", "uk", "ro": return "\(two(d)).\(two(m)).\(y)"
        case "nl": return "\(d)-\(m)-\(y)"
        case "ja", "zh": return "\(y)/\(m)/\(d)"
        case "ko", "sv", "lt": return "\(y)-\(two(m))-\(two(d))"
        default: return "\(m)/\(d)/\(y)"
        }
    }
}

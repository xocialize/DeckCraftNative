// DCText — which script a character belongs to and which theme font slot (latin, ea, cs) draws it. Port
// of deckcraft crates/fonts/src/script.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).

/// An ISO 15924 script tag, e.g. `Arab`.
public typealias ScriptTag = String

/// The theme font slot a run's text draws from: `a:latin`, `a:ea` or `a:cs`.
public enum FontSlot: Sendable, Hashable {
    case latin, eastAsian, complexScript
}

public enum Script {
    private static let ranges: [(UInt32, UInt32, ScriptTag)] = [
        (0x0041, 0x005A, "Latn"), (0x0061, 0x007A, "Latn"), (0x00AA, 0x00AA, "Latn"), (0x00BA, 0x00BA, "Latn"),
        (0x00C0, 0x00D6, "Latn"), (0x00D8, 0x00F6, "Latn"), (0x00F8, 0x024F, "Latn"), (0x0370, 0x03FF, "Grek"),
        (0x0400, 0x052F, "Cyrl"), (0x0530, 0x058F, "Armn"), (0x0591, 0x05F4, "Hebr"), (0x0600, 0x06FF, "Arab"),
        (0x0700, 0x074F, "Syrc"), (0x0750, 0x077F, "Arab"), (0x0780, 0x07BF, "Thaa"), (0x07C0, 0x07FF, "Nkoo"),
        (0x0870, 0x08FF, "Arab"), (0x0900, 0x097F, "Deva"), (0x0980, 0x09FF, "Beng"), (0x0A00, 0x0A7F, "Guru"),
        (0x0A80, 0x0AFF, "Gujr"), (0x0B00, 0x0B7F, "Orya"), (0x0B80, 0x0BFF, "Taml"), (0x0C00, 0x0C7F, "Telu"),
        (0x0C80, 0x0CFF, "Knda"), (0x0D00, 0x0D7F, "Mlym"), (0x0D80, 0x0DFF, "Sinh"), (0x0E00, 0x0E7F, "Thai"),
        (0x0E80, 0x0EFF, "Laoo"), (0x0F00, 0x0FFF, "Tibt"), (0x1000, 0x109F, "Mymr"), (0x10A0, 0x10FF, "Geor"),
        (0x1100, 0x11FF, "Hang"), (0x1200, 0x139F, "Ethi"), (0x1780, 0x17FF, "Khmr"), (0x1E00, 0x1EFF, "Latn"),
        (0x1F00, 0x1FFF, "Grek"), (0x2C60, 0x2C7F, "Latn"), (0x2E80, 0x2FDF, "Hani"), (0x3040, 0x309F, "Hira"),
        (0x30A0, 0x30FF, "Kana"), (0x3100, 0x312F, "Bopo"), (0x3130, 0x318F, "Hang"), (0x31F0, 0x31FF, "Kana"),
        (0x3400, 0x4DBF, "Hani"), (0x4E00, 0x9FFF, "Hani"), (0xA720, 0xA7FF, "Latn"), (0xAC00, 0xD7AF, "Hang"),
        (0xF900, 0xFAFF, "Hani"), (0xFB00, 0xFB06, "Latn"), (0xFB1D, 0xFB4F, "Hebr"), (0xFB50, 0xFDFF, "Arab"),
        (0xFE70, 0xFEFF, "Arab"), (0xFF21, 0xFF3A, "Latn"), (0xFF41, 0xFF5A, "Latn"), (0xFF66, 0xFF9F, "Kana"),
        (0x10E60, 0x10E7F, "Arab"), (0x1EE00, 0x1EEFF, "Arab"), (0x20000, 0x323AF, "Hani"),
    ]

    /// Arabic-block characters every Arabic-script language shares (comma, tatweel, harakat): no script
    /// of their own, so they stay with their neighbours.
    private static func arabicCommon(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x060C, 0x061B, 0x061F, 0x0640, 0x064B ... 0x0655, 0x0670, 0xFEFF, 0xFD3E, 0xFD3F: true
        default: false
        }
    }

    public static func of(_ c: Unicode.Scalar) -> ScriptTag? {
        let cp = c.value
        if arabicCommon(cp) { return nil }
        // partition_point: the first range starting after `cp`.
        var lo = 0
        var hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].0 <= cp { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let r = ranges[lo - 1]
        return cp >= r.0 && cp <= r.1 ? r.2 : nil
    }

    public static func slot(ofScript s: ScriptTag) -> FontSlot {
        switch s {
        case "Hani", "Hira", "Kana", "Hang", "Bopo": .eastAsian
        case "Arab", "Hebr", "Syrc", "Thaa", "Nkoo", "Deva", "Beng", "Guru", "Gujr", "Orya", "Taml", "Telu", "Knda", "Mlym",
             "Sinh", "Thai", "Laoo", "Tibt", "Mymr", "Khmr":
            .complexScript
        default: .latin
        }
    }

    public static func slot(of c: Unicode.Scalar) -> FontSlot? {
        if let s = of(c) { return slot(ofScript: s) }
        let cp = c.value
        if (0x3000 ... 0x303F).contains(cp) || (0xFF00 ... 0xFFEF).contains(cp) || (0x3200 ... 0x33FF).contains(cp) {
            return .eastAsian
        }
        return nil
    }

    public static func defaultLanguage(_ s: ScriptTag) -> String? {
        switch s {
        case "Arab": "ar"
        case "Hebr": "he"
        case "Syrc": "syr"
        case "Thaa": "dv"
        case "Thai": "th"
        case "Deva": "hi"
        default: nil
        }
    }

    /// Each character's script and slot; neutrals (spaces, digits, punctuation) take the script and
    /// slot of the text before them (the first strong one at the start).
    public static func resolve(_ chars: [Unicode.Scalar]) -> [(script: ScriptTag?, slot: FontSlot)] {
        let own = chars.map { (of($0), slot(of: $0)) }
        let first = own.first(where: { $0.1 != nil }).map { ($0.0, $0.1 ?? .latin) } ?? (nil, .latin)
        var prev: (ScriptTag?, FontSlot) = first
        return own.map { s, sl in
            if let sl { prev = (s, sl) }
            return prev
        }
    }

    public static func joinsFollowing(_ c: Unicode.Scalar) -> Bool {
        let cp = c.value
        let letter: Bool
        switch cp {
        case 0x0620 ... 0x064A, 0x066E ... 0x06D3, 0x06FA ... 0x06FC, 0x06FF, 0x0750 ... 0x077F, 0x08A0 ... 0x08C9: letter = true
        default: letter = false
        }
        guard letter else { return false }
        switch cp {
        case 0x0621 ... 0x0625, 0x0627, 0x0629, 0x062F ... 0x0632, 0x0648, 0x0671 ... 0x0673, 0x0675 ... 0x0677, 0x0688 ... 0x0699,
             0x06C0, 0x06C3 ... 0x06CB, 0x06CD, 0x06CF, 0x06D2, 0x06D3, 0x0759 ... 0x075B, 0x076B, 0x076C, 0x0771, 0x0773, 0x0774,
             0x0778, 0x0779, 0x08AA ... 0x08AC, 0x08AE, 0x08B1, 0x08B2, 0x08B9:
            return false
        default:
            return true
        }
    }

    public static func joinsPreceding(_ c: Unicode.Scalar) -> Bool {
        let cp = c.value
        switch cp {
        case 0x0622 ... 0x064A, 0x066E ... 0x06D3, 0x06FA ... 0x06FC, 0x06FF, 0x0750 ... 0x077F, 0x08A0 ... 0x08C9: return cp != 0x0621
        default: return false
        }
    }
}

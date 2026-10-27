// DCText — auto-number bullet labels (`a:buAutoNum`): Latin, Roman, East Asian, Thai, Hindi, Arabic and
// Hebrew schemes as PowerPoint writes them. Port of deckcraft crates/text/src/lib.rs (`autonum` and its
// numerals; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore

private func scalar(_ v: UInt32) -> Character? { Unicode.Scalar(v).map(Character.init) }

func roman(_ n: UInt32, _ upper: Bool) -> String {
    let table: [(UInt32, String)] = [
        (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"),
        (5, "v"), (4, "iv"), (1, "i"),
    ]
    if n == 0 || n > 3999 { return String(n) }
    var n = n
    var s = ""
    for (v, r) in table {
        while n >= v {
            s += r
            n -= v
        }
    }
    return upper ? rustUppercase(s) : s
}

func alphaNum(_ n: UInt32, _ upper: Bool) -> String {
    if n == 0 { return "" }
    let m = n - 1
    let c = Character(Unicode.Scalar(UInt8(97 + m % 26)))
    let reps = Swift.min(m / 26 + 1, 50)
    let s = String(repeating: c, count: Int(reps))
    return upper ? rustUppercase(s) : s
}

/// Letters of a numbering alphabet: 1 → the first, past the end the letter doubles ("aa").
func letters(_ list: [Character], _ n: UInt32) -> String {
    let len = UInt32(Swift.max(list.count, 1))
    guard n >= 1 else { return "" }
    let i = n - 1
    let c = list.at(Int(i % len)) ?? "?"
    return String(repeating: c, count: Int(Swift.min(i / len + 1, 50)))
}

/// `n` written with the digits `zero...zero+9` (Thai, Devanagari, full-width digits).
func digitsIn(_ n: UInt32, _ zero: Unicode.Scalar) -> String {
    String(String(n).map { d in d.wholeNumberValue.flatMap { scalar(zero.value + UInt32($0)) } ?? d })
}

let cjkDigits: [Character] = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

/// Chinese numerals: 10 → 十, 11 → 十一, 25 → 二十五, 105 → 一百零五.
func chineseNum(_ n: UInt32) -> String {
    if n == 0 || n > 99_999 { return String(n) }
    let units: [Character?] = [nil, "十", "百", "千", "万"]
    let ds = String(n).compactMap(\.wholeNumberValue)
    var out = ""
    var zero = false
    for (i, d) in ds.enumerated() {
        let place = ds.count - 1 - i
        if d == 0 {
            zero = true
            continue
        }
        if zero {
            out.append("零")
            zero = false
        }
        // "十" alone for 10–19, not "一十".
        if !(d == 1 && place == 1 && i == 0) { out.append(cjkDigits.at(d) ?? "?") }
        if let u = units.at(place) ?? nil { out.append(u) }
    }
    return out
}

private let thai: [Character] = Array("กขคงจฉชซฌญฎฏฐฑฒณดตถทธนบปผฝพฟภมยรลวศษสหฬอฮ")
private let hindiVowels: [Character] = Array("अआइईउऊऋएऐओऔ")
private let hindiConsonants: [Character] = Array("कखगघङचछजझञटठडढणतथदधनपफबभमयरलवशषसह")
private let arabicAlphabet: [Character] = Array("ابتثجحخدذرزسشصضطظعغفقكلمنهوي")
private let arabicAbjad: [Character] = Array("ابجدهوزحطيكلمنسعفصقرشتثخذضظغ")
private let hebrew: [Character] = Array("אבגדהוזחטיכלמנסעפצקרשת")

/// Text of an auto-number bullet: `arabicPeriod` 3 → "3.". The East Asian, Thai, Hindi, Arabic and Hebrew
/// schemes are written as PowerPoint draws them: `ea1ChsPeriod` 10 → "十．", `ea1JpnKorPeriod` 10 → "一〇．"
/// (digit by digit), `arabicDbPeriod` 13 → "１３．", `thaiAlphaParenR` 4 → "ง)", `hindiAlpha1Period` 1 →
/// "क.", `arabic2Minus` 10 → "ي-" (abjad order), `circleNumWdWhitePlain` 13 → "③" (those circles go to ten).
public func autonum(_ scheme: String, _ n: UInt32) -> String {
    func circled(_ first: UInt32, _ count: UInt32) -> String {
        scalar(first + (n == 0 ? 0 : n - 1) % count).map { String($0) } ?? String(n)
    }
    let core: String
    if scheme.hasPrefix("romanUc") {
        core = roman(n, true)
    } else if scheme.hasPrefix("romanLc") {
        core = roman(n, false)
    } else if scheme.hasPrefix("alphaUc") {
        core = alphaNum(n, true)
    } else if scheme.hasPrefix("alphaLc") {
        core = alphaNum(n, false)
    } else if scheme.hasPrefix("circleNumWdWhite") {
        return circled(0x2460, 10)
    } else if scheme.hasPrefix("circleNumWdBlack") {
        return circled(0x2776, 10)
    } else if scheme.hasPrefix("circleNum") {
        return scalar(0x2460 + Swift.min(n == 0 ? 0 : n - 1, 19)).map { String($0) } ?? String(n)
    } else if scheme.hasPrefix("ea1Chs") || scheme.hasPrefix("ea1Cht") {
        core = chineseNum(n)
    } else if scheme.hasPrefix("ea1Jpn") {
        core = String(String(n).map { d in d.wholeNumberValue.flatMap { cjkDigits.at($0) } ?? d })
    } else if scheme.hasPrefix("arabicDb") {
        core = digitsIn(n, "０")
    } else if scheme.hasPrefix("thaiAlpha") {
        core = letters(thai, n)
    } else if scheme.hasPrefix("thaiNum") {
        core = digitsIn(n, "๐")
    } else if scheme.hasPrefix("hindiAlpha1") {
        core = letters(hindiConsonants, n)
    } else if scheme.hasPrefix("hindiAlpha") {
        core = letters(hindiVowels, n)
    } else if scheme.hasPrefix("hindiNum") {
        core = digitsIn(n, "०")
    } else if scheme.hasPrefix("arabic1") {
        core = letters(arabicAlphabet, n)
    } else if scheme.hasPrefix("arabic2") {
        core = letters(arabicAbjad, n)
    } else if scheme.hasPrefix("hebrew2") {
        core = letters(hebrew, n)
    } else {
        core = String(n)
    }
    // East Asian schemes end with a full-width full stop.
    let wide = scheme.hasPrefix("ea1") || scheme.hasPrefix("arabicDb")
    if scheme.hasSuffix("ParenBoth") { return "(\(core))" }
    if scheme.hasSuffix("ParenR") { return "\(core))" }
    if scheme.hasSuffix("Period") { return core + (wide ? "．" : ".") }
    if scheme.hasSuffix("Minus") { return core + "-" }
    return core
}

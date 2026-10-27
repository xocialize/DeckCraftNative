// Ported from deckcraft crates/model/src/numfmt.rs tests (MIT OR Apache-2.0).
import DCModel
import Testing

private let rub = #"_-* #\ ##0\ "₽"_-;\-* #\ ##0\ "₽"_-;_-* "-"??\ "₽"_-;_-@_-"#

@Suite struct NumFmtTests {
    @Test func scientificSubnormal() {
        #expect(NumFmt.format("0.00E+00", 5e-324, nil) == "4.94E-324")
        #expect(NumFmt.format("0.00E+00", Double.leastNormalMagnitude, nil) == "2.23E-308")
    }

    @Test func russianAccountingRoubles() {
        #expect(NumFmt.format(rub, 800_000.0, "ru-RU") == "800\u{a0}000 ₽")
        #expect(NumFmt.format(rub, 1_234_567.0, "ru-RU") == "1\u{a0}234\u{a0}567 ₽")
        #expect(NumFmt.format(rub, -5_000.0, "ru-RU") == "-5\u{a0}000 ₽")
        #expect(NumFmt.format(rub, 0.0, "ru-RU") == "- ₽")
    }

    @Test func commonCodes() {
        #expect(NumFmt.format("#,##0", 7000.0, "ru-RU") == "7\u{a0}000")
        #expect(NumFmt.format("#,##0", 7000.0, "en-US") == "7,000")
        #expect(NumFmt.format("#,##0", 7000.0, "de-DE") == "7.000")
        #expect(NumFmt.format("0.0%", 0.125, "ru-RU") == "12,5%")
        #expect(NumFmt.format("0.0%", 0.125, nil) == "12.5%")
        #expect(NumFmt.format("0%", 0.0, nil) == "0%")
        #expect(NumFmt.format("General", 2.5, "ru-RU") == "2,5")
        #expect(NumFmt.format("General", 400_000.0, "ru-RU") == "400000")
        #expect(NumFmt.format("General", 1.5e12, nil) == "1.5E+12")
        #expect(NumFmt.format("General", 1e-10, nil) == "1E-10")
        #expect(NumFmt.format("General", -2.5e-12, nil) == "-2.5E-12")
        #expect(NumFmt.format("General", 1e100, nil) == "1E+100")
        #expect(NumFmt.format("0.00", 1.23456, nil) == "1.23")
        #expect(NumFmt.format("#,##0.0#", 1234.5, nil) == "1,234.5")
        #expect(NumFmt.format("#,##0,", 12_345_678.0, nil) == "12,346")
        #expect(NumFmt.format("[$₽-419]#,##0", 1500.0, "ru-RU") == "₽1\u{a0}500")
        #expect(NumFmt.format("0;[Red]-0", -3.0, nil) == "-3")
        #expect(NumFmt.format("0;0", -3.0, nil) == "3")
        #expect(NumFmt.format("0", -3.0, nil) == "-3")
        #expect(NumFmt.format("\"x\"0", 5.0, nil) == "x5")
    }

    @Test func trailingCommasWithDecimals() {
        #expect(NumFmt.format("0.0,,", 15_000_000.0, "en-US") == "15.0")
        #expect(NumFmt.format("0.00,\"K\"", 15_000.0, "en-US") == "15.00K")
    }

    @Test func explicitEmptySectionsHideTheirValues() {
        for v in [3.0, -3.0, 0.0, -0.0] {
            #expect(NumFmt.format(";;;", v, nil) == "", "all sections empty: \(v)")
        }
        let cases: [(String, String, String, String)] = [
            (";0;0", "", "3", "0"),
            ("0;;0", "3", "", "0"),
            ("0;-0;", "3", "-3", ""),
            (";0", "", "3", ""),
            (#"";"0;;"#, ";3", "", ""),
            (#"\;0;;"#, ";3", "", ""),
        ]
        for (code, positive, negative, zero) in cases {
            #expect(NumFmt.format(code, 3.0, nil) == positive, "positive: \(code)")
            #expect(NumFmt.format(code, -3.0, nil) == negative, "negative: \(code)")
            #expect(NumFmt.format(code, 0.0, nil) == zero, "zero: \(code)")
        }
        #expect(NumFmt.format("0;-0;", -0.0, nil) == "")
    }

    @Test func blankWholeCodesAndGeneralKeepTheirFallback() {
        for code in ["", " \t", "General", " general "] {
            #expect(NumFmt.format(code, 2.5, nil) == "2.5", "\(code)")
            #expect(NumFmt.format(code, -2.5, nil) == "-2.5", "\(code)")
            #expect(NumFmt.format(code, 0.0, nil) == "0", "\(code)")
            #expect(NumFmt.format(code, 2.5, "de-DE") == "2,5", "\(code)")
        }
    }

    @Test func scientificFormats() {
        #expect(NumFmt.format("0.00E+00", 1234.0, nil) == "1.23E+03")
        #expect(NumFmt.format("0.00E+00", 1234.0, "ru-RU") == "1,23E+03")
        #expect(NumFmt.format("0.00E+00", 0.00012, nil) == "1.20E-04")
        #expect(NumFmt.format("0.00E+00", -1234.0, nil) == "-1.23E+03")
        #expect(NumFmt.format("0.00E+00", 0.0, nil) == "0.00E+00")
        #expect(NumFmt.format("0.0E+000", 5e10, nil) == "5.0E+010")
        #expect(NumFmt.format("0.0E-0", 1234.0, nil) == "1.2E3")
        #expect(NumFmt.format("0.0E-0", 0.0012, nil) == "1.2E-3")
        #expect(NumFmt.format("0E+00", 9999.0, nil) == "1E+04")
        #expect(NumFmt.format("0.00E+00", 9.999, nil) == "1.00E+01")
        #expect(NumFmt.format("0.00e+00", 1234.0, nil) == "1.23e+03")
        #expect(NumFmt.format("##0.0E+0", 12_345.0, nil) == "12.3E+3")
        #expect(NumFmt.format("##0.0E+0", 0.012, nil) == "12.0E-3")
        #expect(NumFmt.format("##0.0E+0", 999.96, nil) == "1.0E+3")
    }

    @Test func neverTraps() {
        for code in ["", ";", ";;;", "\"", "[", "\\", "0.", ".", "#,", "%", "_", "*", "@", "0E+00", "[$", "\"unterminated"] {
            for v in [0.0, -1.5, 1e300, .nan, .infinity, 1e-300] {
                _ = NumFmt.format(code, v, "ru")
            }
        }
    }
}

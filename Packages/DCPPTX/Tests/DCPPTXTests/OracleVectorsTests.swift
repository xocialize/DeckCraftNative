// DCPPTX against deckcraft-pptx itself: `Tools/oracle/pptx-vectors` compiles the pinned crate's xml, opc,
// cfb, png, maps, custgeom, tables and dgm modules into a tool, runs them over the oracle corpus and over
// generated inputs, and writes what they return to `DECKCRAFT_FIXTURES/pptx/`. Every line here is one
// call, its inputs and deckcraft's result; the Swift port must give the same result, byte for byte.
import DCCore
import DCGeometry
import DCModel
@testable import DCPPTX
import DCTestSupport
import Foundation
import Testing

private let vectorDir = Fixtures.root.appending(path: "pptx", directoryHint: .isDirectory)
private let haveVectors = FileManager.default.fileExists(atPath: vectorDir.appending(path: "modules.txt").path)

// MARK: - Line helpers

private func records(_ name: String) throws -> [[Substring]] {
    let text = try String(contentsOf: vectorDir.appending(path: name), encoding: .utf8)
    return text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
}

private func unhex(_ s: Substring) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count / 2)
    var hi: UInt8?
    for c in s.utf8 {
        let v: UInt8 = switch c {
        case 0x30 ... 0x39: c - 0x30
        case 0x61 ... 0x66: c - 0x61 + 10
        default: c - 0x41 + 10
        }
        if let h = hi {
            out.append(h << 4 | v)
            hi = nil
        } else {
            hi = v
        }
    }
    return out
}

private func str(_ s: Substring) -> String { String(decoding: unhex(s), as: UTF8.self) }

private func hex(_ b: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for x in b {
        out.append(digits[Int(x >> 4)])
        out.append(digits[Int(x & 0xF)])
    }
    return String(decoding: out, as: UTF8.self)
}

private func hs(_ s: some StringProtocol) -> String { hex(s.utf8) }
private func optHS(_ s: String?) -> String { s.map(hs) ?? "-" }
private func bits(_ v: Double) -> String { rustHex(v.bitPattern, width: 16, uppercase: false) }
private func double(_ s: Substring) -> Double { Double(bitPattern: UInt64(s, radix: 16) ?? 0) }

/// The tool's `dump`: `E<name>[,<key>=<value>]…{children}`, texts as `T<text>;`, strings in hex.
private func dump(_ e: XMLEl, _ out: inout String) {
    out += "E" + hs(e.name)
    for (k, v) in e.attrs {
        out += "," + hs(k) + "=" + hs(v)
    }
    out += "{"
    for c in e.children {
        switch c {
        case .el(let c): dump(c, &out)
        case .text(let t): out += "T" + hs(t) + ";"
        }
    }
    out += "}"
}

private func dump(_ e: XMLEl) -> String {
    var s = ""
    dump(e, &s)
    return s
}

/// The tool's `queries`.
private func queries(_ d: XMLDoc) -> String {
    let r = d.root
    var q: [String] = []
    for n in ["id", "r:id", "x:id", "v", "a", "xmlns", "b", "val", "name", "a:b"] {
        q.append(optHS(r.attr(n)))
    }
    q.append(r.i64("v").map { String($0) } ?? "-")
    q.append(r.i32("v").map { String($0) } ?? "-")
    q.append(r.u32("v").map { String($0) } ?? "-")
    q.append(r.f64("v").map(bits) ?? "-")
    q.append(r.bool("v").map { $0 ? "1" : "0" } ?? "-")
    q.append(hs(r.text))
    q.append(optHS(r.find("t")?.text))
    q.append(hs(r.local))
    q.append(hs(r.prefix))
    q.append(String(d.nsDecls().count))
    q.append(String(r.findAll("t").count))
    return q.joined(separator: ",")
}

/// Mismatches by call, the first few of each kept for the report.
private struct Tally {
    var checked = 0
    var failed: [String: Int] = [:]
    var examples: [String] = []

    mutating func check(_ kind: some StringProtocol, _ got: String, _ want: some StringProtocol, _ input: @autoclosure () -> String) {
        checked += 1
        if got.utf8.elementsEqual(want.utf8) { return }
        failed[String(kind), default: 0] += 1
        if examples.count < 12 {
            examples.append("\(kind) \(input().prefix(300)): got \(got.prefix(300)) want \(want.prefix(300))")
        }
    }

    var report: String { "\(failed) — \(examples.joined(separator: "\n"))" }
}

private func pathsSpec(_ paths: [CustomPath]) -> String {
    if paths.isEmpty { return "-" }
    return paths.map { p in
        "\(bits(p.w)):\(bits(p.h)):\(hs(p.d)):\(p.fill.rawValue):\(p.stroke ? 1 : 0)"
    }.joined(separator: ",")
}

private func parsePathsSpec(_ s: Substring) -> [CustomPath] {
    if s == "-" { return [] }
    return s.split(separator: ",").map { item in
        let f = item.split(separator: ":", omittingEmptySubsequences: false)
        return CustomPath(w: double(f[0]), h: double(f[1]), d: str(f[2]), fill: FillMode(rawValue: String(f[3])) ?? .norm, stroke: f[4] == "1")
    }
}

private func animClass(_ s: Substring) -> AnimClass { AnimClass(rawValue: String(s)) ?? .entrance }

private func nodesSpec(_ nodes: [DiagramNode]) -> String {
    nodes.map { "\(hs($0.text)):\($0.level):\($0.assistant ? 1 : 0):\(hs($0.title))" }.joined(separator: ",")
}

private func relsSpec(_ r: Rels, trailingZero: Bool) -> String {
    if r.items.isEmpty { return "-" }
    return r.items.map { it in
        "\(hs(it.id)):\(hs(it.kind)):\(hs(it.ty)):\(hs(it.targetRaw)):\(hs(it.target)):\(it.external ? 1 : 0)" + (trailingZero ? ":0;" : ";")
    }.joined()
}

// MARK: - Tests

@Suite(.serialized) struct OracleVectorsTests {
    /// Every input of `xml.txt` parses (or fails, with quick-xml's message) as deckcraft's parser does,
    /// to the same tree, the same `to_xml` and the same answers to the element queries.
    @Test(.enabled(if: haveVectors, "no pptx vectors: run Tools/oracle/pptx-vectors"))
    func xmlParserMatchesDeckcraft() throws {
        var t = Tally()
        for r in try records("xml.txt") {
            let input = unhex(r[0])
            let label = String(r[0].prefix(200))
            do {
                let d = try XML.parse(input)
                t.check("parse", "ok", r[1], label)
                if r[1] == "ok" {
                    t.check("dump", dump(d.root), r[2], label)
                    t.check("to_xml", hs(d.root.toXML()), r[3], label)
                    t.check("queries", queries(d), r[4], label)
                }
            } catch {
                guard case .xml(let message) = error else { continue }
                t.check("parse", "err\t" + message, r[1] + "\t" + (r.count > 2 ? r[2] : ""), label)
            }
        }
        #expect(t.checked > 30_000)
        #expect(t.failed.isEmpty, "\(t.report)")
    }

    @Test(.enabled(if: haveVectors, "no pptx vectors: run Tools/oracle/pptx-vectors"))
    func escapesMatchDeckcraft() throws {
        var t = Tally()
        for r in try records("escape.txt") {
            let s = str(r[0])
            t.check("esc", hs(XML.esc(s)), r[1], String(r[0]))
            t.check("esc_attr", hs(XML.escAttr(s)), r[2], String(r[0]))
        }
        #expect(t.checked > 6000)
        #expect(t.failed.isEmpty, "\(t.report)")
    }

    /// Every part of every oracle-corpus `.pptx`, through `Package`: the bytes it holds, its content type,
    /// its relationships, its name as written; XML parts parse to the same tree and re-serialise to the
    /// same `to_xml` as deckcraft's.
    @Test(.enabled(if: haveVectors, "no pptx vectors: run Tools/oracle/pptx-vectors"))
    func corpusPartsMatchDeckcraft() throws {
        guard let decks = Fixtures.oracleCorpus?.appending(path: "decks", directoryHint: .isDirectory) else { return }
        var t = Tally()
        var packages: [String: Package] = [:]
        var parts = 0, xmlParts = 0
        for r in try records("corpus.txt") {
            switch r[0] {
            case "deck":
                let name = String(r[1])
                let bytes = try [UInt8](Data(contentsOf: decks.appending(path: name)))
                if let p = try? Package.open(bytes) { packages[name] = p }
                t.check("deck", packages[name] != nil ? "ok" : "err", r[2], name)
            case "part":
                guard let p = packages[String(r[1])] else { continue }
                let name = str(r[2])
                let data = p.get(name)
                parts += 1
                t.check("len", data.map { String($0.count) } ?? "-", r[3], name)
                t.check("content_type", optHS(p.contentType(name)), r[4], name)
                t.check("rels", relsSpec(p.rels(name), trailingZero: true), r[5], name)
                t.check("original_name", optHS(p.originalName(name)), r[6], name)
                if r[7] == "-" { continue }
                xmlParts += 1
                guard let data else { continue }
                do {
                    let d = try XML.parse(data)
                    t.check("parse", "ok", r[7], name)
                    if r[7] == "ok" {
                        t.check("dump", dump(d.root), r[8], name)
                        t.check("to_xml", hs(d.root.toXML()), r[9], name)
                    }
                } catch {
                    t.check("parse", "err", r[7], name)
                }
            default:
                break
            }
        }
        #expect(packages.count == 9)
        #expect(parts > 400 && xmlParts > 300)
        #expect(t.failed.isEmpty, "\(t.report)")
    }

    /// The opc path functions, rels parts, package budgets, cfb, png, maps, custgeom, tables and dgm:
    /// each line of `modules.txt` is one call with deckcraft's result.
    @Test(.enabled(if: haveVectors, "no pptx vectors: run Tools/oracle/pptx-vectors"))
    func modulesMatchDeckcraft() throws {
        var t = Tally()
        for r in try records("modules.txt") {
            let kind = r[0]
            let label = r.dropFirst().prefix(3).map { String($0.prefix(120)) }.joined(separator: " ")
            switch kind {
            case "norm": t.check(kind, hs(OPC.norm(str(r[1]))), r[2], label)
            case "dirof": t.check(kind, hs(OPC.dirOf(str(r[1]))), r[2], label)
            case "fileof": t.check(kind, hs(OPC.fileOf(str(r[1]))), r[2], label)
            case "relspath": t.check(kind, hs(OPC.relsPath(str(r[1]))), r[2], label)
            case "sidecar": t.check(kind, OPC.sidecarPart(str(r[1])) ? "1" : "0", r[2], label)
            case "resolve": t.check(kind, hs(OPC.resolve(str(r[1]), str(r[2]))), r[3], label)
            case "relative": t.check(kind, hs(OPC.relative(str(r[1]), str(r[2]))), r[3], label)
            case "rels": t.check(kind, relsSpec(OPC.relsFromBytes(unhex(r[1]), str(r[2])), trailingZero: false), r[3], label)
            case "package":
                let z = unhex(r[1])
                let got: String
                if let p = try? Package.openWithin(z, maxPart: Int(r[2]) ?? 0, maxTotal: Int(r[3]) ?? 0, maxWork: Int(r[4]) ?? 0) {
                    got = ["a.xml", "A.XML", "b.bin", "/b.bin", "dir/", "c/d.xml", "e", "dup", "x/y.xml", "x\\y.xml", "[content_types].xml"]
                        .map { "\(hs($0)):\(p.get($0).map(hex) ?? "-"):\(optHS(p.originalName($0)));" }.joined()
                } else {
                    got = "err"
                }
                t.check(kind, got, r[5].hasPrefix("err") ? "err" : r[5], label)
            case "cfb": t.check(kind, CFB.isEncrypted(unhex(r[1])) ? "1" : "0", r[2], label)
            case "png": t.check(kind, hex(PNG.transparent1x1()), r[1], label)
            case "trans":
                var w = W.frag()
                let ns = Maps.transitionToXML(&w, str(r[1]), str(r[2]))
                t.check(kind, (ns ?? "-") + "\t" + hs(w.s), r[3] + "\t" + r[4], label)
            case "transread":
                let got = (try? XML.parse(unhex(r[1]))).flatMap { Maps.transitionFromXML($0.root) }.map { "\(hs($0.kind)):\(hs($0.option))" } ?? "-"
                t.check(kind, got, r[2], label)
            case "optsub": t.check(kind, hs(Maps.optionFromSubtype(str(r[1]), UInt32(r[2]) ?? 0)), r[3], label)
            case "subopt": t.check(kind, Maps.subtypeFromOption(str(r[1]), str(r[2])).map { String($0) } ?? "-", r[3], label)
            case "effpreset": t.check(kind, optHS(Maps.effectForPreset(animClass(r[1]), UInt32(r[2]) ?? 0)), r[3], label)
            case "fallback": t.check(kind, hs(Maps.fallbackEffect(animClass(r[1]))), r[2], label)
            case "presetfor":
                var a = Animation.default
                a.class = animClass(r[1])
                a.effect = str(r[2])
                a.option = str(r[3])
                a.presetId = UInt32(r[4])
                t.check(kind, String(Maps.presetFor(a)), r[5], label)
            case "guide":
                var g = Guides(double(r[1]), double(r[2]))
                g.set("x1", 1234.5)
                t.check(kind, bits(g.eval(str(r[3]))), r[4], label)
            case "cgread":
                let d = try XML.parse(unhex(r[1]))
                t.check(kind, pathsSpec(CustGeom.readCustGeom(d.root, double(r[2]), double(r[3]))), r[4], label)
            case "cgwrite":
                var w = W.frag()
                CustGeom.writeCustGeom(&w, parsePathsSpec(r[1]))
                t.check(kind, hs(w.s), r[2], label)
            case "parsepath":
                let p = CustGeom.parsePath(str(r[1]))
                let got = p.isEmpty ? "-" : p.map { c, v in String(c) + v.map { ":" + bits($0) }.joined() + ";" }.joined()
                t.check(kind, got, r[2], label)
            case "guid": t.check(kind, hs(Tables.guid(str(r[1]))), r[2], label)
            case "stylefromguid": t.check(kind, hs(Tables.styleFromGUID(str(r[1]))), r[2], label)
            case "guidforstyle":
                let (g, define) = Tables.guidForStyle(str(r[1]))
                t.check(kind, hs(g) + "\t" + (define ? "1" : "0"), r[2] + "\t" + r[3], label)
            case "isownguid": t.check(kind, Tables.isOwnGUID(str(r[1])) ? "1" : "0", r[2], label)
            case "tablestyles":
                let used: [String] = r[1].isEmpty ? [] : r[1].split(separator: ",", omittingEmptySubsequences: false).map(str)
                let defs: [TableStyleDef] = r[2].isEmpty ? [] : r[2].split(separator: ",", omittingEmptySubsequences: false).map { item in
                    let f = item.split(separator: ":", omittingEmptySubsequences: false)
                    return TableStyleDef(id: str(f[0]), raw: str(f[1]))
                }
                t.check(kind, hex(Tables.tableStylesXML(used, defs)), r[3], label)
            case "layoutid": t.check(kind, hs(Dgm.layoutID(str(r[1]))), r[2], label)
            case "layoutxml": t.check(kind, hex(Dgm.layoutXML(str(r[1]))), r[2], label)
            case "qsid": t.check(kind, hs(Dgm.qsID(str(r[1]))), r[2], label)
            case "stylexml": t.check(kind, hex(Dgm.styleXML(str(r[1]))), r[2], label)
            case "csid": t.check(kind, hs(Dgm.csID(str(r[1]))), r[2], label)
            case "colorsxml": t.check(kind, hex(Dgm.colorsXML(str(r[1]))), r[2], label)
            case "stylefor": t.check(kind, hs(Dgm.styleFor(str(r[1]))), r[2], label)
            case "colorsfor": t.check(kind, hs(Dgm.colorsFor(str(r[1]))), r[2], label)
            case "kindfor": t.check(kind, hs(Dgm.kindFor(str(r[1]), str(r[2]))), r[3], label)
            case "dataxml":
                let nodes: [DiagramNode] = r[7].isEmpty ? [] : r[7].split(separator: ",", omittingEmptySubsequences: false).map { item in
                    let f = item.split(separator: ":", omittingEmptySubsequences: false)
                    return DiagramNode(text: str(f[0]), level: UInt8(f[1]) ?? 0, picture: nil, assistant: f[2] == "1", title: str(f[3]))
                }
                let pics: [(Int, String)] = r[8].isEmpty ? [] : r[8].split(separator: ",").map { item in
                    let f = item.split(separator: ":", omittingEmptySubsequences: false)
                    return (Int(f[0]) ?? 0, str(f[1]))
                }
                let d = Diagram(kind: str(r[1]), nodes: nodes, style: str(r[2]), colors: str(r[3]), layoutId: str(r[4]))
                t.check(kind, hex(Dgm.dataXML(d, UInt32(r[5]) ?? 0, str(r[6]), pics)), r[9], label)
            case "outline":
                let d = try XML.parse(unhex(r[1]))
                let pics = Dgm.nodePictures(d.root).map { "\($0.0):\(hs($0.1))" }.joined(separator: ",")
                t.check(kind, nodesSpec(Dgm.outline(d.root)) + "\t" + pics, r[2] + "\t" + r[3], label)
            default:
                Issue.record("unknown vector kind \(kind)")
            }
        }
        #expect(t.checked > 60_000)
        #expect(t.failed.isEmpty, "\(t.report)")
    }
}

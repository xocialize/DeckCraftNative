// DCPPTX — SmartArt (DrawingML diagrams): the outline ⇄ the data model, and the layout, quick style and
// colour definitions DeckCraft writes for its own layouts. Port of deckcraft crates/pptx/src/dgm.rs (MIT
// OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// A diagram's data part holds its points (`dgm:pt`: the document, one per node, and the transitions
// PowerPoint pairs with each link) and its links (`dgm:cxn` of type `parOf`, parent → child, ordered by
// `srcOrd`). The outline is that tree flattened depth first.
import DCCore
import DCModel

/// The `dgm` module.
enum Dgm {
    static let nsDGM = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    static let nsDSP = "http://schemas.microsoft.com/office/drawing/2008/diagram"
    static let ctData = "application/vnd.openxmlformats-officedocument.drawingml.diagramData+xml"
    static let ctLayout = "application/vnd.openxmlformats-officedocument.drawingml.diagramLayout+xml"
    static let ctStyle = "application/vnd.openxmlformats-officedocument.drawingml.diagramStyle+xml"
    static let ctColors = "application/vnd.openxmlformats-officedocument.drawingml.diagramColors+xml"
    static let ctDrawing = "application/vnd.ms-office.drawingml.diagramDrawing+xml"
    static let rtDrawing = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"
    static let qsBase = "urn:microsoft.com/office/officeart/2005/8/quickstyle/"
    static let csBase = "urn:microsoft.com/office/officeart/2005/8/colors/"
    /// Most nodes read from one diagram.
    static let maxNodes = 2000

    /// After the last `/` (`rsplit('/').next()`).
    private static func lastSegment(_ s: String) -> String {
        guard let i = s.utf8.lastIndex(of: UInt8(ascii: "/")) else { return s }
        return String(s[s.utf8.index(after: i)...])
    }

    /// The rest of `s` after `prefix`, if it starts with it (`strip_prefix`).
    private static func stripPrefix(_ s: String, _ prefix: String) -> Substring? {
        hasBytePrefix(s, prefix) ? s[s.utf8.index(s.startIndex, offsetBy: prefix.utf8.count)...] : nil
    }

    /// `r.get(..1).and_then(|n| n.parse::<u8>().ok())`: the first byte, when it is an ASCII digit.
    private static func firstDigit(_ r: Substring?) -> Int? {
        guard let b = r?.utf8.first, b >= 0x30, b <= 0x39 else { return nil }
        return Int(b - 0x30)
    }

    /// PowerPoint's quick style for a SmartArt Style.
    static func qsID(_ style: String) -> String {
        let s = switch style {
        case "subtle": "simple3"
        case "intense": "simple5"
        case "outline": "simple4"
        case "polished": "3d1"
        case "inset": "3d2"
        case "cartoon": "3d3"
        case "powder": "3d4"
        case "brick": "3d5"
        default: "simple1"
        }
        return qsBase + s
    }

    /// The SmartArt Style closest to a quick style id.
    static func styleFor(_ qs: String) -> String {
        switch lastSegment(qs) {
        case "simple1", "": ""
        case "simple4": "outline"
        case "3d1": "polished"
        case "3d2": "inset"
        case "3d3": "cartoon"
        case "3d4": "powder"
        case "3d5": "brick"
        case "simple2", "simple3": "subtle"
        default: "intense"
        }
    }

    /// PowerPoint's colour definition for Change Colors.
    static func csID(_ colors: String) -> String {
        if let a = firstDigit(stripPrefix(colors, "range")), (2 ... 5).contains(a) {
            return csBase + "colorful\(a)"
        }
        let grad = hasByteSuffix(colors, "Grad")
        if let n = firstDigit(stripPrefix(colors, "accent")), (1 ... 6).contains(n) {
            return csBase + "accent\(n)_\(grad ? 3 : 2)"
        }
        return csBase + "colorful1"
    }

    /// The accents a Change Colors choice fills shapes with, in turn.
    static func fillAccents(_ colors: String) -> [String] {
        if let a = firstDigit(stripPrefix(colors, "range")), (2 ... 5).contains(a) {
            return ["accent\(a)", "accent\(a + 1)"]
        }
        if let n = firstDigit(stripPrefix(colors, "accent")), (1 ... 6).contains(n) {
            return ["accent\(n)"]
        }
        return (1 ... 6).map { "accent\($0)" }
    }

    /// Change Colors from a colour definition id: `accentN_…` keeps accent N, anything else is colourful.
    static func colorsFor(_ cs: String) -> String {
        let last = lastSegment(cs)
        if let rest = stripPrefix(last, "colorful"), let a = rustParseUnsigned(rest, as: UInt8.self), (2 ... 5).contains(a) {
            return "range\(a)\(a + 1)"
        }
        let parts = (stripPrefix(last, "accent") ?? "").split(separator: "_", omittingEmptySubsequences: false)
        let n = parts.first.flatMap { rustParseUnsigned($0, as: UInt8.self) }
        let second = parts.count > 1 ? parts[1] : nil
        if let n, (1 ... 6).contains(n) {
            if let second, second == "3" || second == "4" || second == "5" { return "accent\(n)Grad" }
            return "accent\(n)"
        }
        return ""
    }

    /// PowerPoint's built-in layout DeckCraft's layout `kind` is written as.
    static func layoutID(_ kind: String) -> String {
        switch kind {
        case "blockList": "urn:microsoft.com/office/officeart/2005/8/layout/default"
        case "hBulletList": "urn:microsoft.com/office/officeart/2005/8/layout/hList1"
        case "process": "urn:microsoft.com/office/officeart/2005/8/layout/process1"
        case "chevron": "urn:microsoft.com/office/officeart/2005/8/layout/chevron1"
        case "verticalProcess": "urn:microsoft.com/office/officeart/2005/8/layout/process2"
        case "stepUp": "urn:microsoft.com/office/officeart/2009/3/layout/StepUpProcess"
        case "cycle": "urn:microsoft.com/office/officeart/2005/8/layout/cycle2"
        case "blockCycle": "urn:microsoft.com/office/officeart/2005/8/layout/cycle5"
        case "radial": "urn:microsoft.com/office/officeart/2005/8/layout/radial1"
        case "hierarchy": "urn:microsoft.com/office/officeart/2005/8/layout/hierarchy1"
        case "pyramid": "urn:microsoft.com/office/officeart/2005/8/layout/pyramid1"
        case "invertedPyramid": "urn:microsoft.com/office/officeart/2005/8/layout/pyramid3"
        case "matrix": "urn:microsoft.com/office/officeart/2005/8/layout/matrix3"
        case "titledMatrix": "urn:microsoft.com/office/officeart/2005/8/layout/matrix1"
        case "pictureList": "urn:microsoft.com/office/officeart/2005/8/layout/vList4"
        case "pictureCaption": "urn:microsoft.com/office/officeart/2005/8/layout/pList1"
        case "pictureProcess": "urn:microsoft.com/office/officeart/2005/8/layout/hProcess10"
        case "pictureHList": "urn:microsoft.com/office/officeart/2005/8/layout/pList2"
        case "timeline": "urn:microsoft.com/office/officeart/2005/8/layout/hProcess11"
        case "venn": "urn:microsoft.com/office/officeart/2005/8/layout/venn1"
        case "target": "urn:microsoft.com/office/officeart/2005/8/layout/target1"
        case "textCycle": "urn:microsoft.com/office/officeart/2005/8/layout/cycle1"
        case "continuousCycle": "urn:microsoft.com/office/officeart/2005/8/layout/cycle3"
        case "horizontalHierarchy": "urn:microsoft.com/office/officeart/2005/8/layout/hierarchy2"
        case "gridMatrix": "urn:microsoft.com/office/officeart/2005/8/layout/matrix2"
        case "gear": "urn:microsoft.com/office/officeart/2005/8/layout/gear1"
        case "funnel": "urn:microsoft.com/office/officeart/2005/8/layout/funnel1"
        case "segmentedCycle": "urn:microsoft.com/office/officeart/2005/8/layout/cycle8"
        case "multidirectionalCycle": "urn:microsoft.com/office/officeart/2005/8/layout/cycle7"
        case "orgChart": "urn:microsoft.com/office/officeart/2005/8/layout/orgChart1"
        case "halfCircleOrgChart": "urn:microsoft.com/office/officeart/2008/layout/HalfCircleOrganizationChart"
        case "nameTitleOrgChart": "urn:microsoft.com/office/officeart/2008/layout/NameandTitleOrganizationalChart"
        case "verticalBoxList": "urn:microsoft.com/office/officeart/2005/8/layout/list1"
        case "trapezoidList": "urn:microsoft.com/office/officeart/2005/8/layout/hList6"
        case "tableList": "urn:microsoft.com/office/officeart/2005/8/layout/hList3"
        case "accentProcess": "urn:microsoft.com/office/officeart/2005/8/layout/process3"
        case "continuousBlockProcess": "urn:microsoft.com/office/officeart/2005/8/layout/hProcess9"
        case "bendingProcess": "urn:microsoft.com/office/officeart/2005/8/layout/process5"
        case "linearVenn": "urn:microsoft.com/office/officeart/2005/8/layout/venn3"
        case "stackedVenn": "urn:microsoft.com/office/officeart/2005/8/layout/venn2"
        case "nestedTarget": "urn:microsoft.com/office/officeart/2005/8/layout/target2"
        case "cycleMatrix": "urn:microsoft.com/office/officeart/2005/8/layout/cycle4"
        case "segmentedPyramid": "urn:microsoft.com/office/officeart/2005/8/layout/pyramid4"
        case "pie": "urn:microsoft.com/office/officeart/2005/8/layout/chart3"
        default: "urn:microsoft.com/office/officeart/2005/8/layout/vList2"
        }
    }

    /// The kinds `kindFor` matches exactly, in order.
    private static let exactKinds = [
        "blockList", "hBulletList", "process", "chevron", "verticalProcess", "stepUp", "cycle", "blockCycle", "radial",
        "hierarchy", "pyramid", "invertedPyramid", "matrix", "titledMatrix", "pictureList", "pictureCaption",
        "pictureProcess", "pictureHList", "timeline", "venn", "target", "textCycle", "continuousCycle",
        "horizontalHierarchy", "gridMatrix", "gear", "funnel", "segmentedCycle", "multidirectionalCycle", "orgChart",
        "halfCircleOrgChart", "nameTitleOrgChart", "verticalBoxList", "trapezoidList", "tableList", "accentProcess",
        "continuousBlockProcess", "bendingProcess", "linearVenn", "stackedVenn", "nestedTarget", "cycleMatrix",
        "segmentedPyramid", "pie", "list",
    ]

    /// The DeckCraft layout closest to a PowerPoint layout (by its id and category).
    static func kindFor(_ layoutID: String, _ category: String) -> String {
        let last = rustASCIILowercase(lastSegment(layoutID))
        // DeckCraft before Picture Accent Process got its own id wrote it as pList2 (Horizontal Picture
        // List) with its own layout part in the process category; PowerPoint's pList2 is a list.
        if last == "plist2" && eqIgnoreASCIICase(category, "process") {
            return "pictureProcess"
        }
        // Exact ids first: the layouts DeckCraft writes, and their closest siblings.
        for k in exactKinds where bytesEqual(layoutID, Dgm.layoutID(k)) {
            return k
        }
        let s = Array((last + " " + rustASCIILowercase(category)).utf8)
        func has(_ needle: String) -> Bool {
            let n = Array(needle.utf8)
            guard s.count >= n.count else { return false }
            return (0 ... s.count - n.count).contains { s[$0 ..< $0 + n.count].elementsEqual(n) }
        }
        if has("gear") { return "gear" }
        if has("funnel") { return "funnel" }
        if has("venn") { return "venn" }
        if has("target") { return "target" }
        if has("timeline") { return "timeline" }
        if has("nameandtitle") { return "nameTitleOrgChart" }
        if has("orgchart") || has("organizationchart") || has("organizationalchart") { return "orgChart" }
        if has("hierarchy") { return "hierarchy" }
        if has("radial") { return "radial" }
        if has("cycle") { return "cycle" }
        if has("pyramid") { return "pyramid" }
        if has("matrix") { return "matrix" }
        if has("chevron") { return "chevron" }
        if has("process") || has("arrow") { return "process" }
        if last == "default" { return "blockList" }
        if hasBytePrefix(last, "hlist") { return "hBulletList" }
        return "list"
    }

    static func category(_ kind: String) -> String {
        switch kind {
        case "process", "chevron", "verticalProcess", "stepUp", "pictureProcess", "timeline", "gear", "funnel", "accentProcess",
             "continuousBlockProcess", "bendingProcess":
            "process"
        case "venn", "target", "linearVenn", "stackedVenn", "nestedTarget": "relationship"
        case "cycle", "blockCycle", "radial", "textCycle", "continuousCycle", "segmentedCycle", "multidirectionalCycle", "cycleMatrix", "pie":
            "cycle"
        case "hierarchy", "horizontalHierarchy", "orgChart", "halfCircleOrgChart", "nameTitleOrgChart": "hierarchy"
        case "pyramid", "invertedPyramid", "segmentedPyramid": "pyramid"
        case "matrix", "titledMatrix", "gridMatrix": "matrix"
        default: "list"
        }
    }

    /// A model id, stable for a given diagram (`seed`) and point number.
    static func guid(_ seed: UInt32, _ n: Int) -> String {
        "{" + rustHex(seed, width: 8) + "-D1A6-4C0A-9E5B-" + rustHex(UInt64(truncatingIfNeeded: n), width: 12) + "}"
    }

    private static func text(_ w: inout W, _ t: String) {
        w.open0("dgm:t")
        w.empty0("a:bodyPr")
        w.empty0("a:lstStyle")
        w.open0("a:p")
        if t.isEmpty {
            w.empty("a:endParaRPr", A().a("lang", "en-US"))
        } else {
            w.open0("a:r")
            w.empty("a:rPr", A().a("lang", "en-US"))
            w.elt("a:t", t)
            w.close("a:r")
        }
        w.close("a:p")
        w.close("dgm:t")
    }

    /// `ppt/diagrams/dataN.xml` for the outline. `drawingRel` is the slide's relationship id of the
    /// cached drawing; `pics` the data part's relationship ids of node pictures, by node index.
    static func dataXML(_ d: Diagram, _ seed: UInt32, _ drawingRel: String, _ pics: [(Int, String)]) -> [UInt8] {
        let lo = d.layoutId.isEmpty ? layoutID(d.kind) : d.layoutId
        var w = W.new()
        w.open("dgm:dataModel", A().a("xmlns:dgm", nsDGM).a("xmlns:a", OPC.nsA).a("xmlns:r", OPC.nsR))
        w.open0("dgm:ptLst")
        let doc = guid(seed, 0)
        w.open("dgm:pt", A().a("modelId", doc).a("type", "doc"))
        w.empty(
            "dgm:prSet",
            A()
                .a("loTypeId", lo)
                .a("loCatId", category(d.kind))
                .a("qsTypeId", qsID(d.style))
                .a("qsCatId", "simple")
                .a("csTypeId", csID(d.colors))
                .a("csCatId", hasBytePrefix(d.colors, "accent") ? d.colors : "colorful")
                .a("phldr", "1")
        )
        w.empty0("dgm:spPr")
        text(&w, "")
        w.close("dgm:pt")
        // Node k: model id 1 + 3k; its link's parent and sibling transitions 2 + 3k and 3 + 3k.
        func node(_ k: Int) -> String { guid(seed, 1 + 3 * k) }
        for (k, n) in d.nodes.enumerated() {
            var a = A().a("modelId", node(k))
            if n.assistant { a = a.a("type", "asst") }
            w.open("dgm:pt", a)
            w.empty("dgm:prSet", A().a("phldrT", "[Text]"))
            w.empty0("dgm:spPr")
            text(&w, n.text)
            w.close("dgm:pt")
            let cxn = guid(seed, 0x10_0000 + k)
            for (i, ty) in [(2, "parTrans"), (3, "sibTrans")] {
                w.open("dgm:pt", A().a("modelId", guid(seed, i + 3 * k)).a("type", ty).a("cxnId", cxn))
                w.empty0("dgm:prSet")
                w.empty0("dgm:spPr")
                text(&w, "")
                w.close("dgm:pt")
            }
        }
        // A node's picture sits on the presentation point of its picture placeholder, as PowerPoint
        // stores it (`presAssocID` names the node, the blip is a relationship of the data part).
        // Name and Title: a node's title is the text of its title box's presentation point.
        for (k, n) in d.nodes.enumerated() where !n.title.isEmpty {
            w.open("dgm:pt", A().a("modelId", guid(seed, 0x30_0000 + k)).a("type", "pres"))
            w.empty("dgm:prSet", A().a("presAssocID", node(k)).a("presName", "titleText1").a("presStyleLbl", "fgAcc1").a("custT", "1"))
            w.empty0("dgm:spPr")
            text(&w, n.title)
            w.close("dgm:pt")
        }
        for (k, rid) in pics where k < d.nodes.count {
            w.open("dgm:pt", A().a("modelId", guid(seed, 0x20_0000 + k)).a("type", "pres"))
            w.empty("dgm:prSet", A().a("presAssocID", node(k)).a("presName", "Image").a("presStyleLbl", "fgImgPlace1"))
            w.open0("dgm:spPr")
            w.open0("a:blipFill")
            w.empty("a:blip", A().a("r:embed", rid))
            w.open0("a:stretch")
            w.empty0("a:fillRect")
            w.close("a:stretch")
            w.close("a:blipFill")
            w.close("dgm:spPr")
            w.close("dgm:pt")
        }
        w.close("dgm:ptLst")
        w.open0("dgm:cxnLst")
        var stack: [(UInt8, String)] = []
        var ords: [String: Int] = [:]
        for (k, n) in d.nodes.enumerated() {
            while let last = stack.last, last.0 >= n.level {
                stack.removeLast()
            }
            let parent = stack.last?.1 ?? doc
            let ord = ords[parent, default: 0]
            w.empty(
                "dgm:cxn",
                A()
                    .a("modelId", guid(seed, 0x10_0000 + k))
                    .a("srcId", parent)
                    .a("destId", node(k))
                    .a("srcOrd", ord)
                    .a("destOrd", 0)
                    .a("parTransId", guid(seed, 2 + 3 * k))
                    .a("sibTransId", guid(seed, 3 + 3 * k))
            )
            ords[parent] = ord + 1
            stack.append((n.level, node(k)))
        }
        w.close("dgm:cxnLst")
        w.empty0("dgm:bg")
        w.empty0("dgm:whole")
        w.open0("dgm:extLst")
        w.open("a:ext", A().a("uri", "http://schemas.microsoft.com/office/drawing/2008/diagram"))
        w.empty(
            "dsp:dataModelExt",
            A().a("xmlns:dsp", nsDSP).a("relId", drawingRel).a("minVer", "http://schemas.openxmlformats.org/drawingml/2006/diagram")
        )
        w.close("a:ext")
        w.close("dgm:extLst")
        w.close("dgm:dataModel")
        return w.finish()
    }

    /// The outline of a data part: the `parOf` tree under the document point, depth first.
    static func outline(_ data: XMLEl) -> [DiagramNode] {
        outlineIDs(data).map(\.node)
    }

    /// The relationship ids (of the data part) of node pictures, by node index in `outline`: the blip
    /// fill of a presentation point associated with the node.
    static func nodePictures(_ data: XMLEl) -> [(Int, String)] {
        var ids: [ByteKey: Int] = [:]
        for (k, (id, _)) in outlineIDs(data).enumerated() { ids[ByteKey(id)] = k }
        guard let pts = data.child("ptLst") else { return [] }
        var out: [(Int, String)] = []
        for pt in pts.childrenNamed("pt").prefix(maxNodes * 8) {
            if pt.attr("type") != "pres" { continue }
            guard let assoc = pt.child("prSet")?.attr("presAssocID"), let k = ids[ByteKey(assoc)] else { continue }
            guard let rid = pt.child("spPr")?.child("blipFill")?.child("blip")?.attr("r:embed") else { continue }
            if !out.contains(where: { $0.0 == k }) {
                out.append((k, rid))
            }
        }
        return out
    }

    private static func outlineIDs(_ data: XMLEl) -> [(id: String, node: DiagramNode)] {
        guard let pts = data.child("ptLst") else { return [] }
        var texts: [ByteKey: String] = [:]
        var assistants = Set<ByteKey>()
        var titles: [ByteKey: String] = [:]
        var doc: String?
        for pt in pts.childrenNamed("pt").prefix(maxNodes * 4) {
            guard let id = pt.attr("modelId") else { continue }
            let ty = pt.attr("type") ?? "node"
            switch ty {
            case "doc":
                if doc == nil { doc = id }
            case "node", "asst":
                texts[ByteKey(id)] = pt.child("t").map(paragraphs) ?? ""
                if ty == "asst" { assistants.insert(ByteKey(id)) }
            case "pres":
                // Name and Title: the title box's own text, on its presentation point.
                let pr = pt.child("prSet")
                if let name = pr?.attr("presName"), hasBytePrefix(name, "titleText"), let node = pr?.attr("presAssocID"),
                   let t = pt.child("t").map(paragraphs), !t.isEmpty {
                    titles[ByteKey(node)] = t
                }
            default:
                break
            }
        }
        guard let doc else { return [] }
        var kids: [ByteKey: [(Int64, String)]] = [:]
        if let cx = data.child("cxnLst") {
            for c in cx.childrenNamed("cxn").prefix(maxNodes * 4) {
                if (c.attr("type") ?? "parOf") != "parOf" { continue }
                guard let src = c.attr("srcId"), let dst = c.attr("destId") else { continue }
                if texts[ByteKey(dst)] != nil {
                    kids[ByteKey(src), default: []].append((c.i64("srcOrd") ?? 0, dst))
                }
            }
        }
        // `sort_by_key` is stable: equal orders keep their file order.
        for (key, v) in kids {
            kids[key] = v.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element)
        }
        var out: [(id: String, node: DiagramNode)] = []
        var seen = Set<ByteKey>()
        // Depth first, iteratively; a node reached twice (a cycle in a hostile file) is skipped.
        var stack: [(String, UInt8)] = (kids[ByteKey(doc)] ?? []).reversed().map { ($0.1, 0) }
        while let (id, level) = stack.popLast() {
            if out.count >= maxNodes || !seen.insert(ByteKey(id)).inserted { continue }
            out.append((
                id,
                DiagramNode(
                    text: texts[ByteKey(id)] ?? "", level: Swift.min(level, 8), picture: nil,
                    assistant: assistants.contains(ByteKey(id)), title: titles[ByteKey(id)] ?? ""
                )
            ))
            if let v = kids[ByteKey(id)] {
                let next = level == .max ? level : level + 1
                stack += v.reversed().map { ($0.1, next) }
            }
        }
        return out
    }

    /// A text body's paragraphs joined by spaces.
    private static func paragraphs(_ t: XMLEl) -> String {
        t.childrenNamed("p")
            .map { p in p.findAll("t").map(\.text).joined() }
            .filter { !rustTrim($0).isEmpty }
            .joined(separator: " ")
    }

    /// The layout algorithm and node shape of a DeckCraft layout.
    private static func alg(_ kind: String) -> (type: String, params: [(String, String)], shape: String) {
        switch kind {
        case "process", "stepUp", "pictureProcess", "pictureCaption", "pictureHList", "timeline":
            return ("lin", [("linDir", "fromL"), ("nodeVertAlign", "mid")], "roundRect")
        case "chevron":
            return ("lin", [("linDir", "fromL"), ("nodeVertAlign", "mid")], "chevron")
        case "verticalProcess":
            return ("lin", [("linDir", "fromT"), ("nodeHorzAlign", "ctr")], "roundRect")
        case "cycle", "radial", "venn", "target", "textCycle", "continuousCycle", "gear", "segmentedCycle", "multidirectionalCycle",
             "cycleMatrix", "pie":
            return ("cycle", [("stAng", "0"), ("spanAng", "360")], "ellipse")
        case "blockCycle":
            return ("cycle", [("stAng", "0"), ("spanAng", "360")], "roundRect")
        case "pyramid", "invertedPyramid", "segmentedPyramid":
            return ("pyra", [("linDir", kind == "pyramid" ? "fromT" : "fromB"), ("txDir", "fromT"), ("pyraAcctPos", "bef")], "trapezoid")
        case "matrix", "titledMatrix", "gridMatrix", "blockList":
            return (
                "snake", [("grDir", "tL"), ("flowDir", "row"), ("contDir", "sameDir"), ("off", "ctr")],
                kind == "blockList" ? "rect" : "roundRect"
            )
        case "hBulletList":
            return ("lin", [("linDir", "fromL"), ("nodeVertAlign", "t")], "roundRect")
        default:
            return ("lin", [("linDir", "fromT"), ("vertAlign", "mid")], "roundRect")
        }
    }

    private static func nodeLayout(_ w: inout W, _ shape: String, _ bullets: Bool) {
        w.open("dgm:layoutNode", A().a("name", "node"))
        w.open0("dgm:varLst")
        w.empty("dgm:bulletEnabled", A().a("val", bullets ? "1" : "0"))
        w.close("dgm:varLst")
        w.empty("dgm:alg", A().a("type", "tx"))
        w.open("dgm:shape", A().a("type", shape).a("r:blip", ""))
        w.empty0("dgm:adjLst")
        w.close("dgm:shape")
        w.empty("dgm:presOf", A().a("axis", bullets ? "desOrSelf" : "self").a("ptType", "node"))
        w.open0("dgm:constrLst")
        for side in ["tMarg", "bMarg", "lMarg", "rMarg"] {
            w.empty("dgm:constr", A().a("type", side).a("refType", "primFontSz").a("fact", "0.3"))
        }
        w.close("dgm:constrLst")
        w.open0("dgm:ruleLst")
        w.empty("dgm:rule", A().a("type", "primFontSz").a("val", "5").a("fact", "NaN").a("max", "NaN"))
        w.close("dgm:ruleLst")
        w.close("dgm:layoutNode")
    }

    private static func space(_ w: inout W) {
        w.open("dgm:forEach", A().a("name", "sibling").a("axis", "followSib").a("ptType", "sibTrans").a("cnt", "1"))
        w.open("dgm:layoutNode", A().a("name", "space"))
        w.empty("dgm:alg", A().a("type", "sp"))
        w.open("dgm:shape", A().a("r:blip", ""))
        w.empty0("dgm:adjLst")
        w.close("dgm:shape")
        w.empty0("dgm:presOf")
        w.empty0("dgm:constrLst")
        w.empty0("dgm:ruleLst")
        w.close("dgm:layoutNode")
        w.close("dgm:forEach")
    }

    /// `ppt/diagrams/layoutN.xml`: a layout definition for DeckCraft's layout `kind`, under the id of
    /// the closest built-in PowerPoint layout.
    static func layoutXML(_ kind: String) -> [UInt8] {
        var w = W.new()
        w.open(
            "dgm:layoutDef",
            A().a("xmlns:dgm", nsDGM).a("xmlns:a", OPC.nsA).a("xmlns:r", OPC.nsR).a("uniqueId", layoutID(kind))
        )
        w.empty("dgm:title", A().a("val", ""))
        w.empty("dgm:desc", A().a("val", ""))
        w.open0("dgm:catLst")
        w.empty("dgm:cat", A().a("type", category(kind)).a("pri", "1000"))
        w.close("dgm:catLst")
        w.open("dgm:layoutNode", A().a("name", "diagram"))
        w.open0("dgm:varLst")
        w.empty0("dgm:dir")
        w.empty("dgm:resizeHandles", A().a("val", "exact"))
        w.close("dgm:varLst")
        if ["hierarchy", "horizontalHierarchy", "orgChart", "halfCircleOrgChart", "nameTitleOrgChart"].contains(kind) {
            // Each node over the row of its children, recursively.
            w.empty("dgm:alg", A().a("type", "hierChild"))
            w.open("dgm:shape", A().a("r:blip", ""))
            w.empty0("dgm:adjLst")
            w.close("dgm:shape")
            w.empty0("dgm:presOf")
            w.empty0("dgm:constrLst")
            w.empty0("dgm:ruleLst")
            w.open("dgm:forEach", A().a("name", "level").a("axis", "ch").a("ptType", "node"))
            w.open("dgm:layoutNode", A().a("name", "hierRoot"))
            w.empty("dgm:alg", A().a("type", "hierRoot"))
            w.open("dgm:shape", A().a("r:blip", ""))
            w.empty0("dgm:adjLst")
            w.close("dgm:shape")
            w.empty0("dgm:presOf")
            w.empty0("dgm:constrLst")
            w.empty0("dgm:ruleLst")
            nodeLayout(&w, "roundRect", false)
            w.open("dgm:layoutNode", A().a("name", "hierChild"))
            w.empty("dgm:alg", A().a("type", "hierChild"))
            w.open("dgm:shape", A().a("r:blip", ""))
            w.empty0("dgm:adjLst")
            w.close("dgm:shape")
            w.empty0("dgm:presOf")
            w.empty0("dgm:constrLst")
            w.empty0("dgm:ruleLst")
            w.empty("dgm:forEach", A().a("name", "repeat").a("ref", "level"))
            w.close("dgm:layoutNode")
            w.close("dgm:layoutNode")
            w.close("dgm:forEach")
        } else {
            let (ty, params, shape) = alg(kind)
            w.open("dgm:alg", A().a("type", ty))
            for (k, v) in params {
                w.empty("dgm:param", A().a("type", k).a("val", v))
            }
            w.close("dgm:alg")
            w.open("dgm:shape", A().a("r:blip", ""))
            w.empty0("dgm:adjLst")
            w.close("dgm:shape")
            w.empty0("dgm:presOf")
            w.open0("dgm:constrLst")
            w.empty("dgm:constr", A().a("type", "w").a("for", "ch").a("forName", "node").a("refType", "w"))
            w.empty(
                "dgm:constr",
                A().a("type", "h").a("for", "ch").a("forName", "node").a("refType", "w").a("refFor", "ch").a("refForName", "node").a("fact", "0.6")
            )
            w.empty(
                "dgm:constr",
                A().a("type", "w").a("for", "ch").a("forName", "space").a("refType", "w").a("refFor", "ch").a("refForName", "node").a("fact", "0.1")
            )
            w.empty("dgm:constr", A().a("type", "primFontSz").a("for", "ch").a("forName", "node").a("op", "equ").a("val", "65"))
            w.close("dgm:constrLst")
            w.empty0("dgm:ruleLst")
            w.open("dgm:forEach", A().a("name", "nodes").a("axis", "ch").a("ptType", "node"))
            nodeLayout(&w, shape, true)
            if !["cycle", "blockCycle", "radial"].contains(kind) {
                space(&w)
            }
            w.close("dgm:forEach")
        }
        w.close("dgm:layoutNode")
        w.close("dgm:layoutDef")
        return w.finish()
    }

    /// The top bevel (preset, width in EMU) of a 3-D SmartArt Style.
    private static func bevel(_ style: String) -> (String, Int64)? {
        switch style {
        case "polished": ("circle", 76200)
        case "inset": ("relaxedInset", 63500)
        case "cartoon": ("softRound", 50800)
        case "powder": ("convex", 101_600)
        case "brick": ("slope", 50800)
        default: nil
        }
    }

    /// `ppt/diagrams/quickStyleN.xml`: flat shapes drawn from the theme's first styles.
    static func styleXML(_ style: String) -> [UInt8] {
        // Brick Scene looks at the diagram from above and to the side.
        let camera = style == "brick" ? "isometricOffAxis2Top" : "orthographicFront"
        var w = W.new()
        w.open("dgm:styleDef", A().a("xmlns:dgm", nsDGM).a("xmlns:a", OPC.nsA).a("uniqueId", qsID(style)))
        w.empty("dgm:title", A().a("val", ""))
        w.empty("dgm:desc", A().a("val", ""))
        w.open0("dgm:catLst")
        w.empty("dgm:cat", A().a("type", bevel(style) != nil ? "3D" : "simple").a("pri", "10100"))
        w.close("dgm:catLst")
        w.open0("dgm:scene3d")
        w.empty("a:camera", A().a("prst", camera))
        w.empty("a:lightRig", A().a("rig", "threePt").a("dir", "t"))
        w.close("dgm:scene3d")
        w.open("dgm:styleLbl", A().a("name", "node1"))
        w.open0("dgm:scene3d")
        w.empty("a:camera", A().a("prst", camera))
        w.empty("a:lightRig", A().a("rig", "threePt").a("dir", "t"))
        w.close("dgm:scene3d")
        if let (prst, wEMU) = bevel(style) {
            w.open0("dgm:sp3d")
            w.empty("a:bevelT", A().a("w", wEMU.rustDisplay).a("h", (wEMU * 3 / 5).rustDisplay).a("prst", prst))
            w.close("dgm:sp3d")
        } else {
            w.empty0("dgm:sp3d")
        }
        w.empty("dgm:txPr", A())
        w.open0("dgm:style")
        for (tag, idx) in [("a:lnRef", "2"), ("a:fillRef", "1"), ("a:effectRef", "0")] {
            w.open(tag, A().a("idx", idx))
            w.empty("a:scrgbClr", A().a("r", "0").a("g", "0").a("b", "0"))
            w.close(tag)
        }
        w.open("a:fontRef", A().a("idx", "minor"))
        w.empty("a:schemeClr", A().a("val", "lt1"))
        w.close("a:fontRef")
        w.close("dgm:style")
        w.close("dgm:styleLbl")
        w.close("dgm:styleDef")
        return w.finish()
    }

    /// `ppt/diagrams/colorsN.xml`: accent 1 fills with light text.
    static func colorsXML(_ colors: String) -> [UInt8] {
        var w = W.new()
        w.open("dgm:colorsDef", A().a("xmlns:dgm", nsDGM).a("xmlns:a", OPC.nsA).a("uniqueId", csID(colors)))
        w.empty("dgm:title", A().a("val", ""))
        w.empty("dgm:desc", A().a("val", ""))
        let accents = fillAccents(colors)
        let single = accents.count == 1
        let cat = single ? (accents.first ?? "accent1") : "colorful"
        w.open0("dgm:catLst")
        w.empty("dgm:cat", A().a("type", cat).a("pri", "11200"))
        w.close("dgm:catLst")
        w.open("dgm:styleLbl", A().a("name", "node1"))
        if hasByteSuffix(colors, "Grad") {
            // Gradient Range: the accent shaded darker across the shapes.
            w.open("dgm:fillClrLst", A().a("meth", "repeat"))
            for k in 0 ..< 4 {
                w.open("a:schemeClr", A().a("val", cat))
                w.empty("a:lumMod", A().a("val", (100_000 - k * 15_000).rustDisplay))
                w.close("a:schemeClr")
            }
            w.close("dgm:fillClrLst")
        } else {
            w.open("dgm:fillClrLst", A().a("meth", "repeat"))
            for a in accents {
                w.empty("a:schemeClr", A().a("val", a))
            }
            w.close("dgm:fillClrLst")
        }
        w.open("dgm:linClrLst", A().a("meth", "repeat"))
        w.empty("a:schemeClr", A().a("val", "lt1"))
        w.close("dgm:linClrLst")
        w.empty0("dgm:effectClrLst")
        w.empty0("dgm:txLinClrLst")
        w.empty0("dgm:txFillClrLst")
        w.empty0("dgm:txEffectClrLst")
        w.close("dgm:styleLbl")
        w.close("dgm:colorsDef")
        return w.finish()
    }
}

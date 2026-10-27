// The tests of deckcraft crates/pptx/src/maps.rs, custgeom.rs, tables.rs and dgm.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCGeometry
import DCModel
@testable import DCPPTX
import Testing

@Suite struct MapsTests {
    /// #147: these exits, with their directions, fell back to a plain fade (PowerPoint's ids).
    @Test func exitPresetsImportAsTheirOwnEffects() throws {
        let cases: [(UInt32, UInt32, String, String)] = [
            (3, 10, "blindsOut", "horz"),
            (4, 32, "boxOut", "out"),
            (5, 5, "checkerboardOut", "down"),
            (8, 16, "diamondOut", "in"),
            (12, 4, "peekOut", "b"),
            (18, 6, "stripsOut", "rd"),
            (37, 0, "sinkDown", ""),
            (49, 0, "spinnerOut", ""),
            (55, 0, "contract", ""),
        ]
        for (preset, sub, effect, option) in cases {
            let e = try #require(Maps.effectForPreset(.exit, preset), "known exit \(preset)")
            #expect(e == effect, "preset \(preset)")
            #expect(Maps.optionFromSubtype(e, sub) == option, "preset \(preset)")
        }
    }

    @Test func everyTransitionKindRoundTrips() throws {
        for t in transitions where t.id != "none" {
            let opts = t.options.isEmpty ? [""] : t.options
            for o in opts {
                var w = W.frag()
                let ns = try #require(Maps.transitionToXML(&w, t.id, o), "no xml for \(t.id)")
                #expect(!ns.isEmpty)
                let d = try parseXML(w.s)
                let (k, opt) = try #require(Maps.transitionFromXML(d.root), "no read for \(t.id)")
                #expect(k == t.id, "kind for \(t.id)/\(o)")
                if !o.isEmpty {
                    #expect(opt == o, "option for \(t.id)")
                }
            }
        }
    }

    @Test func subtypes() {
        #expect(Maps.subtypeFromOption("fly", "b") == 4)
        #expect(Maps.optionFromSubtype("fly", 8) == "l")
        #expect(Maps.optionFromSubtype("fade", 0) == "")
        #expect(Maps.effectForPreset(.entrance, 2) == "fly")
        #expect(Maps.effectForPreset(.emphasis, 8) == "spin")
    }
}

@Suite struct CustGeomTests {
    @Test func formulas() {
        var g = Guides(1000.0, 500.0)
        #expect(g.eval("*/ w 1 2") == 500.0)
        #expect(g.eval("+- w h 100") == 1400.0)
        #expect(g.eval("+/ w h 3") == 500.0)
        #expect(g.eval("?: -1 5 7") == 7.0)
        #expect(g.eval("?: 1 5 7") == 5.0)
        #expect(g.eval("abs -42") == 42.0)
        #expect(g.eval("max 3 9") == 9.0)
        #expect(g.eval("min 3 9") == 3.0)
        #expect(g.eval("mod 3 4 0") == 5.0)
        #expect(g.eval("pin 0 150 100") == 100.0)
        #expect(g.eval("pin 0 -5 100") == 0.0)
        #expect(g.eval("sqrt 16") == 4.0)
        #expect(g.eval("val ss") == 500.0)
        #expect(abs(g.eval("at2 1 1") - 2_700_000.0) < 1e-6)
        #expect(abs(g.eval("cos 100 5400000")) < 1e-9)
        #expect(abs(g.eval("sin 100 5400000") - 100.0) < 1e-9)
        #expect(abs(g.eval("tan 100 2700000") - 100.0) < 1e-6)
        #expect(abs(g.eval("cat2 10 1 0") - 10.0) < 1e-9)
        #expect(abs(g.eval("sat2 10 0 1") - 10.0) < 1e-9)
        #expect(g.eval("*/ 1 1 0") == 0.0, "division by zero is 0")
        #expect(g.eval("bogus 1 2") == 0.0)
        #expect(g.eval("") == 0.0)
        g.set("x1", 7.0)
        #expect(g.eval("+- x1 0 2") == 5.0)
        #expect(g.get("hc") == 500.0)
        #expect(g.get("cd4") == 5_400_000.0)
    }

    @Test func custgeomWithGuidesAndArc() throws {
        let x = """
            <a:custGeom xmlns:a="x"><a:avLst/><a:gdLst><a:gd name="mid" fmla="*/ w 1 2"/></a:gdLst>
                <a:pathLst><a:path w="200" h="100"><a:moveTo><a:pt x="0" y="0"/></a:moveTo><a:lnTo><a:pt x="mid" y="h"/></a:lnTo>
                <a:arcTo wR="50" hR="50" stAng="0" swAng="5400000"/><a:close/></a:path>
                <a:path w="10" h="10" fill="none" stroke="0"><a:moveTo><a:pt x="1" y="1"/></a:moveTo><a:quadBezTo><a:pt x="2" y="2"/><a:pt x="3" y="1"/></a:quadBezTo></a:path></a:pathLst></a:custGeom>
            """
        let d = try parseXML(x)
        let paths = CustGeom.readCustGeom(d.root, 1000.0, 1000.0)
        try #require(paths.count == 2)
        #expect(paths[0].d.hasPrefix("M 0 0 L 100 100 C"), "\(paths[0].d)")
        #expect(paths[0].d.hasSuffix("Z"))
        // The quarter arc from (100,100) with centre (50,100) ends at (50,150).
        #expect(paths[0].d.contains("50 150"), "\(paths[0].d)")
        #expect(paths[1].fill == FillMode.none)
        #expect(!paths[1].stroke)
        #expect(paths[1].d == "M 1 1 Q 2 2 3 1")
    }

    @Test func writeThenReadPath() throws {
        let p = CustomPath(w: 100.0, h: 50.0, d: "M 0 0 L 100 0 C 100 10 90 50 50 50 Q 0 50 0 0 Z", fill: .norm, stroke: true)
        var w = W.frag()
        CustGeom.writeCustGeom(&w, [p])
        let d = try parseXML(w.s)
        let back = CustGeom.readCustGeom(d.root, 1.0, 1.0)
        try #require(back.count == 1)
        // Scaled by 1000 (100 → 100000).
        #expect(back[0].w == 100_000.0)
        #expect(back[0].d == "M 0 0 L 100000 0 C 100000 10000 90000 50000 50000 50000 Q 0 50000 0 0 Z")
    }

    @Test func parsePathTokens() {
        let v = CustGeom.parsePath("M0,0 L10-5 Z")
        #expect(v.count == 3)
        #expect(v.count > 1 && v[1].0 == "L" && v[1].1 == [10.0, -5.0])
        #expect(CustGeom.parsePath("garbage ### C 1").isEmpty || CustGeom.parsePath("garbage").isEmpty)
    }
}

@Suite struct TablesTests {
    @Test func stylePartsFollowSchemaOrder() throws {
        let order = [
            "tblBg", "wholeTbl", "band1H", "band2H", "band1V", "band2V", "lastCol", "firstCol", "lastRow", "seCell", "swCell", "firstRow",
            "neCell", "nwCell",
        ]
        let used = tableStyles().map(\.id)
        let d = try XML.parse(Tables.tableStylesXML(used, []))
        var n = 0
        for st in d.root.childrenNamed("tblStyle") {
            n += 1
            let pos = st.elements.map { e in order.firstIndex { $0 == e.local } ?? -1 }
            #expect(!pos.contains(-1))
            #expect(zip(pos, pos.dropFirst()).allSatisfy { $0 < $1 }, "\(st.attr("styleName") ?? ""): \(pos)")
        }
        #expect(n > 30)
    }

    @Test func guidsRoundTrip() {
        for (id, _) in tableStyles() {
            let (g, _) = Tables.guidForStyle(id)
            #expect(Tables.styleFromGUID(g) == id, "\(id) via \(g)")
            #expect(g.count == 38)
        }
        #expect(Tables.styleFromGUID("{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}") == "medium2-accent1")
        #expect(Tables.styleFromGUID("{ABCDEF00-0000-0000-0000-000000000000}") == "{ABCDEF00-0000-0000-0000-000000000000}")
    }
}

@Suite struct DgmTests {
    static func nodes(_ v: [(String, UInt8)]) -> [DiagramNode] {
        v.map { DiagramNode(text: $0.0, level: $0.1, picture: nil, assistant: false, title: "") }
    }

    @Test func outlineSurvivesTheDataModel() throws {
        let d = Diagram(kind: "hierarchy", nodes: Self.nodes([("CEO", 0), ("CTO", 1), ("Dev", 2), ("CFO", 1), ("Board", 0)]))
        let xml = Dgm.dataXML(d, 7, "rId9", [])
        let doc = try XML.parse(xml)
        #expect(Dgm.outline(doc.root) == d.nodes)
        let s = String(decoding: xml, as: UTF8.self)
        #expect(s.contains("hierarchy1") && s.contains("relId=\"rId9\""))
        for x in [
            Dgm.layoutXML("hierarchy"), Dgm.layoutXML("cycle"), Dgm.styleXML("subtle"), Dgm.colorsXML(""), Dgm.colorsXML("accent3"),
            Dgm.styleXML("polished"), Dgm.colorsXML("range23"), Dgm.colorsXML("accent6Grad"), Dgm.layoutXML("pictureList"),
        ] {
            #expect((try? XML.parse(x)) != nil)
        }
    }

    @Test func assistantsSurviveTheDataModel() throws {
        var v = Self.nodes([("CEO", 0), ("Aide", 1), ("CTO", 1)])
        v[1].assistant = true
        v[0].title = "Chief Executive"
        let d = Diagram(kind: "orgChart", nodes: v)
        let xml = Dgm.dataXML(d, 5, "rId1", [])
        #expect(String(decoding: xml, as: UTF8.self).contains("type=\"asst\""))
        let doc = try XML.parse(xml)
        #expect(Dgm.outline(doc.root) == d.nodes)
    }

    @Test func nodePicturesComeFromPresentationPoints() throws {
        let d = Diagram(kind: "pictureList", nodes: Self.nodes([("A", 0), ("a", 1), ("B", 0)]))
        let xml = Dgm.dataXML(d, 3, "rId1", [(2, "rId7"), (9, "rId8")])
        let doc = try XML.parse(xml)
        let pics = Dgm.nodePictures(doc.root)
        #expect(pics.count == 1 && pics.first?.0 == 2 && pics.first?.1 == "rId7")
    }

    @Test func styleAndColourIDsRoundTrip() {
        for st in ["", "subtle", "intense", "outline", "polished", "inset", "cartoon", "powder", "brick"] {
            #expect(Dgm.styleFor(Dgm.qsID(st)) == st)
        }
        for c in ["", "range23", "range56", "accent1", "accent4Grad"] {
            #expect(Dgm.colorsFor(Dgm.csID(c)) == c)
        }
        #expect(String(decoding: Dgm.styleXML("cartoon"), as: UTF8.self).contains("bevelT"))
        #expect(Dgm.layoutID("pictureProcess").hasSuffix("/hProcess10"), "Picture Accent Process")
        #expect(Dgm.layoutID("pictureHList").hasSuffix("/pList2"), "Horizontal Picture List")
        // Picture Accent Process as an earlier DeckCraft wrote it (pList2, process category).
        #expect(Dgm.kindFor("urn:microsoft.com/office/officeart/2005/8/layout/pList2", "process") == "pictureProcess")
        #expect(Dgm.kindFor("urn:microsoft.com/office/officeart/2005/8/layout/pList2", "list") == "pictureHList")
        for k in [
            "pictureList", "pictureCaption", "pictureProcess", "pictureHList", "timeline", "venn", "target", "textCycle",
            "continuousCycle", "horizontalHierarchy", "gridMatrix", "gear", "funnel", "segmentedCycle", "multidirectionalCycle",
            "orgChart", "halfCircleOrgChart", "cycleMatrix", "segmentedPyramid", "pie", "nameTitleOrgChart", "verticalBoxList",
            "trapezoidList", "tableList", "accentProcess", "continuousBlockProcess", "bendingProcess", "linearVenn", "stackedVenn",
            "nestedTarget",
        ] {
            #expect(Dgm.kindFor(Dgm.layoutID(k), "") == k)
        }
    }

    @Test func hostileLinksAreBounded() throws {
        let xml = #"<dgm:dataModel xmlns:dgm="d"><dgm:ptLst><dgm:pt modelId="0" type="doc"/><dgm:pt modelId="1"><dgm:t><a:p xmlns:a="a"><a:r><a:t>A</a:t></a:r></a:p></dgm:t></dgm:pt><dgm:pt modelId="2"/></dgm:ptLst><dgm:cxnLst><dgm:cxn srcId="0" destId="1"/><dgm:cxn srcId="1" destId="2"/><dgm:cxn srcId="2" destId="1"/><dgm:cxn type="presOf" srcId="0" destId="2"/></dgm:cxnLst></dgm:dataModel>"#
        let doc = try parseXML(xml)
        #expect(Dgm.outline(doc.root) == Self.nodes([("A", 0), ("", 1)]))
        #expect(Dgm.kindFor("urn:microsoft.com/office/officeart/2005/8/layout/orgChart1", "") == "orgChart")
        #expect(Dgm.kindFor("urn:x/layout/NameandTitleOrganizationalChart", "") == "nameTitleOrgChart")
        #expect(Dgm.kindFor("urn:x/layout/chevron2", "process") == "chevron")
        #expect(Dgm.kindFor("urn:x/layout/hProcess9", "process") == "process")
        #expect(Dgm.kindFor("urn:x/layout/default", "list") == "blockList")
        #expect(Dgm.colorsFor(Dgm.csID("accent4")) == "accent4")
        #expect(Dgm.colorsFor(Dgm.csID("")) == "")
        #expect(Dgm.styleFor(Dgm.qsID("outline")) == "outline")
    }
}

// DCPPT — a slide's drawing ([MS-PPT] 2.5.13 DrawingContainer; [MS-ODRAW] 2.2): an OfficeArtDgContainer whose group
// container holds the shapes in z-order. A group's first shape is the group itself: its OfficeArtFSPGR gives the
// coordinate space its children's OfficeArtChildAnchors use, and its own anchor places that space in its parent's.
// Top-level shapes are placed by an OfficeArtClientAnchor in master units (1/576 inch). Each shape's OfficeArtFSP
// gives its id, its shape type (recInstance) and flags; its OfficeArtFOPT and OfficeArtTertiaryFOPT its properties
// (with their complex data after them); its OfficeArtClientData can hold a PlaceholderAtom and an InteractiveInfo, and
// its OfficeArtClientTextbox the text records (or an OutlineTextRefAtom into the slide list's text). The drawing's
// OfficeArtSolverContainer holds the connector rules.
//
// `tree` keeps groups as groups, each child's box in its group's coordinate space (P3); `shapes` flattens them into
// slide coordinates (notes pages, which need only their placeholders). Groups nest no deeper than `maxDepth`.
struct DrawnShape {
    var id: UInt32
    /// The MSOSPT shape type ([MS-ODRAW] 2.4.24): 1 rectangle, 202 text box…
    var type: UInt16
    var flags: UInt32
    /// Left, top, width, height in master units, in slide coordinates.
    var rect: (x: Double, y: Double, w: Double, h: Double)?
    /// The PlaceholderAtom: its type ([MS-PPT] 2.13.25 PlaceholderEnum) and position.
    var placeholder: (type: UInt8, position: Int32)?
    /// The client textbox's records.
    var textbox: [Record] = []
    /// The OfficeArtFOPT's and OfficeArtTertiaryFOPT's properties ([MS-ODRAW] 2.3): property id → value. A complex
    /// property's value is its data's length; the data is in `complex`.
    var props: [UInt16: UInt32] = [:]
    /// Each complex property's data, as a range of the drawing's bytes.
    var complex: [UInt16: Range<Int>] = [:]
    /// The OfficeArtClientData's records (PlaceholderAtom, InteractiveInfoContainer…).
    var clientData: [Record] = []
    /// A group's shapes, in z-order (`tree` only).
    var children: [DrawnShape] = []
    /// A group's coordinate space (its OfficeArtFSPGR), which its children's boxes use.
    var space: (x: Double, y: Double, w: Double, h: Double)?

    var isGroup: Bool { flags & 0x1 != 0 }
    var isDeleted: Bool { flags & 0x8 != 0 }
    var flipH: Bool { flags & 0x40 != 0 }
    var flipV: Bool { flags & 0x80 != 0 }
    var isConnector: Bool { flags & 0x100 != 0 }
    var isBackground: Bool { flags & 0x400 != 0 }
    var isOLE: Bool { flags & 0x10 != 0 }
}

/// An OfficeArtFConnectorRule ([MS-ODRAW] 2.2.36): connector `connector` joins shape `start` (at its connection site
/// `startSite`) to shape `end`.
struct ConnectorRule {
    var start: UInt32, end: UInt32, connector: UInt32
    var startSite: UInt32, endSite: UInt32
}

enum Drawing {
    static let maxDepth = 64

    /// The shapes of a slide, notes page or master container (its DrawingContainer), flattened in z-order.
    static func shapes(_ b: [UInt8], _ container: Record) -> [DrawnShape] {
        guard let drawing = container.children(b).first(where: { $0.type == RT.drawing }),
              let dg = drawing.children(b).first(where: { $0.type == RT.dgContainer }),
              let root = dg.children(b).first(where: { $0.type == RT.spgrContainer })
        else { return [] }
        var out: [DrawnShape] = []
        walk(b, root, transform: nil, depth: 0, into: &out)
        return out
    }

    /// The shapes of a slide's drawing in z-order, groups kept as groups, and its connector rules.
    static func tree(_ b: [UInt8], _ container: Record) -> (shapes: [DrawnShape], rules: [ConnectorRule]) {
        guard let drawing = container.children(b).first(where: { $0.type == RT.drawing }),
              let dg = drawing.children(b).first(where: { $0.type == RT.dgContainer })
        else { return ([], []) }
        let kids = dg.children(b)
        var rules: [ConnectorRule] = []
        if let solver = kids.first(where: { $0.type == RT.solverContainer }) {
            for r in solver.children(b) where r.type == RT.connectorRule && r.body.count >= 24 {
                let p = r.body.lowerBound
                rules.append(ConnectorRule(start: le32(b, p + 4), end: le32(b, p + 8), connector: le32(b, p + 12),
                                           startSite: le32(b, p + 16), endSite: le32(b, p + 20)))
            }
        }
        guard let root = kids.first(where: { $0.type == RT.spgrContainer }) else { return ([], rules) }
        return (members(b, root, depth: 0), rules)
    }

    /// A group container's shapes after its first (the group's own shape; at the top, the patriarch). Top-level shapes
    /// keep their client anchors; deeper ones their child anchors, untransformed.
    static func members(_ b: [UInt8], _ group: Record, depth: Int) -> [DrawnShape] {
        guard depth < maxDepth else { return [] }
        var out: [DrawnShape] = []
        for c in group.children(b).dropFirst() {
            switch c.type {
            case RT.spContainer:
                let s = shape(b, c, transform: depth == 0 ? nil : Transform())
                if !s.isDeleted { out.append(s) }
            case RT.spgrContainer:
                guard depth + 1 < maxDepth, let first = c.children(b).first, first.type == RT.spContainer else { continue }
                var g = shape(b, first, transform: depth == 0 ? nil : Transform())
                guard !g.isDeleted else { continue }
                g.space = groupSpace(b, first)
                g.children = members(b, c, depth: depth + 1)
                out.append(g)
            default: continue
            }
        }
        return out
    }

    /// The drawing group's default properties (the OfficeArtDggContainer's options in the document's
    /// PPDrawingGroup): what a shape that doesn't set a property takes, such as PowerPoint's default fill and line.
    static func defaults(_ b: [UInt8], _ document: [Record]) -> [UInt16: UInt32] {
        guard let group = document.first(where: { $0.type == RT.drawingGroup }),
              let dgg = group.children(b).first(where: { $0.type == RT.dggContainer })
        else { return [:] }
        return shape(b, dgg, transform: nil).props
    }

    /// The drawing's background shape (an OfficeArtSpContainer directly in the OfficeArtDgContainer, fBackground).
    static func background(_ b: [UInt8], _ container: Record) -> DrawnShape? {
        guard let drawing = container.children(b).first(where: { $0.type == RT.drawing }),
              let dg = drawing.children(b).first(where: { $0.type == RT.dgContainer })
        else { return nil }
        for c in dg.children(b) where c.type == RT.spContainer {
            let s = shape(b, c, transform: nil)
            if s.flags & 0x400 != 0 { return s }
        }
        return nil
    }

    /// A child anchor's coordinates in slide coordinates: x' = x * sx + tx.
    struct Transform {
        var sx = 1.0, sy = 1.0, tx = 0.0, ty = 0.0
        func apply(_ r: (x: Double, y: Double, w: Double, h: Double)) -> (x: Double, y: Double, w: Double, h: Double) {
            (r.x * sx + tx, r.y * sy + ty, r.w * sx, r.h * sy)
        }
    }

    /// The shapes in a group container. `transform` maps child anchors to slide coordinates; nil for the top level,
    /// whose shapes use client anchors.
    static func walk(_ b: [UInt8], _ group: Record, transform: Transform?, depth: Int, into out: inout [DrawnShape]) {
        guard depth < maxDepth else { return }
        let children = group.children(b)
        guard let first = children.first else { return }
        // The group's own shape: its coordinate space for the shapes after it.
        var inner = transform
        if depth > 0, first.type == RT.spContainer {
            let g = shape(b, first, transform: transform)
            if let space = groupSpace(b, first), let placed = g.rect, space.w != 0, space.h != 0 {
                let sx = placed.w / space.w, sy = placed.h / space.h
                inner = Transform(sx: sx, sy: sy, tx: placed.x - space.x * sx, ty: placed.y - space.y * sy)
            }
        }
        for c in children.dropFirst() {
            switch c.type {
            case RT.spContainer:
                let s = shape(b, c, transform: depth == 0 ? nil : inner)
                if !s.isDeleted { out.append(s) }
            case RT.spgrContainer:
                walk(b, c, transform: depth == 0 ? nil : inner, depth: depth + 1, into: &out)
            default: continue
            }
        }
    }

    /// The complex properties whose data is an IMsoArray ([MS-ODRAW] 2.2.51): vertices, segments, connection sites
    /// and their directions, adjust handles, guides, text rectangles, shade colours, dash styles, the wrap polygon and
    /// table rows.
    static let arrays: Set<UInt16> = [0x0145, 0x0146, 0x0151, 0x0152, 0x0155, 0x0156, 0x0157, 0x0197, 0x01CF, 0x0383, 0x03A0]

    /// The OfficeArtFSPGR rectangle of a group's shape container.
    static func groupSpace(_ b: [UInt8], _ sp: Record) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let r = sp.children(b).first(where: { $0.type == RT.fspgr }), r.body.count >= 16 else { return nil }
        let p = r.body.lowerBound
        let l = Double(i32(b, p)), t = Double(i32(b, p + 4)), rr = Double(i32(b, p + 8)), bb = Double(i32(b, p + 12))
        return (l, t, rr - l, bb - t)
    }

    /// One shape container.
    static func shape(_ b: [UInt8], _ sp: Record, transform: Transform?) -> DrawnShape {
        var s = DrawnShape(id: 0, type: 0, flags: 0)
        for r in sp.children(b) {
            let p = r.body.lowerBound
            switch r.type {
            case RT.fsp where r.body.count >= 8:
                s.id = le32(b, p)
                s.flags = le32(b, p + 4)
                s.type = r.instance
            case RT.clientAnchor where transform == nil:
                // SmallRectStruct (8 bytes) or RectStruct (16): top, left, right, bottom.
                if r.body.count >= 16 {
                    let t = Double(i32(b, p)), l = Double(i32(b, p + 4)), rr = Double(i32(b, p + 8)), bb = Double(i32(b, p + 12))
                    s.rect = (l, t, rr - l, bb - t)
                } else if r.body.count >= 8 {
                    let t = Double(Int16(bitPattern: le16(b, p))), l = Double(Int16(bitPattern: le16(b, p + 2)))
                    let rr = Double(Int16(bitPattern: le16(b, p + 4))), bb = Double(Int16(bitPattern: le16(b, p + 6)))
                    s.rect = (l, t, rr - l, bb - t)
                }
            case RT.childAnchor where r.body.count >= 16:
                // xLeft, yTop, xRight, yBottom in the group's coordinate space.
                let l = Double(i32(b, p)), t = Double(i32(b, p + 4)), rr = Double(i32(b, p + 8)), bb = Double(i32(b, p + 12))
                s.rect = (transform ?? Transform()).apply((l, t, rr - l, bb - t))
            case RT.clientData:
                s.clientData = r.children(b)
                if let ph = r.children(b).first(where: { $0.type == RT.placeholderAtom }), ph.body.count >= 6 {
                    s.placeholder = (b[ph.body.lowerBound + 4], i32(b, ph.body.lowerBound))
                }
            case RT.clientTextbox:
                s.textbox = r.children(b)
            case RT.fopt, RT.tertiaryFopt:
                // OfficeArtFOPTE entries: a 14-bit property id with fBid and fComplex flags, then a 32-bit value; then
                // the complex properties' data, in their entries' order, each as long as its value says.
                var q = p
                var complex: [(UInt16, Int)] = []
                for _ in 0 ..< Int(r.instance) {
                    guard q + 6 <= r.body.upperBound else { break }
                    let id = le16(b, q), value = le32(b, q + 2)
                    s.props[id & 0x3FFF] = value
                    if id & 0x8000 != 0 { complex.append((id & 0x3FFF, Int(value))) }
                    q += 6
                }
                for (id, n) in complex {
                    var n = n
                    // An IMsoArray's length should count its 6-byte header; LibreOffice leaves it out.
                    if arrays.contains(id), q + 6 <= r.body.upperBound {
                        let count = Int(le16(b, q)), size = Int(le16(b, q + 4))
                        if n == count * (size == 0xFFF0 ? 4 : size), n + 6 <= r.body.upperBound - q { n += 6 }
                    }
                    guard n >= 0, n <= r.body.upperBound - q else { break }
                    s.complex[id] = q ..< q + n
                    q += n
                }
            default: continue
            }
        }
        return s
    }
}

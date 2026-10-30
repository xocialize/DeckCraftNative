// DCPPT — a slide's drawing ([MS-PPT] 2.5.13 DrawingContainer; [MS-ODRAW] 2.2): an OfficeArtDgContainer whose group
// container holds the shapes in z-order. A group's first shape is the group itself: its OfficeArtFSPGR gives the
// coordinate space its children's OfficeArtChildAnchors use, and its own anchor places that space in its parent's.
// Top-level shapes are placed by an OfficeArtClientAnchor in master units (1/576 inch). Each shape's OfficeArtFSP
// gives its id, its shape type (recInstance) and flags; its OfficeArtClientData can hold a PlaceholderAtom, and its
// OfficeArtClientTextbox the text records (or an OutlineTextRefAtom into the slide list's text).
//
// P2a reads the shapes that carry text, flattening groups into slide coordinates; P3 brings the rest. Groups nest no
// deeper than `maxDepth`.
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

    var isGroup: Bool { flags & 0x1 != 0 }
    var isDeleted: Bool { flags & 0x8 != 0 }
    var flipH: Bool { flags & 0x40 != 0 }
    var flipV: Bool { flags & 0x80 != 0 }
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
                if let ph = r.children(b).first(where: { $0.type == RT.placeholderAtom }), ph.body.count >= 6 {
                    s.placeholder = (b[ph.body.lowerBound + 4], i32(b, ph.body.lowerBound))
                }
            case RT.clientTextbox:
                s.textbox = r.children(b)
            default: continue
            }
        }
        return s
    }
}

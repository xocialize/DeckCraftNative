// DCEngine — pointer tools: the tool state the Session holds, and the pieces of tools.rs the rest of the
// engine calls. Port of the data types and helpers of deckcraft crates/engine/src/tools.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// The gesture handling itself (`Session::pointer`, hit testing, drags, snapping; about 1,900 lines) is
// not ported in Wave 4's core: no command module or script needs it, and it belongs with the app's canvas
// (Wave 5). `Drag` is here so the state and Escape/Enter handling in `keys.rs` keep their shape.
import DCColor
import DCCore
import DCGeometry
import DCModel

public enum PointerKind: String, Sendable, Equatable, JSONStringEnum {
    case down
    case drag
    case up
    case move
    case doubleClick
    case tripleClick
    /// Secondary-button press (right click), before the context menu opens.
    case contextClick

    public static let `default` = PointerKind.down
}

public struct Mods: Sendable, Equatable {
    public var shift = false
    public var alt = false
    public var cmd = false
    public init(shift: Bool = false, alt: Bool = false, cmd: Bool = false) {
        self.shift = shift
        self.alt = alt
        self.cmd = cmd
    }
}

public struct PointerEvent: Sendable, Equatable {
    public var kind: PointerKind = .down
    public var x = 0.0
    public var y = 0.0
    public var mods = Mods()
    /// Hit tolerance in points (≈ 4 screen px at the current zoom).
    public var tol = 0.0
    /// Pen pressure `0...1` when the device reported one; nil is a mouse.
    public var pressure: Float?
    public init() {}
}

public enum ToolKind: Sendable, Equatable {
    case select
    /// Draw a preset shape.
    case shape(preset: String)
    case textBox
    /// Ink: pen (`pen`, `highlighter`) or `eraser`.
    case ink(mode: String, color: Rgba, width: Double)

    public static let `default` = ToolKind.select
}

/// What a point hits.
public enum Hit: Sendable, Equatable {
    /// Resize handle 0..8: NW, N, NE, E, SE, S, SW, W.
    case resize(id: ShapeId, handle: UInt8)
    case rotate(id: ShapeId)
    case adjust(id: ShapeId, index: Int)
    /// A control handle (`out`: the outgoing one) of the selected vertex in Edit Points.
    case handle(id: ShapeId, path: Int, index: Int, out: Bool)
    /// A vertex of a shape whose points are being edited.
    case vertex(id: ShapeId, path: Int, index: Int)
    /// WordArt warp adjust (yellow handle).
    case warp(id: ShapeId, index: Int)
    /// Line end 0/1 of a line-like shape.
    case lineEnd(id: ShapeId, end: UInt8)
    case shape(id: ShapeId, text: Bool)
    /// The frame of the box whose text is being edited.
    case frame(id: ShapeId)
    /// The right edge of table column `col`.
    case tableColumn(id: ShapeId, col: Int)
    /// The bottom edge of table row `row`.
    case tableRow(id: ShapeId, row: Int)
}

/// A text selection's shape, table cell, notes flag, anchor and caret.
typealias TextTarget = (ShapeId, TextPoint?, Bool, TextPoint, TextPoint)

/// A pointer drag in progress.
enum Drag {
    case move(ids: [ShapeId], start: Point, origs: [(ShapeId, Xfrm)], moved: Bool, duplicate: Bool, enterText: (ShapeId, Point)?)
    case resize(id: ShapeId, handle: UInt8, orig: Xfrm, start: Point)
    case lineEnd(id: ShapeId, end: UInt8, orig: Xfrm)
    case rotate(ids: [ShapeId], center: Point, start: Double, origs: [(ShapeId, Xfrm)])
    case adjust(id: ShapeId, index: Int, orig: Xfrm)
    case vertex(id: ShapeId, path: Int, index: Int)
    case handle(id: ShapeId, path: Int, index: Int, out: Bool)
    /// WordArt: `base` is the adjust list at mouse-down (empty means the preset defaults).
    case warp(id: ShapeId, index: Int, name: String, base: [Double], orig: Xfrm)
    case marquee(start: Point, add: Bool)
    /// Dragging drawing guide `index`.
    case guide(index: Int)
    case create(start: Point)
    case textSelect(shape: ShapeId, before: TextTarget?, press: TextSel?)
    case tableBorder(id: ShapeId, column: Bool, index: Int, start: Point, size: Double, frame: Affine, moved: Bool)
    case ink(points: [(Double, Double, Float)])
    /// Freeform drawing (`freeform` polygon, `curve`, `scribble`).
    case freeform(mode: String, points: [Point], pressed: Bool)
}

/// A snapping guide line to draw (slide coordinates): vertical (x) or horizontal (y).
public struct Guide: Sendable, Equatable {
    public var vertical: Bool
    public var pos: Double
    public var from: Double
    public var to: Double
}

public struct ToolState {
    public var kind: ToolKind = .select
    /// Keep the tool after one use (double-click on a shape in the gallery: lock drawing mode).
    public var sticky = false
    var drag: Drag?
    public var marquee: Rect?
    public var preview: Xfrm?
    public var guides: [Guide] = []
    public var hover: Hit?
    public var inkPreview: [(Double, Double, Float)] = []
    /// Connection sites to show while drawing or dragging a line end, and the site the end would glue to.
    public var sites: [Point] = []
    public var glue: Point?
    /// Freeform being drawn: points so far (plus the rubber-band point), smoothed, and whether the
    /// pointer is over the start (closing the shape).
    public var pathPreview: [Point] = []
    public var pathSmooth = false
    public var pathClosing = false
    /// The shape in Edit Points: its vertices are handles instead of the box's.
    public var editPoints: ShapeId?
    /// The vertex (path, index) whose control handles show in Edit Points.
    public var editVertex: (Int, Int)?
    /// The segment (path, index of the vertex ending it) last right-clicked in Edit Points.
    public var editSegment: (Int, Int)?
    /// Where on that segment the right click was (0..1), where Add Point puts the new point.
    public var editSegmentT: Double?
    /// The point type last chosen for a vertex (shape, path, index, type): handle drags follow it.
    public var vertexKind: VertexKind?
    /// Drawing guides are shown (View › Guides): they can be dragged and shapes snap to them.
    public var guidesVisible = false
    /// The guide being dragged and where it is now (slide points); nil once dropped.
    public var guideDrag: (Int, Double)?
    /// The drawing guide under the pointer, for the cursor.
    public var guideHover: Int?
    /// Pressure from the pointer event being handled, if the device reported one.
    var pressure: Float?

    public init() {}

    public var dragging: Bool { drag != nil }

    /// The shape in Edit Points, while it is still the one selected shape.
    public func editingPoints(_ st: DocState) -> ShapeId? {
        guard let id = editPoints, st.selection.shapes == [id], st.selection.text == nil, let sh = st.shape(id) else { return nil }
        // Only a freeform has points: after Undo takes the conversion back, Edit Points is over.
        if case .custom = sh.geom { return id }
        return nil
    }

    /// A freeform path is being drawn (Enter/Escape/double-click finish it).
    public var drawingFreeform: Bool {
        if case .freeform = drag { return true }
        return false
    }
}

public enum Tools {
    /// Shape-gallery names that draw a freeform path instead of a preset.
    public static let freeformTools: [(String, String)] = [("curve", "Curve"), ("freeform", "Freeform: Shape"), ("scribble", "Freeform: Scribble")]

    /// Draw Table's pencil and eraser, as `ToolKind.shape` presets (Insert › Table › Draw Table).
    public static let drawTable = "drawTable"
    public static let tableEraser = "tableEraser"

    public static func isFreeformTool(_ name: String) -> Bool { freeformTools.contains { $0.0 == name } }

    /// The box of a line from `a` to `b`: flips say which way it runs.
    public static func lineXfrm(_ a: Point, _ b: Point, _ rot: Double) -> Xfrm {
        let r = Rect.fromPoints(a, b)
        return Xfrm(x: r.x0, y: r.y0, w: r.width, h: r.height, rot: 0, flipH: b.x < a.x, flipV: b.y < a.y)
    }
}

extension Session {
    /// Pick the pointer tool (`set_tool`): any drag, preview or marquee of the last one is dropped.
    public func setTool(_ kind: ToolKind) {
        tool.kind = kind
        tool.drag = nil
        tool.preview = nil
        tool.marquee = nil
    }

    /// Escape during an Edit Points vertex or handle drag: the drag is undone. False when there is none.
    func cancelPointDrag() -> Bool {
        switch tool.drag {
        case .vertex, .handle: break
        default: return false
        }
        tool.drag = nil
        if let st = activeDoc, let i = st.interaction, i.label == "Edit Points" {
            st.interaction = nil
            // A modifier held during the drag may have set a point type; the drag is undone, so is that.
            if i.doc !== st.docRef {
                st.docRef = i.doc
                st.selection = i.selection
                st.revision += 1
            }
            tool.vertexKind = i.vertexKind
        }
        return true
    }

    /// Finish the freeform being drawn (`closed`: join its ends) as a `shape.freeform`.
    public func finishFreeform(_ closed: Bool) throws(EngineError) -> JSON {
        guard case .freeform(let mode, let points, _) = tool.drag else { return .null }
        tool.drag = nil
        tool.pathPreview.removeAll()
        tool.pathClosing = false
        if !tool.sticky { tool.kind = .select }
        if points.count < 2 { return .null }
        let pts = JSON.array(points.map { .array([.num($0.x), .num($0.y)]) })
        return try execute("shape.freeform", ["points": pts, "closed": .bool(closed), "smooth": .bool(mode == "curve")])
    }
}

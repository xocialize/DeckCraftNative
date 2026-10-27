// DCEngineTests — what the pointer tests share: events as deckcraft's tests build them, `s.pointer(…)
// .unwrap()`, and commands with JSON parameters.
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import Testing

/// A pointer event (`PointerEvent { kind, x, y, mods, tol, pressure }`); `tol` 0 is deckcraft's
/// `..Default::default()`, which the pointer reads as 4.
func pev(_ kind: PointerKind, _ x: Double, _ y: Double, tol: Double = 3, mods: Mods = Mods(), pressure: Float? = nil) -> PointerEvent {
    var e = PointerEvent()
    e.kind = kind
    e.x = x
    e.y = y
    e.mods = mods
    e.tol = tol
    e.pressure = pressure
    return e
}

func pev(_ kind: PointerKind, _ p: Point, tol: Double = 3, mods: Mods = Mods()) -> PointerEvent {
    pev(kind, p.x, p.y, tol: tol, mods: mods)
}

/// A shape id answered by a command (`r["id"]`).
func shapeIdOf(_ r: JSON) -> ShapeId { ShapeId(r.get("id")?.asU32 ?? 0) }

extension Session {
    /// `s.pointer(ev).unwrap()`: an error is a test failure.
    @discardableResult
    func ptr(_ e: PointerEvent, sourceLocation: SourceLocation = #_sourceLocation) -> JSON {
        do {
            return try pointer(e)
        } catch {
            Issue.record("pointer \(e.kind) at (\(e.x), \(e.y)): \(error)", sourceLocation: sourceLocation)
            return .null
        }
    }

    @discardableResult
    func ptr(_ kind: PointerKind, _ x: Double, _ y: Double, tol: Double = 3, mods: Mods = Mods(), pressure: Float? = nil,
             sourceLocation: SourceLocation = #_sourceLocation) -> JSON {
        ptr(pev(kind, x, y, tol: tol, mods: mods, pressure: pressure), sourceLocation: sourceLocation)
    }

    /// `s.execute(id, &json!(…)).unwrap()` with a built value.
    @discardableResult
    func exec(_ id: String, _ params: JSON, sourceLocation: SourceLocation = #_sourceLocation) -> JSON {
        do {
            return try execute(id, params)
        } catch {
            Issue.record("\(id) \(params.display): \(error)", sourceLocation: sourceLocation)
            return .null
        }
    }

    /// Press and release at `at` without moving (tests.rs `click_at`).
    func clickAt(_ x: Double, _ y: Double, tol: Double = 3, sourceLocation: SourceLocation = #_sourceLocation) {
        ptr(.down, x, y, tol: tol, sourceLocation: sourceLocation)
        ptr(.up, x, y, tol: tol, sourceLocation: sourceLocation)
    }

    /// Press at `from`, drag through the midpoint to `to`, release; the press's answer (tests.rs
    /// `drag_gesture`).
    @discardableResult
    func dragGesture(_ from: (Double, Double), _ to: (Double, Double), sourceLocation: SourceLocation = #_sourceLocation) -> JSON {
        let down = ptr(.down, from.0, from.1, sourceLocation: sourceLocation)
        ptr(.drag, (from.0 + to.0) / 2.0, (from.1 + to.1) / 2.0, sourceLocation: sourceLocation)
        ptr(.drag, to.0, to.1, sourceLocation: sourceLocation)
        ptr(.up, to.0, to.1, sourceLocation: sourceLocation)
        return down
    }

    /// The effective box of shape `id` (tests.rs `text_box_xfrm`).
    func boxOf(_ id: ShapeId) -> Xfrm {
        guard let st = activeDoc, let sh = st.shape(id) else {
            Issue.record("no shape \(id)")
            return Xfrm()
        }
        return Cmd.xfrmOf(st.doc, st.selection, sh)
    }

    /// `shape.inspect`'s `box` of shape `id` (tests.rs `box_of`).
    func inspectBox(_ id: ShapeId) -> JSON { exec("shape.inspect", ["id": id.toJSON()]).get("box") ?? .null }
}

/// A shape's text selection as (anchor, caret) pairs.
func orderedOf(_ t: TextSel?) -> ((Int, Int), (Int, Int))? {
    guard let t else { return nil }
    let (a, b) = t.ordered
    return ((a.para, a.char), (b.para, b.char))
}

func sameRange(_ a: ((Int, Int), (Int, Int))?, _ b: ((Int, Int), (Int, Int))) -> Bool {
    guard let a else { return false }
    return a.0 == b.0 && a.1 == b.1
}

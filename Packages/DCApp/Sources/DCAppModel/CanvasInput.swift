// DCAppModel — input from the canvas into the session: keys, typing, an input method's text and pointer
// events go to the engine directly (`Session.key`, `typeText`, `pointer`), as deckcraft's `keyboard` and
// `canvas::pointer` do, and then the app refreshes and hands on the engine's UI requests as `AppModel.run`
// would. Behaviour from deckcraft `crates/ui-egui/src/lib.rs` (`keyboard`) and `canvas.rs` (`pointer`,
// `trackpad_twist`) (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCEngine
import DCGeometry
import DCModel

extension AppModel {
    /// Run canvas input against the session: failures go to the status bar, the engine's UI requests to
    /// the host, and views refresh (what `run` does for a command).
    @discardableResult
    public func input(_ body: (Session) throws(EngineError) -> JSON) -> Result<JSON, CommandError> {
        let r: Result<JSON, CommandError>
        do { r = .success(try body(session)) } catch { r = .failure(CommandError(error.description)) }
        if case .failure(let e) = r { status = e.message }
        drainRequests()
        changed()
        return r
    }

    /// A key press the canvas owns (`Session.key`).
    @discardableResult
    public func key(_ name: String, _ mods: Mods) -> Result<JSON, CommandError> {
        input { s throws(EngineError) in try s.key(name, mods) }
    }
}

public enum CanvasInput {
    /// Hit tolerance in slide points: about 4 screen points at `scale` (`tol`).
    public static func tolerance(_ scale: Double) -> Double { 4 / max(scale.isFinite ? scale : 1, 0.01) }

    /// Feed one pointer event to the active tool (`Session.pointer`, deckcraft's tools.rs).
    public static func pointer(_ s: Session, _ ev: PointerEvent) throws(EngineError) -> JSON {
        try s.pointer(ev)
    }

    /// A two-finger twist on the trackpad turns the selected shapes (`trackpad_twist`): the whole twist is
    /// one undo step. `degrees` is this event's turn (clockwise positive on the slide); `ended` closes the
    /// gesture. Returns whether the twist did anything.
    @MainActor
    public static func twist(_ app: AppModel, degrees: Double, ended: Bool, twisting: inout Bool) {
        let s = app.session
        let d = degrees.isFinite ? min(max(degrees, -180), 180) : 0
        let turning = abs(d) > 1e-4 && !ended
        let rotatable = s.activeDoc.map { st in
            st.selection.text == nil && st.selection.shapes.contains { id in st.shape(id).map { !$0.locked && $0.xfrm != nil } ?? false }
        } ?? false
        if turning && rotatable && !s.tool.dragging {
            app.run("shape.rotate", ["by": .num(d), "gesture": "move"])
            twisting = true
        } else if twisting {
            app.run("shape.rotate", ["gesture": "end", "ids": []])
            twisting = false
        }
    }
}

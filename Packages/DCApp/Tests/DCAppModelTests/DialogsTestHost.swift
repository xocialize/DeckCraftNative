// DCAppModelTests — a window-free host for the dialogs: the `AppHost` that routes the dialogs' UI
// commands and requests to a `DialogController`, and mock file panels (deckcraft's `Services`
// `pick_open` / `pick_save` in its tests).
import DCAppModel
import DCCore
import DCEngine
import DCModel
import Foundation

@MainActor
final class DialogsHost: AppHost, DialogServices {
    let model: AppModel
    let dialogs: DialogController
    /// What the next open panels answer, in order (nil = Cancel).
    var openPaths: [String?] = []
    /// What the save panel answers.
    var savePath: String?
    /// Hold the open panel's answer until `release` (a picker that finishes later).
    var holdPicks = false
    private(set) var held: [@MainActor (String?) -> Void] = []
    private(set) var asked: [String] = []
    private(set) var suggested: [String] = []
    private(set) var opened: [String] = []
    private(set) var copied: [String] = []

    init(_ session: Session = Session.withNew()) {
        model = AppModel(session: session)
        dialogs = DialogController(model: model)
        dialogs.fontFamiliesProvider = { ["Inter", "Lato", "Liberation Serif", "Comic Neue"] }
        model.host = self
        dialogs.services = self
    }

    var session: Session { model.session }
    var st: DocState? { model.session.activeDoc }
    var dialog: Dialog? { dialogs.current }

    func uiCommand(_ id: String, _ params: JSON) -> Result<JSON, CommandError>? { dialogs.uiCommand(id, params) }
    func uiRequest(_ request: UiRequest) { _ = dialogs.request(request) }
    func modelChanged() {}

    func pickOpen(_ purpose: String, _ done: @escaping @MainActor (String?) -> Void) {
        asked.append(purpose)
        if holdPicks {
            held.append(done)
        } else {
            done(openPaths.isEmpty ? nil : openPaths.removeFirst())
        }
    }

    /// Answer the oldest held pick with `path`.
    func release(_ path: String?) {
        guard !held.isEmpty else { return }
        held.removeFirst()(path)
    }

    func pickSave(_ name: String, _ done: @escaping @MainActor (String?) -> Void) {
        suggested.append(name)
        done(savePath)
    }

    func openURL(_ url: String) { opened.append(url) }
    func copyText(_ text: String) { copied.append(text) }

    /// Run a command the way the app does.
    @discardableResult
    func run(_ id: String, _ p: JSON = .emptyObject) -> Result<JSON, CommandError> { model.run(id, p) }

    /// Set the open dialog's fields and press `button`.
    func press(_ button: String, _ fields: [String: String] = [:]) {
        dialogs.set(fields)
        dialogs.press(button)
    }

    var undoLabels: [String] { st?.history.undo.map(\.label) ?? [] }
}

/// A temporary folder removed by `clean`.
struct TempDir {
    let url: URL
    init(_ name: String) {
        url = FileManager.default.temporaryDirectory.appending(path: "dcapp-dialogs-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func path(_ name: String) -> String { url.appending(path: name).path }
    func clean() { try? FileManager.default.removeItem(at: url) }
}

/// An 8×8 red PNG (`png()` in deckcraft's tests).
func redPNG() -> [UInt8] {
    let w = 8, h = 8
    var raw: [UInt8] = []
    for _ in 0 ..< h {
        raw.append(0)
        for _ in 0 ..< w { raw += [255, 0, 0, 255] }
    }
    let data = Data(raw)
    // A stored (uncompressed) zlib stream: header, one final block, Adler-32.
    var z: [UInt8] = [0x78, 0x01, 0x01]
    let n = UInt16(data.count)
    z += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8(~n >> 8)]
    z += raw
    var a: UInt32 = 1, b: UInt32 = 0
    for x in raw {
        a = (a + UInt32(x)) % 65521
        b = (b + a) % 65521
    }
    let adler = b << 16 | a
    z += [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        let len = UInt32(body.count)
        let crc = crc32(t + body)
        return [UInt8(len >> 24), UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)] + t + body
            + [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
    }
    let ihdr: [UInt8] = [0, 0, 0, UInt8(w), 0, 0, 0, UInt8(h), 8, 6, 0, 0, 0]
    return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", z) + chunk("IEND", [])
}

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for x in bytes {
        c ^= UInt32(x)
        for _ in 0 ..< 8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }
    return ~c
}

/// The gallery tiles in a form.
func tilesOf(_ form: [FormRow]) -> [FormTile] {
    form.flatMap { row -> [FormTile] in
        if case .tiles(let t) = row { return t }
        return []
    }
}

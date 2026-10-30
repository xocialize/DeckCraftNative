// DCApp — one presentation as an NSDocument. The engine's `Session` holds every open presentation, as
// deckcraft's does; a `PresentationDocument` is the window-side handle on one of them (by `DocState.uid`)
// and gives it the native lifecycle: Open, Save, Save As, Revert, Open Recent, the edited dot, and the
// close confirmation. Reading and writing go through the engine's own coders (`FileCommands`), so the
// bytes are the ones `dccli` and the engine scripts write.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import UniformTypeIdentifiers

/// The document types (deckcraft's `packaging/macos/Info.plist.in`).
public enum DocumentTypes {
    /// deckcraft's own UTI: the format is byte-compatible, so both apps claim the same type.
    public static let deckcraft = "ai.storyteller.deckcraft.presentation"
    public static let pptx = "org.openxmlformats.presentationml.presentation"
    public static let potx = "org.openxmlformats.presentationml.template"
    public static let ppsx = "org.openxmlformats.presentationml.slideshow"

    /// The engine's format name for a type (`FileCommands.saveBytes`); nil for types it can't write.
    public static func format(_ typeName: String) -> String? {
        switch typeName {
        case deckcraft, "deckcraft": "deckcraft"
        case pptx, "pptx": "pptx"
        default: nil
        }
    }

    /// The type for a file name, by extension (unbundled runs have no Info.plist to ask).
    public static func type(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "deckcraft": deckcraft
        case "pptx": pptx
        case "potx": potx
        case "ppsx": ppsx
        default: nil
        }
    }
}

@MainActor
public final class PresentationDocument: NSDocument {
    /// The engine document this one shows (`DocState.uid`); 0 until read or adopted.
    public private(set) var uid: UInt64 = 0
    /// It was opened read-only (a password to modify wasn't given): an untitled copy, so Save asks where.
    private(set) var openedReadOnly = false
    var model: AppModel? { AppController.shared?.model }

    override public init() { super.init() }

    /// A document for one the engine opened itself.
    init(adopting uid: UInt64) {
        super.init()
        self.uid = uid
        if let st = state {
            if let path = st.path { fileURL = URL(filePath: path); fileType = DocumentTypes.type(forExtension: fileURL?.pathExtension ?? "") }
            displayName = st.title
        }
    }

    /// The engine's state for this document.
    var state: DocState? { model?.session.documents.first { $0.uid == uid } }
    var engineIndex: Int? { model?.session.documents.firstIndex { $0.uid == uid } }

    nonisolated override public class var autosavesInPlace: Bool { false }
    nonisolated override public class var readableTypes: [String] { [DocumentTypes.deckcraft, DocumentTypes.pptx, DocumentTypes.potx, DocumentTypes.ppsx] }
    nonisolated override public class var writableTypes: [String] { [DocumentTypes.deckcraft, DocumentTypes.pptx] }
    nonisolated override public class func isNativeType(_ type: String) -> Bool { type == DocumentTypes.deckcraft }
    nonisolated override public func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { Self.writableTypes }
    nonisolated override public func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        DocumentTypes.format(typeName)
    }

    // MARK: Reading and writing

    // NSDocument reads and writes on the main thread unless a subclass opts into concurrency, and this one
    // doesn't: the engine's session is the main thread's.
    nonisolated override public func read(from data: Data, ofType typeName: String) throws {
        guard Thread.isMainThread else { throw CocoaError(.fileReadUnknown) }
        try MainActor.assumeIsolated { try readOnMain(data, typeName) }
    }

    private func readOnMain(_ data: Data, _ typeName: String) throws {
        guard let model else { throw CocoaError(.fileReadUnknown) }
        let name = fileURL?.lastPathComponent ?? "Untitled.\(DocumentTypes.format(typeName) ?? "deckcraft")"
        let bytes = [UInt8](data)
        let shown = fileURL?.lastPathComponent ?? name
        // A password-protected file asks for its passwords until it opens or the person cancels (PasswordPrompt):
        // the password to open first, then the password to modify, which Read Only skips.
        var password = PasswordPrompt.supplied, modify = PasswordPrompt.suppliedModify
        PasswordPrompt.supplied = nil
        PasswordPrompt.suppliedModify = nil
        var wrongOpen = false, wrongModify = false, askingModify = false, readOnlyChosen = false
        while true {
            do {
                let f = try FileCommands.openFile(name, bytes, password: password, modifyPassword: modify)
                if f.readOnly, !readOnlyChosen, PasswordPrompt.interactive {
                    askingModify = true
                    switch PasswordPrompt.askModify(shown, wrong: wrongModify) {
                    case .cancel: throw CocoaError(.userCancelled)
                    case .readOnly: readOnlyChosen = true
                    case let .password(p):
                        modify = p
                        continue
                    }
                }
                let i = FileCommands.addOpened(model.session, name, f.readOnly ? nil : fileURL?.path, f.presentation)
                if let st = model.session.documents.at(i) {
                    st.protection = f.protection
                    if f.readOnly { st.title = "\(st.title) (Read-Only)" }
                }
                openedReadOnly = f.readOnly
                uid = model.session.documents.at(i)?.uid ?? 0
                return
            } catch let e as EngineError {
                switch e {
                case .passwordRequired, .wrongPassword:
                    // The control channel's opens don't ask: the error goes back to the script.
                    guard PasswordPrompt.interactive else { break }
                    if askingModify {
                        // The password to open was right (the file was read): it's the password to modify that wasn't.
                        wrongModify = true
                        modify = nil
                        continue
                    }
                    if case .wrongPassword = e { wrongOpen = true }
                    guard let p = PasswordPrompt.ask(shown, wrong: wrongOpen) else { throw CocoaError(.userCancelled) }
                    password = p
                    continue
                default: break
                }
                throw NSError(domain: "DeckCraft", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(e)"])
            } catch {
                throw NSError(domain: "DeckCraft", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
            }
        }
    }

    nonisolated override public func data(ofType typeName: String) throws -> Data {
        guard Thread.isMainThread else { throw CocoaError(.fileWriteUnknown) }
        return try MainActor.assumeIsolated { try dataOnMain(typeName) }
    }

    private func dataOnMain(_ typeName: String) throws -> Data {
        guard let st = state, let format = DocumentTypes.format(typeName) else { throw CocoaError(.fileWriteUnknown) }
        do {
            return Data(try Protection.fileBytes(st, format))
        } catch {
            throw NSError(domain: "DeckCraft", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
        }
    }

    /// A new, untitled document: the engine's `file.new`.
    func createNew() {
        guard let model else { return }
        _ = model.run("file.new")
        uid = model.session.activeDoc?.uid ?? 0
        fileType = DocumentTypes.deckcraft
    }

    nonisolated override public func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        guard Thread.isMainThread, saveOperation != .autosaveElsewhereOperation, saveOperation != .saveToOperation else { return }
        MainActor.assumeIsolated { didSave(to: url, ofType: typeName) }
    }

    /// The engine's document now matches the file: its path, title and saved revision.
    private func didSave(to url: URL, ofType typeName: String) {
        guard let st = state else { return }
        st.protectionEdited = false
        // Saved in a format that can't keep its passwords (.deckcraft): the document has none now, and says so.
        if st.protection != nil, let format = DocumentTypes.format(typeName), !Protection.keepsPasswords(format) {
            st.protection = nil
            model?.status = String(localized: "“\(url.deletingPathExtension().lastPathComponent)” was saved in a format that can't keep a password, so it isn't password-protected.", bundle: .module, comment: "Status line after saving a password-protected presentation as .deckcraft; %@ is the file name")
        }
        st.path = url.path
        st.title = url.lastPathComponent
        st.savedDocRef = st.docRef
        syncChangeCount()
        model?.changed()
    }

    // MARK: State

    /// The edited dot follows the engine (`DocState.isDirty`): undo back to the saved state clears it.
    func syncChangeCount() {
        guard let st = state else { return }
        // A save the engine made itself (`file.save {path}`, a script, the control channel's `app.save`).
        if let path = st.path, path != fileURL?.path {
            fileURL = URL(filePath: path)
            fileType = DocumentTypes.type(forExtension: URL(filePath: path).pathExtension) ?? fileType
        }
        if st.isDirty != isDocumentEdited { updateChangeCount(st.isDirty ? .changeDone : .changeCleared) }
    }

    override public func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    /// A PowerPoint Slide Show (`.ppsx`) opens straight into its show, as PowerPoint does; Esc leaves it
    /// in the editor.
    private var playedOnOpen = false

    override public func showWindows() {
        super.showWindows()
        guard fileType == DocumentTypes.ppsx, !playedOnOpen, let model else { return }
        playedOnOpen = true
        AppController.shared?.activate(uid: uid)
        model.run("show.start", ["from": 0])
    }

    override public func close() {
        if let i = engineIndex, let model {
            model.session.closeDocument(i)
            super.close()
            model.changed()
        } else {
            super.close()
        }
    }

    /// Close the window of a document the engine already closed.
    func closeWithoutEngine() {
        uid = 0
        super.close()
    }
}

/// Creates `PresentationDocument`s whatever the bundle declares: `DeckCraftDev` runs without an Info.plist.
@MainActor
final class DocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? { PresentationDocument.self }
    override var documentClassNames: [String] { [NSStringFromClass(PresentationDocument.self)] }
    override var defaultType: String? { DocumentTypes.deckcraft }

    override func typeForContents(of url: URL) throws -> String {
        if let t = DocumentTypes.type(forExtension: url.pathExtension) { return t }
        return try super.typeForContents(of: url)
    }

    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        // The engine opens the document before NSDocumentController knows it: no second window for it.
        AppController.shared?.syncSuspended += 1
        defer { AppController.shared?.syncSuspended -= 1 }
        let d = PresentationDocument()
        d.createNew()
        return d
    }

    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        AppController.shared?.syncSuspended += 1
        defer { AppController.shared?.syncSuspended -= 1 }
        let d = PresentationDocument()
        d.fileURL = url
        d.fileType = typeName
        try d.read(from: Data(contentsOf: url), ofType: typeName)
        // A read-only copy (a password to modify wasn't given) is untitled, so Save can't overwrite the original.
        if d.openedReadOnly {
            d.fileURL = nil
            d.displayName = d.state?.title
        }
        return d
    }

    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        AppController.shared?.model.changed()
    }
}

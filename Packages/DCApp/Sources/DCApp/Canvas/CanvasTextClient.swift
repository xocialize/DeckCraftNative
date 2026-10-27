// DCApp — the canvas as the Mac's text system sees it: `NSTextInputClient`, so typing, input methods (marked
// text and their candidate windows), dictation, the accent menu and the text services all edit slide text
// through the engine's commands; and the Services menu's requestor. The logic is `CanvasTextInput`
// (DCAppModel); this is the AppKit shell. Behaviour from deckcraft `crates/ui-egui/src/lib.rs` (`keyboard`,
// `ime_event`) and `canvas.rs` (`ime_area`) (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry

extension CanvasView: @MainActor NSTextInputClient {
    private static let none = NSRange(location: NSNotFound, length: 0)

    private func plain(_ s: Any) -> String {
        (s as? NSAttributedString)?.string ?? (s as? String) ?? ""
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        inTextInput = true
        defer { inTextInput = false }
        guard let model, activeState != nil else { return }
        let text = plain(string)
        model.input { s throws(EngineError) in try CanvasTextInput.insertText(s, text, replacement: replacementRange) }
        inputContext?.invalidateCharacterCoordinates()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inTextInput = true
        defer { inTextInput = false }
        guard let model, activeState != nil else { return }
        let text = plain(string)
        model.input { s throws(EngineError) in
            try CanvasTextInput.setMarkedText(s, text, selected: selectedRange, replacement: replacementRange)
        }
        inputContext?.invalidateCharacterCoordinates()
    }

    func unmarkText() {
        inTextInput = true
        defer { inTextInput = false }
        guard let model, activeState != nil else { return }
        model.input { s throws(EngineError) in
            CanvasTextInput.unmarkText(s)
            return .null
        }
    }

    func selectedRange() -> NSRange {
        activeState.flatMap(CanvasTextInput.selectedRange) ?? Self.none
    }

    func markedRange() -> NSRange {
        activeState.flatMap(CanvasTextInput.markedRange) ?? Self.none
    }

    func hasMarkedText() -> Bool {
        activeState?.composition != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let st = activeState, let d = CanvasTextDocument(st), let (s, r) = d.substring(range) else { return nil }
        actualRange?.pointee = r
        return NSAttributedString(string: s)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the range is drawn, in screen coordinates: the input method's candidate window goes there
    /// (deckcraft's `ime_area`, #101).
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let st = activeState, let xf, let window else { return .zero }
        let slideRect = CanvasTextInput.firstRect(st, range) ?? CanvasTextInput.imeArea(st)
        guard let r = slideRect else { return .zero }
        let inView = xf.toView(r)
        return window.convertToScreen(convert(inView, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let st = activeState, let xf, let window else { return NSNotFound }
        let inView = convert(window.convertPoint(fromScreen: point), from: nil)
        return CanvasTextInput.characterIndex(st, xf.toSlide(inView)) ?? NSNotFound
    }

    /// Commands the key bindings give for keys the canvas didn't take itself (⌃A, ⌃E, ⌃K…): the
    /// engine's keys for the same motions.
    override func doCommand(by selector: Selector) {
        guard let model, activeState != nil else { return }
        let map: [Selector: (String, Mods)] = [
            #selector(moveToBeginningOfLine(_:)): ("Home", Mods()),
            #selector(moveToBeginningOfParagraph(_:)): ("Home", Mods()),
            #selector(moveToEndOfLine(_:)): ("End", Mods()),
            #selector(moveToEndOfParagraph(_:)): ("End", Mods()),
            #selector(moveForward(_:)): ("Right", Mods()),
            #selector(moveBackward(_:)): ("Left", Mods()),
            #selector(moveUp(_:)): ("Up", Mods()),
            #selector(moveDown(_:)): ("Down", Mods()),
            #selector(moveLeft(_:)): ("Left", Mods()),
            #selector(moveRight(_:)): ("Right", Mods()),
            #selector(deleteForward(_:)): ("Delete", Mods()),
            #selector(deleteBackward(_:)): ("Backspace", Mods()),
            #selector(insertNewline(_:)): ("Enter", Mods()),
            #selector(insertLineBreak(_:)): ("Enter", Mods(shift: true)),
            #selector(insertTab(_:)): ("Tab", Mods()),
            #selector(insertBacktab(_:)): ("Tab", Mods(shift: true)),
            #selector(cancelOperation(_:)): ("Escape", Mods()),
        ]
        if let (key, mods) = map[selector] { model.key(key, mods) }
    }
}

// MARK: - Services

extension CanvasView: @MainActor NSServicesMenuRequestor {
    /// The canvas sends the selected text and takes text back while text is being edited.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let st = activeState, st.selection.text != nil {
            let sendOK = sendType == nil || (sendType == .string && st.selection.text?.isRange == true)
            let returnOK = returnType == nil || returnType == .string
            if sendOK && returnOK && (sendType != nil || returnType != nil) { return self }
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), let st = activeState, let r = CanvasTextInput.selectedRange(st), r.length > 0,
              let d = CanvasTextDocument(st), let (s, _) = d.substring(r) else { return false }
        pboard.clearContents()
        return pboard.setString(s, forType: .string)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let s = pboard.string(forType: .string), let model, activeState != nil else { return false }
        model.input { session throws(EngineError) in try CanvasTextInput.insertText(session, s, replacement: NSRange(location: NSNotFound, length: 0)) }
        return true
    }
}

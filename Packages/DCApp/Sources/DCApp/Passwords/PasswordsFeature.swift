// DCApp — File › Passwords… and Review › Protect Presentation (Docs/plans/Legacy-PPT-and-Encryption.md §2–3, E3): as
// in PowerPoint, one sheet with a password to open ("Encrypt this presentation and require a password to open") and a
// password to modify, each turned on with its checkbox and typed twice. They're kept with the open document
// (`DocState.protection`) and written when it is saved as .pptx; the document needs saving after a change.
//
// `file.passwords` without parameters shows the sheet. Scripts and the control channel pass the passwords instead:
// `{password?: string|null, modifyPassword?: string|null}`, where a missing key leaves that password as it is and null
// or "" removes it.
import AppKit
import DCCore
import DCAppModel
import DCEngine

@MainActor
enum PasswordsFeature {
    static let maxLength = 255

    static func install(_ app: AppController) {
        app.handle(["file.passwords"]) { p in
            guard let st = app.model.session.activeDoc else { return .failure("no active presentation") }
            if p["password"] != nil || p["modifyPassword"] != nil {
                func value(_ key: String, _ current: String?) -> String? {
                    guard let v = p[key] else { return current }
                    guard let s = v.asStr, !s.isEmpty else { return nil }
                    return s
                }
                let open = value("password", st.protection?.password), modify = value("modifyPassword", st.protection?.modifyPassword)
                if let bad = [open, modify].compactMap({ $0 }).first(where: { $0.count > maxLength }) {
                    return .failure(CommandError("a password can be at most \(maxLength) characters (one has \(bad.count))"))
                }
                apply(app, st, open: open, modify: modify)
                return .success(["password": .bool(open != nil), "modifyPassword": .bool(modify != nil)])
            }
            guard let window = AppControlHost.keyDocumentWindow() else { return .failure("no presentation window") }
            PasswordsSheet(st).present(on: window) { open, modify in apply(app, st, open: open, modify: modify) }
            return .success(.null)
        }
    }

    /// Keep the passwords with the document; it needs saving when they changed.
    static func apply(_ app: AppController, _ st: DocState, open: String?, modify: String?) {
        let new = open == nil && modify == nil ? nil : DocProtection(password: open, modifyPassword: modify)
        guard new != st.protection else { return }
        st.protection = new
        st.protectionEdited = true
        app.model.changed()
    }
}

/// The Passwords sheet.
@MainActor
final class PasswordsSheet {
    let st: DocState
    let openBox: NSButton, modifyBox: NSButton
    let open = NSSecureTextField(), openAgain = NSSecureTextField()
    let modify = NSSecureTextField(), modifyAgain = NSSecureTextField()

    init(_ st: DocState) {
        self.st = st
        openBox = NSButton(checkboxWithTitle: String(localized: "Encrypt this presentation and require a password to open", bundle: .module,
                                                     comment: "Passwords sheet: turns the password to open on"), target: nil, action: nil)
        modifyBox = NSButton(checkboxWithTitle: String(localized: "Require a password to modify the presentation", bundle: .module,
                                                       comment: "Passwords sheet: turns the password to modify on"), target: nil, action: nil)
        openBox.state = st.protection?.password != nil ? .on : .off
        modifyBox.state = st.protection?.modifyPassword != nil ? .on : .off
    }

    /// The sheet over `window`; `done` gets the passwords when OK is chosen and they're valid.
    func present(on window: NSWindow, error: String? = nil, _ done: @escaping @MainActor (String?, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Passwords", bundle: .module, comment: "Passwords sheet: its title")
        alert.informativeText = error ?? String(localized: "A password to open encrypts the presentation when it is saved as a PowerPoint file. A password to modify lets others open it read-only.",
                                                bundle: .module, comment: "Passwords sheet: what the two passwords do")
        if error != nil { alert.alertStyle = .warning }
        alert.accessoryView = accessory()
        alert.addButton(withTitle: String(localized: "OK", bundle: .module, comment: "Passwords sheet: keeps the passwords"))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module, comment: "Passwords sheet: changes nothing"))
        alert.window.initialFirstResponder = openBox.state == .on ? open : openBox
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            switch validate() {
            case let .success((o, m)): done(o, m)
            case let .failure(message):
                // Ask again, the boxes as they were and the fields empty.
                for f in [open, openAgain, modify, modifyAgain] { f.stringValue = "" }
                DispatchQueue.main.async { self.present(on: window, error: message.message, done) }
            }
        }
    }

    /// The passwords the sheet asks for: a box that's on with empty fields keeps the password the document has.
    func validate() -> Result<(String?, String?), CommandError> {
        func one(_ box: NSButton, _ a: NSSecureTextField, _ b: NSSecureTextField, _ current: String?) -> Result<String?, CommandError> {
            guard box.state == .on else { return .success(nil) }
            if a.stringValue.isEmpty && b.stringValue.isEmpty {
                guard let current else {
                    return .failure(CommandError(String(localized: "Type the password in both fields.", bundle: .module,
                                                        comment: "Passwords sheet: a password was turned on but not typed")))
                }
                return .success(current)
            }
            guard a.stringValue == b.stringValue else {
                return .failure(CommandError(String(localized: "The passwords don't match. Type the same password in both fields.",
                                                    bundle: .module, comment: "Passwords sheet: the two fields differ")))
            }
            guard a.stringValue.count <= PasswordsFeature.maxLength else {
                return .failure(CommandError(String(localized: "A password can be at most 255 characters.", bundle: .module,
                                                    comment: "Passwords sheet: too long")))
            }
            return .success(a.stringValue)
        }
        switch (one(openBox, open, openAgain, st.protection?.password), one(modifyBox, modify, modifyAgain, st.protection?.modifyPassword)) {
        case let (.success(o), .success(m)): return .success((o, m))
        case let (.failure(e), _), let (_, .failure(e)): return .failure(e)
        }
    }

    func accessory() -> NSView {
        func heading(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return l
        }
        func field(_ f: NSSecureTextField, _ placeholder: String, _ hasOne: Bool) -> NSSecureTextField {
            f.placeholderString = hasOne
                ? String(localized: "Unchanged", bundle: .module, comment: "Passwords sheet: an empty field keeps the current password")
                : placeholder
            f.setAccessibilityLabel(placeholder)
            f.widthAnchor.constraint(equalToConstant: 280).isActive = true
            return f
        }
        let password = String(localized: "Password", bundle: .module, comment: "Password prompt: the field's placeholder")
        let verify = String(localized: "Verify", bundle: .module, comment: "Passwords sheet: the field to type the password again")
        let stack = NSStackView(views: [
            heading(String(localized: "Password to open", bundle: .module, comment: "Passwords sheet: section heading")),
            openBox, field(open, password, st.protection?.password != nil), field(openAgain, verify, st.protection?.password != nil),
            heading(String(localized: "Password to modify", bundle: .module, comment: "Passwords sheet: section heading")),
            modifyBox, field(modify, password, st.protection?.modifyPassword != nil),
            field(modifyAgain, verify, st.protection?.modifyPassword != nil),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: openAgain)
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: stack.fittingSize.height)
        return stack
    }
}

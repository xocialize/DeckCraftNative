// DCApp — asking for a presentation's password when one is opened (Docs/plans/Legacy-PPT-and-Encryption.md §2–3):
// like PowerPoint's Password to Open, a small window before the presentation's own, naming the file, with a
// password field and Open and Cancel; a wrong password asks again and says so. Scripts and the control channel
// never see it: they pass `password` (`file.open`, `app.open`), and a missing or wrong one comes back as an error.
import AppKit

@MainActor
enum PasswordPrompt {
    /// The password for the next document read, given by the control channel's `app.open {password}`. When it is set,
    /// the read doesn't ask: a wrong password is an error.
    static var supplied: String?
    /// False while the control channel opens a file: nothing may wait for a person.
    static var interactive = true

    /// Asks for the password of the file named `name`; nil when the person cancels. `wrong`: the last one wasn't it.
    static func ask(_ name: String, wrong: Bool) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Enter the password to open “\(name)”.", bundle: .module,
                                   comment: "Password prompt when opening a password-protected presentation; %@ is the file name")
        alert.informativeText = wrong
            ? String(localized: "The password is incorrect. Passwords are case-sensitive.", bundle: .module,
                     comment: "Password prompt after a wrong password")
            : String(localized: "This presentation is password-protected.", bundle: .module,
                     comment: "Password prompt: why it asks")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = String(localized: "Password", bundle: .module, comment: "Password prompt: the field's placeholder")
        field.setAccessibilityLabel(String(localized: "Password", bundle: .module, comment: "Password prompt: the field's placeholder"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Open", bundle: .module, comment: "Password prompt: opens the presentation"))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module, comment: "Password prompt: doesn't open it"))
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

// DCIntentsKit — what an intent run from the app's control channel produced (`intents.run`, DCApp's
// `IntentsFeature`): the values each intent's `perform` reports, and the folder Export Presentation writes to.
// Outside such a run (Shortcuts, Siri, Spotlight, the App Intents extension) reporting is a no-op.
import DCCore
import Foundation

/// The values an intent run from the control channel reported.
public final class IntentsRun: @unchecked Sendable {
    /// The run in progress on this task, if the control channel started it.
    @TaskLocal public static var current: IntentsRun?

    /// The folder Export Presentation writes to while this run is current.
    public let directory: URL
    private let lock = NSLock()
    private var values: [JSON] = []

    public init(directory: URL) { self.directory = directory }

    /// Record a value an intent returns (a no-op unless the control channel runs it).
    public static func report(_ value: JSON) {
        guard let run = current else { return }
        run.lock.lock()
        run.values.append(value)
        run.lock.unlock()
    }

    /// Everything reported so far, in order.
    public var reported: [JSON] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

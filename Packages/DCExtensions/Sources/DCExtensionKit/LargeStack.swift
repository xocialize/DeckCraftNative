// DCExtensionKit — running the engine off the thread an extension is called on. The PPTX reader and the
// renderer recurse once per nesting level of a group (the app runs them on the main thread's 8 MB stack, the
// PPTX reader on a 32 MB thread of its own: `PPTX.onLargeStack`). An extension is called on a dispatch or
// Swift concurrency thread with 512 KB, so the reading and drawing happen on a thread with a stack like the
// PPTX reader's.
import Foundation

public enum LargeStack {
    /// The stack every extension job runs on.
    public static let stackSize = 32 << 20

    /// Runs `body` on a new thread with a `stackSize` stack, then `done` with its result on that thread.
    public static func async<T: Sendable>(_ body: @escaping @Sendable () -> T, then done: @escaping @Sendable (T) -> Void) {
        let thread = Thread { done(body()) }
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs `body` on a new thread with a `stackSize` stack and waits for it. For callers that must answer
    /// synchronously (Spotlight's importer); nil only if the thread never ran.
    public static func sync<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let box = Box<T>()
        let thread = Thread {
            box.value = body()
            box.done.signal()
        }
        thread.stackSize = stackSize
        thread.qualityOfService = .utility
        thread.start()
        box.done.wait()
        return box.value
    }

    /// The result handed from the thread (written before `done` is signalled, read after it is waited for).
    private final class Box<T>: @unchecked Sendable {
        var value: T?
        let done = DispatchSemaphore(value: 0)
    }
}

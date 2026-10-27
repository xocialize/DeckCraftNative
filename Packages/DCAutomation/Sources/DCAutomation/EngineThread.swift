// DCAutomation — the thread engine commands run on when automation drives them.
//
// deckcraft's automation calls `Session::execute` on Rust threads (the main thread's 8 MiB, the server's
// own). A Swift concurrency thread has 512 KiB, and deeply nested groups recurse once per level through
// the shape-tree walks and the PPTX reader and writer (which run on a 32 MiB thread of their own,
// `PPTX.onLargeStack`). So whatever runs engine commands off the main thread here (the MCP server's
// handlers, the control channel) hands them to an `EngineThread`: one dedicated thread with a 32 MiB
// stack that runs work items in the order they arrive. Everything it runs is confined to it, which is
// what makes the non-Sendable `Session` and backends safe to keep behind it.
import Foundation

/// A serial worker thread with a large stack.
public final class EngineThread: @unchecked Sendable {
    /// The stack every engine thread gets: what DCPPTX gives its import and export.
    public static let stackSize = 32 << 20

    /// The queue the thread drains; the thread holds it, so it outlives the `EngineThread` until stopped.
    private final class Worker: @unchecked Sendable {
        let condition = NSCondition()
        // Guarded by `condition`.
        var queue: [() -> Void] = []
        var stopped = false

        func loop() {
            while true {
                condition.lock()
                while queue.isEmpty && !stopped { condition.wait() }
                if queue.isEmpty {
                    condition.unlock()
                    return
                }
                let work = queue.removeFirst()
                condition.unlock()
                work()
            }
        }

        func submit(_ work: @escaping () -> Void) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            if stopped { return false }
            queue.append(work)
            condition.signal()
            return true
        }

        func stop() {
            condition.lock()
            stopped = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private let worker = Worker()
    private let thread: Thread

    /// Starts the thread (`name` shows in debuggers and crash reports).
    public init(name: String = "dc.engine") {
        let w = worker
        thread = Thread { w.loop() }
        thread.name = name
        thread.stackSize = EngineThread.stackSize
        thread.start()
    }

    deinit { worker.stop() }

    /// Stops the thread once the queued work is done. Work submitted afterwards never runs.
    public func stop() { worker.stop() }

    private func submit(_ work: @escaping () -> Void) -> Bool { worker.submit(work) }

    /// True on this engine's thread.
    public var isCurrent: Bool { Thread.current === thread }

    /// Runs `body` on the engine thread and waits for it (from a thread that may block: not a concurrency
    /// thread, which should use `run`). On the engine thread itself it runs in place. nil when the thread
    /// was stopped before `body` could run.
    public func sync<T>(_ body: @escaping () -> T) -> T? {
        if isCurrent { return body() }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        guard submit({
            box.value = body()
            done.signal()
        }) else { return nil }
        done.wait()
        return box.value
    }

    /// Runs `body` on the engine thread and suspends until it is done. nil when the thread was stopped.
    public func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            if !submit({ c.resume(returning: body()) }) { c.resume(returning: nil) }
        }
    }

    /// Runs `body` on a fresh thread with an `EngineThread.stackSize` stack and waits for it: for a
    /// one-off command line run that must not recurse on a small stack.
    public static func onLargeStack<T>(_ body: @escaping () -> T) -> T? {
        let box = ResultBox<T>()
        let work = EngineConfined(body)
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            box.value = work.value()
            done.signal()
        }
        t.stackSize = stackSize
        t.start()
        done.wait()
        return box.value
    }
}

/// A value handed back from another thread: written before a semaphore is signalled, read after it is
/// waited for.
final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// A value confined to an `EngineThread`: only code running there touches it.
public final class EngineConfined<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

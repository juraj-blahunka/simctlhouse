import Foundation

/// Runs two independent pieces of work at the same time and returns both results, or the first error.
/// Each `simctl` call spends 0.1-0.3s (seconds under load) waiting on CoreSimulator, so overlapping them cuts wall time.
func concurrently<A, B>(_ first: @Sendable () throws -> A, _ second: @Sendable () throws -> B) throws -> (A, B) {
    try withoutActuallyEscaping(second) { second in
        let b = OwnThread(second)
        let a = Result { try first() }
        let bResult = b.join()
        return (try a.get(), try bResult.get())
    }
}

/// Runs `body` for every item at the same time and waits for all of them.
func concurrentForEach<T: Sendable>(_ items: [T], _ body: @Sendable (T) -> Void) {
    guard let first = items.first else { return }
    withoutActuallyEscaping(body) { body in
        let others = items.dropFirst().map { item in OwnThread { body(item) } }
        body(first)
        for other in others { _ = other.join() }
    }
}

/// Runs work on a thread of its own, started at once, and hands back its result on `join`.
///
/// GCD would not do: once every core is busy, `concurrentPerform` runs its iterations one after the other
/// and the global queues hold work back until a thread frees up.
/// Work that waits for the other side, as a pipe reader does, then stalls or deadlocks.
final class OwnThread<T>: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private var work: (() throws -> T)?
    private var result: Result<T, Error>?

    init(_ work: @escaping () throws -> T) {
        self.work = work
        Thread.detachNewThread { self.run() }
    }

    /// Lets go of `work` before `join` returns, as `withoutActuallyEscaping` in the callers requires.
    private func run() {
        result = Result { try work!() }
        work = nil
        finished.signal()
    }

    /// Waits for the work to finish; the semaphore orders the write of `result` before this read.
    func join() -> Result<T, Error> {
        finished.wait()
        return result!
    }
}

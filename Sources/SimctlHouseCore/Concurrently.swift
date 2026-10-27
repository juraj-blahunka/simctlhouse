import Foundation

/// Runs two independent pieces of work at the same time and returns both results, or the first error.
/// Each `simctl` call spends 0.1-0.3s (seconds under load) waiting on CoreSimulator, so overlapping them cuts wall time.
func concurrently<A, B>(_ first: @Sendable () throws -> A, _ second: @Sendable () throws -> B) throws -> (A, B) {
    nonisolated(unsafe) var a: Result<A, Error>?
    nonisolated(unsafe) var b: Result<B, Error>?
    DispatchQueue.concurrentPerform(iterations: 2) { index in
        if index == 0 { a = Result { try first() } } else { b = Result { try second() } }
    }
    return (try a!.get(), try b!.get())
}

/// Runs `body` for every item at the same time and waits for all of them.
func concurrentForEach<T: Sendable>(_ items: [T], _ body: @Sendable (T) -> Void) {
    DispatchQueue.concurrentPerform(iterations: items.count) { body(items[$0]) }
}

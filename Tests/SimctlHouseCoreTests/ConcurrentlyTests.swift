import Foundation
import Testing
@testable import SimctlHouseCore

@Suite struct ConcurrentlyTests {
    @Test func runsBothAndReturnsTheirResults() throws {
        let (a, b) = try concurrently({ 1 }, { "two" })
        #expect(a == 1)
        #expect(b == "two")
    }

    @Test func runsBothAtTheSameTime() throws {
        let pair = Rendezvous(count: 2)
        let (a, b) = try concurrently({ pair.arrive() }, { pair.arrive() })
        #expect(a && b)
    }

    // A CI runner has 3 cores, and other tests keep them busy; GCD then stops handing out threads.
    @Test func runsBothAtTheSameTimeWhileEveryCoreIsBusy() throws {
        let pair = Rendezvous(count: 2)
        let (a, b) = try whileEveryCoreIsBusy { try concurrently({ pair.arrive() }, { pair.arrive() }) }
        #expect(a && b)
    }

    @Test func propagatesAnError() {
        #expect(throws: SimctlHouseError.io("boom")) {
            _ = try concurrently({ 1 }, { () throws -> Int in throw SimctlHouseError.io("boom") })
        }
    }

    @Test func forEachRunsEveryItemAtTheSameTimeWhileEveryCoreIsBusy() {
        let met = Locked<[Bool]>([])
        let all = Rendezvous(count: 3)
        whileEveryCoreIsBusy {
            concurrentForEach([1, 2, 3]) { _ in
                let result = all.arrive()
                met.mutate { $0.append(result) }
            }
        }
        #expect(met.value == [true, true, true])
    }

    @Test func forEachOfNothingDoesNothing() {
        concurrentForEach([Int]()) { _ in Issue.record("ran without an item") }
    }
}

/// Lets `count` threads wait for each other: run one after the other, the first would time out.
/// `arrive` is true once all of them arrived in time.
private final class Rendezvous: Sendable {
    private let arrived = Locked(0)
    private let everyone = DispatchSemaphore(value: 0)
    private let count: Int

    init(count: Int) { self.count = count }

    func arrive() -> Bool {
        var last = false
        arrived.mutate {
            $0 += 1
            last = $0 == count
        }
        if last { for _ in 1..<count { everyone.signal() } }
        return last || everyone.wait(timeout: .now() + 10) == .success
    }
}

/// Runs `body` while busy work occupies every thread GCD's global pool will hand out.
private func whileEveryCoreIsBusy<T>(_ body: () throws -> T) rethrows -> T {
    let done = Locked(false)
    for _ in 0..<ProcessInfo.processInfo.activeProcessorCount * 2 {
        DispatchQueue.global().async {
            // Checks the flag only every millisecond: a contended lock blocks, and GCD replaces blocked threads.
            while !done.value {
                let end = DispatchTime.now() + .milliseconds(1)
                while DispatchTime.now() < end {}
            }
        }
    }
    defer { done.mutate { $0 = true } }
    // The pool is full once new work no longer starts; how many threads that takes depends on what else runs.
    let deadline = Date.now + 5
    while Date.now < deadline {
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { started.signal() }
        if started.wait(timeout: .now() + .milliseconds(100)) == .timedOut { break }
    }
    return try body()
}

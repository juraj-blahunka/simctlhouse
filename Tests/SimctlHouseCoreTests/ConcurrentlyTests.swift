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
        // Each side waits for the other to start; run one after the other, the first would time out.
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let (a, b) = try concurrently(
            {
                firstStarted.signal()
                return secondStarted.wait(timeout: .now() + 10) == .success
            },
            {
                secondStarted.signal()
                return firstStarted.wait(timeout: .now() + 10) == .success
            }
        )
        #expect(a && b)
    }

    @Test func propagatesAnError() {
        #expect(throws: SimctlHouseError.io("boom")) {
            _ = try concurrently({ 1 }, { () throws -> Int in throw SimctlHouseError.io("boom") })
        }
    }
}

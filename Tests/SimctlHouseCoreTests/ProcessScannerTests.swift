import Foundation
import Testing
@testable import SimctlHouseCore

/// The real scanner, against live processes. Claims (D28) and daemon records trust `startTime` to tell a live
/// process from an exited one and from a recycled pid, so it must answer for this process and nothing else.
@Suite struct ProcessScannerTests {
    let scanner = PSProcessScanner()

    @Test func knowsWhenThisProcessStarted() throws {
        let started = try #require(scanner.startTime(of: getpid()))
        #expect(started <= Date())
        #expect(started > Date().addingTimeInterval(-24 * 60 * 60))
        #expect(scanner.startTime(of: getpid()) == started)
    }

    @Test func anExitedProcessHasNoStartTime() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(scanner.startTime(of: process.processIdentifier) == nil)
    }

    @Test func seesItsOwnCommandLine() throws {
        let lines = try scanner.commandLines()
        #expect(lines.contains { $0.contains(ProcessInfo.processInfo.processName) })
    }
}

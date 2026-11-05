import Foundation
import Testing
@testable import simctlhouse

@Suite struct ListWatchTests {
    /// Each frame starts at the top left and clears every line before writing it and the screen below,
    /// so a shorter table never leaves rows of the previous one behind.
    @Test func aFrameRedrawsInPlace() {
        let date = Date(timeIntervalSince1970: 1_793_037_600)
        let frame = ListWatch.frame(lines: ["NAME", "wild-dragon"], at: date)
        #expect(frame.hasPrefix("\u{1B}[H\u{1B}[KEvery 1s"))
        #expect(frame.hasSuffix("\u{1B}[J"))
        #expect(frame.contains("Press q to quit.\n\u{1B}[K\n\u{1B}[KNAME\n\u{1B}[Kwild-dragon\u{1B}[J"))
    }

    /// A wrapped line would push the frame down, and one past the bottom would scroll the header away.
    @Test func aFrameFitsTheTerminal() {
        let frame = ListWatch.frame(lines: ["NAME  STATUS", "wild-dragon  available", "bold-otter  leased"], at: Date(), size: (rows: 4, columns: 10))
        let lines = frame.dropFirst(3).dropLast(3).components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\u{1B}[K", with: "") }
        #expect(lines == ["Every 1s, ", "", "NAME  STAT", "wild-drago"])
    }

    @Test func showsWhatThePoolReportedBelowTheTable() {
        let messages = RecentMessages(now: { Date(timeIntervalSince1970: 0) })
        for index in 1...7 { messages.append("message \(index)") }
        #expect(messages.recent.count == RecentMessages.limit)
        #expect(messages.recent.last?.hasSuffix("  message 7") == true)
        let frame = ListWatch.frame(lines: ["NAME"], messages: messages.recent, at: Date())
        #expect(frame.contains("\u{1B}[KNAME\n\u{1B}[K\n\u{1B}[K"))
        #expect(frame.contains("message 3") && !frame.contains("message 2"))
    }

    @Test func watchDoesNotGoWithJSON() {
        #expect(throws: (any Error).self) { try List.parse(["--watch", "--json"]) }
    }
}

import Foundation
import Testing
@testable import simctlhouse

@Suite struct ListWatchTests {
    /// Each frame starts at the top left and clears the rest of every line and the screen below,
    /// so a shorter table never leaves rows of the previous one behind.
    @Test func aFrameRedrawsInPlace() {
        let date = Date(timeIntervalSince1970: 1_793_037_600)
        let frame = ListWatch.frame(lines: ["NAME", "wild-dragon"], at: date)
        #expect(frame.hasPrefix("\u{1B}[H"))
        #expect(frame.hasSuffix("\u{1B}[J"))
        #expect(frame.contains("Press q to quit.\u{1B}[K\n\u{1B}[K\nNAME\u{1B}[K\nwild-dragon\u{1B}[K"))
    }

    @Test func watchDoesNotGoWithJSON() {
        #expect(throws: (any Error).self) { try List.parse(["--watch", "--json"]) }
    }
}

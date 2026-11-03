import Foundation
import Testing
@testable import simctlhouse

@Suite struct FormatTests {
    @Test(
        arguments: [
            (5, "5s"),
            (59.4, "59s"),
            (59.6, "1m"),
            (60, "1m"),
            (89, "1m"),
            (90, "2m"),
            (30 * 60, "30m"),
            (0.4, "expired"),
        ] as [(TimeInterval, String)])
    func leaseLengthRoundsToTheNearestUnit(seconds: TimeInterval, expected: String) {
        #expect(Format.leaseLength(seconds) == expected)
    }

    /// `state.json` keeps whole seconds, so a lease granted just now reads back up to a second short.
    /// Counting down to that date shows 59s for a 60s lease; the granted length does not.
    @Test func aLeaseJustGrantedShowsItsFullLength() {
        // A 5s lease whose expiry lost 0.6s of fraction, read back 0.1s later.
        let storedExpiry = Date().addingTimeInterval(5 - 0.7)
        #expect(Format.minutes(until: storedExpiry) == "4s")
        #expect(Format.leaseLength(5) == "5s")
    }

    @Test func countsDownToAnExpiry() {
        #expect(Format.minutes(until: nil) == "-")
        #expect(Format.minutes(until: Date().addingTimeInterval(-1)) == "expired")
        #expect(Format.minutes(until: Date().addingTimeInterval(10 * 60 + 5)) == "10m")
    }

    @Test(
        arguments: [
            (0, "0s"),
            (59, "59s"),
            (60, "1m"),
            (59 * 60 + 59, "59m"),
            (3600, "1h 00m"),
            (2 * 3600 + 5 * 60, "2h 05m"),
            (-5, "0s"),
        ] as [(TimeInterval, String)])
    func durationTruncatesToTheUnitShown(seconds: TimeInterval, expected: String) {
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(Format.duration(from: start, to: start.addingTimeInterval(seconds)) == expected)
    }
}

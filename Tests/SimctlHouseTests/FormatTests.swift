import Foundation
import Testing
@testable import SimctlHouseCore
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

    static func device(_ status: PoolDevice.Status, expiresIn: TimeInterval? = nil, shutdownIn: TimeInterval? = nil) -> DeviceInfo {
        DeviceInfo(
            name: "amber-falcon", udid: nil, status: status, state: "Booted", model: "iPhone 18 Pro", os: "27.2", holder: nil, leaseId: nil,
            acquiredAt: nil, expiresAt: expiresIn.map { Date().addingTimeInterval($0) }, lastActivityAt: Date(),
            shutdownAt: shutdownIn.map { Date().addingTimeInterval($0) })
    }

    @Test func nextSaysWhatHappensToTheDevice() {
        #expect(Format.next(Self.device(.leased, expiresIn: 28 * 60 + 5)) == "expires in 28m")
        #expect(Format.next(Self.device(.leased, expiresIn: -1)) == "expired")
        #expect(Format.next(Self.device(.available, shutdownIn: 12 * 60 + 5)) == "shutdown in 12m")
        #expect(Format.next(Self.device(.available, shutdownIn: -1)) == "shutdown due")
        #expect(Format.next(Self.device(.available)) == "-")
        #expect(Format.next(Self.device(.provisioning)) == "-")
        // Bound to a `simctlhouse run`: held as long as that process runs, whatever its expiry says.
        var bound = Self.device(.leased, expiresIn: 28 * 60)
        bound.ownerPid = 4242
        #expect(Format.next(bound) == "until pid 4242 exits")
    }

    @Test func releaseSaysHowLongTheDeviceStaysWarm() {
        // Just released: the stored time lost its fraction, so it shows the full idle time.
        #expect(
            Format.released(Self.device(.available, shutdownIn: 60 - 0.7), idleShutdown: 60)
                == "Released amber-falcon. It stays booted for 1m for the next agent.")
        #expect(Format.released(Self.device(.available, shutdownIn: 0), idleShutdown: 0) == "Released amber-falcon. It shuts down now.")
        // Already free: release changes nothing, so it counts down to the stored time.
        #expect(
            Format.released(Self.device(.available, shutdownIn: 5 * 60), idleShutdown: 15 * 60)
                == "Released amber-falcon. It stays booted for 5m for the next agent.")
        #expect(Format.released(Self.device(.available), idleShutdown: 15 * 60) == "Released amber-falcon.")
    }

    @Test(
        arguments: [
            ("7d", 7 * 24 * 3600.0), ("12h", 12 * 3600), ("30m", 30 * 60), ("45s", 45), ("0", 0), ("0d", 0),
        ] as [(String, TimeInterval)])
    func unusedAgesParse(argument: String, seconds: TimeInterval) throws {
        #expect(try #require(Delete.Age(argument: argument)).seconds == seconds)
    }

    @Test(arguments: ["7", "7w", "d", "-1d", "1.5d", ""])
    func malformedAgesAreRejected(argument: String) {
        #expect(Delete.Age(argument: argument) == nil)
    }

    @Test func ageShowsTheLargestWholeUnit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Format.age(since: now.addingTimeInterval(-9.5 * 24 * 3600), now: now) == "9d")
        #expect(Format.age(since: now.addingTimeInterval(-5 * 3600 - 59), now: now) == "5h")
        #expect(Format.age(since: now.addingTimeInterval(-12 * 60), now: now) == "12m")
        #expect(Format.age(since: now.addingTimeInterval(-30), now: now) == "30s")
    }

    @Test func theUninstallPlanNamesLeasedDevicesAndEverythingElse() {
        let plan = UninstallPlan(
            devices: [
                .init(name: "wild-dragon", holder: "fix login", isLeased: true, bytes: 2_400_000_000),
                .init(name: "plucky-papaya", holder: nil, isLeased: false, bytes: 17_000_000),
            ],
            links: [SkillLink(path: "/Users/x/.claude/skills/simctlhouse", target: nil, status: .linked)],
            daemonRunning: true, home: URL(fileURLWithPath: "/Users/x/.simctlhouse"), homeExists: true)
        let text = Format.uninstallPlan(plan)
        #expect(text.contains("  2 simctlhouse simulators, \(Format.bytes(2_417_000_000))"))
        #expect(text.contains("    wild-dragon is leased by \"fix login\""))
        #expect(!text.contains("plucky-papaya is leased"))
        #expect(text.contains("the background daemon, which is running"))
        #expect(text.contains("the skill link /Users/x/.claude/skills/simctlhouse"))
        #expect(text.hasSuffix("Your own simulators and the simctlhouse binary stay."))
    }

    @Test func anEmptyUninstallPlanSaysSo() {
        let plan = UninstallPlan(devices: [], links: [], daemonRunning: false, home: URL(fileURLWithPath: "/x"), homeExists: false)
        #expect(Format.uninstallPlan(plan).contains("nothing; simctlhouse left nothing behind"))
    }

    @Test func theBinaryHintFollowsHowItWasInstalled() {
        #expect(
            Format.removeBinaryHint(executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/simctlhouse/0.2.0/bin/simctlhouse")).hasSuffix(
                "brew uninstall simctlhouse"))
        #expect(Format.removeBinaryHint(executable: URL(fileURLWithPath: "/usr/local/bin/simctlhouse")).hasSuffix("rm /usr/local/bin/simctlhouse"))
    }

    @Test func unusedSummaryCountsAndTotals() {
        let device = UnusedDevice(name: "wild-dragon", udid: nil, lastUsedAt: Date(), bytes: 2_400_000_000)
        #expect(Format.unusedSummary([device, device], age: .week, dryRun: false) == "Deleted 2 devices, freed \(Format.bytes(4_800_000_000)).")
        #expect(Format.unusedSummary([device], age: .week, dryRun: true) == "Would delete 1 device, freeing \(Format.bytes(2_400_000_000)).")
        #expect(Format.unusedSummary([], age: .week, dryRun: false) == "No free device has been unused for 7d.")
        #expect(Format.unusedSummary([], age: Delete.Age(argument: "0")!, dryRun: false) == "No free device to delete.")
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

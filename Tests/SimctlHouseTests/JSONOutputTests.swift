import Foundation
import Testing
@testable import SimctlHouseCore
@testable import simctlhouse

/// `--json` output is API: the skill and how-to tell scripts to read `udid`, `leaseId`, `expiresAt` and `shutdownAt`,
/// and the smoke test matches `"running" : true`. Renaming a field or changing a date format breaks them.
@Suite struct JSONOutputTests {
    static let acquiredAt = Date(timeIntervalSince1970: 1_793_037_600)  // 2026-10-26T18:00:00Z

    @Test func aLeasedDevice() throws {
        let device = DeviceInfo(
            name: "amber-falcon", udid: "E1B5E4F7-1356-4DBA-9D3C-CC2F5807D95B", status: .leased, state: "Booted", model: "iPhone 18 Pro",
            os: "27.2", holder: "agent-42", leaseId: "4f0c", acquiredAt: Self.acquiredAt, expiresAt: Self.acquiredAt.addingTimeInterval(30 * 60),
            lastActivityAt: Self.acquiredAt)
        #expect(
            try Runtime.json(device) == """
                {
                  "acquiredAt" : "2026-10-26T18:00:00Z",
                  "expiresAt" : "2026-10-26T18:30:00Z",
                  "holder" : "agent-42",
                  "lastActivityAt" : "2026-10-26T18:00:00Z",
                  "leaseId" : "4f0c",
                  "model" : "iPhone 18 Pro",
                  "name" : "amber-falcon",
                  "os" : "27.2",
                  "state" : "Booted",
                  "status" : "leased",
                  "udid" : "E1B5E4F7-1356-4DBA-9D3C-CC2F5807D95B"
                }
                """)
    }

    @Test func aFreeDeviceLeavesOutTheLeaseFields() throws {
        let device = DeviceInfo(
            name: "amber-falcon", udid: "E1B5E4F7-1356-4DBA-9D3C-CC2F5807D95B", status: .available, state: "Shutdown", model: "iPhone 18 Pro",
            os: "27.2", holder: nil, leaseId: nil, acquiredAt: nil, expiresAt: nil, lastActivityAt: Self.acquiredAt)
        #expect(
            try Runtime.json(device) == """
                {
                  "lastActivityAt" : "2026-10-26T18:00:00Z",
                  "model" : "iPhone 18 Pro",
                  "name" : "amber-falcon",
                  "os" : "27.2",
                  "state" : "Shutdown",
                  "status" : "available",
                  "udid" : "E1B5E4F7-1356-4DBA-9D3C-CC2F5807D95B"
                }
                """)
    }

    @Test func aFreeBootedDeviceSaysWhenItShutsDown() throws {
        let device = DeviceInfo(
            name: "amber-falcon", udid: "E1B5E4F7-1356-4DBA-9D3C-CC2F5807D95B", status: .available, state: "Booted", model: "iPhone 18 Pro",
            os: "27.2", holder: nil, leaseId: nil, acquiredAt: nil, expiresAt: nil, lastActivityAt: Self.acquiredAt,
            shutdownAt: Self.acquiredAt.addingTimeInterval(15 * 60))
        #expect(
            try Runtime.json(device) == """
                {
                  "lastActivityAt" : "2026-10-26T18:00:00Z",
                  "model" : "iPhone 18 Pro",
                  "name" : "amber-falcon",
                  "os" : "27.2",
                  "shutdownAt" : "2026-10-26T18:15:00Z",
                  "state" : "Booted",
                  "status" : "available",
                  "udid" : "E1B5E4F7-1356-4DBA-9D3C-CC2F5807D95B"
                }
                """)
    }

    @Test func unusedDevices() throws {
        let device = UnusedDevice(name: "wild-dragon", udid: "74592BC9-F43A-4248-86E0-A313AB85D16B", lastUsedAt: Self.acquiredAt, bytes: 2_499_124_000)
        #expect(
            try Runtime.json([device]) == """
                [
                  {
                    "bytes" : 2499124000,
                    "lastUsedAt" : "2026-10-26T18:00:00Z",
                    "name" : "wild-dragon",
                    "udid" : "74592BC9-F43A-4248-86E0-A313AB85D16B"
                  }
                ]
                """)
    }

    @Test func gcReport() throws {
        let report = GCReport(reclaimed: ["ready-lion"], shutDown: ["amber-falcon"], forgotten: [], recovered: [])
        #expect(
            try Runtime.json(report) == """
                {
                  "forgotten" : [

                  ],
                  "reclaimed" : [
                    "ready-lion"
                  ],
                  "recovered" : [

                  ],
                  "shutDown" : [
                    "amber-falcon"
                  ]
                }
                """)
    }

    @Test func daemonStatus() throws {
        #expect(
            try Runtime.json(DaemonStatus(running: false)) == """
                {
                  "running" : false
                }
                """)
        let build = DaemonBuild(executable: "/opt/homebrew/Cellar/simctlhouse/0.2.0/bin/simctlhouse", inode: 7, modifiedAt: 1_793_037_000)
        let record = DaemonRecord(
            pid: 4242, processStartedAt: Self.acquiredAt, startedAt: Self.acquiredAt, version: "0.2.0", build: build,
            keepAliveUntil: Self.acquiredAt.addingTimeInterval(30 * 60))
        #expect(
            try Runtime.json(DaemonStatus(running: true, daemon: record, isCurrentBuild: true)) == """
                {
                  "daemon" : {
                    "build" : {
                      "executable" : "/opt/homebrew/Cellar/simctlhouse/0.2.0/bin/simctlhouse",
                      "inode" : 7,
                      "modifiedAt" : 1793037000
                    },
                    "keepAliveUntil" : "2026-10-26T18:30:00Z",
                    "pid" : 4242,
                    "processStartedAt" : "2026-10-26T18:00:00Z",
                    "startedAt" : "2026-10-26T18:00:00Z",
                    "version" : "0.2.0"
                  },
                  "isCurrentBuild" : true,
                  "running" : true
                }
                """)
    }
}

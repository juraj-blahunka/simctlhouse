import Foundation
import Testing
@testable import SimctlHouseCore

@Suite struct PoolTests {
    let h = Harness()

    @Test func acquireCreatesAndBootsADevice() throws {
        let first = try h.pool.acquire(AcquireRequest(spec: DeviceSpec(), holder: "agent-1"))
        #expect(first.status == .leased)
        #expect(first.state == "Booted")
        #expect(first.holder == "agent-1")
        #expect(first.model == "iPhone 18 Pro")
        #expect(first.expiresAt == h.clock.now.addingTimeInterval(30 * 60))

        let second = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(second.udid != first.udid)
        #expect(h.backend.callCount(prefix: "create") == 2)
    }

    @Test func releasedDeviceIsReusedStillBooted() throws {
        let first = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(first.name)
        let again = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(again.udid == first.udid)
        #expect(h.backend.callCount(prefix: "create") == 1)
        #expect(h.backend.callCount(prefix: "shutdown") == 0)
        #expect(h.backend.device(again.udid)?.state == "Booted")
    }

    @Test func acquirePrefersBootedDevices() throws {
        let a = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        let b = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(a.name)
        h.clock.advance(minutes: 1)
        try h.pool.release(b.name)
        h.backend.setState(b.udid!, "Shutdown")
        #expect(try h.pool.acquire(AcquireRequest(spec: DeviceSpec())).udid == a.udid)
    }

    @Test func doesNotReuseDeviceOfADifferentSpec() throws {
        let phone = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(phone.name)
        let pad = try h.pool.acquire(AcquireRequest(spec: DeviceSpec(family: .ipad)))
        #expect(pad.udid != phone.udid)
        #expect(pad.model == "iPad Pro 11-inch (M5)")
    }

    @Test func neverTouchesDevicesItDidNotCreate() throws {
        let foreign = h.backend.addForeignDevice(name: "iPhone 18 Pro", booted: true)
        let acquired = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(acquired.udid != foreign)
        #expect(throws: SimctlHouseError.deviceNotFound(foreign)) { try h.pool.release(foreign) }
        #expect(throws: SimctlHouseError.deviceNotFound(foreign)) { try h.pool.delete([foreign], force: true) }
        h.clock.advance(minutes: 120)
        try h.pool.collectGarbage()
        #expect(h.backend.device(foreign)?.state == "Booted")
    }

    @Test func skipsFreeDeviceUsedByAnotherProcess() throws {
        let first = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(first.name)
        h.scanner.set(["/usr/bin/xcodebuild test -destination id=\(first.udid!.lowercased())"])
        let second = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(second.udid != first.udid)
    }

    @Test func ignoresSimulatorOwnProcessesAndSimctlhouse() throws {
        let first = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(first.name)
        h.scanner.set([
            "launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(first.udid!)/data/var/run/launchd_bootstrap.plist",
            "/usr/local/bin/simctlhouse release \(first.udid!)",
        ])
        #expect(try h.pool.acquire(AcquireRequest(spec: DeviceSpec())).udid == first.udid)
    }

    @Test func otherToolsMentioningSimctlhouseStillCountAsForeignUse() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(device.name)
        h.scanner.set(["/usr/bin/xcodebuild -project /Users/me/src/simctlhouse-demo/App.xcodeproj -destination id=\(device.udid!)"])
        #expect(try h.pool.collectGarbage(shutDownAllFree: true).shutDown.isEmpty)
        #expect(h.backend.device(device.udid)?.state == "Booted")
    }

    @Test func releaseRules() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(throws: SimctlHouseError.leaseMismatch(device: device.name)) { try h.pool.release(device.name, leaseId: "nope") }
        #expect(throws: SimctlHouseError.deviceNotFound("ghost-town")) { try h.pool.release("ghost-town") }
        let released = try h.pool.release(device.udid!.lowercased(), leaseId: device.leaseId)
        #expect(released.status == .available)
        #expect(released.state == "Booted")
        // Idempotent: releasing twice is fine.
        #expect(try h.pool.release(device.name).status == .available)
    }

    @Test func expiredLeaseIsReclaimedUnderANewNameAndErased() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        h.clock.advance(minutes: 29)
        try h.pool.collectGarbage()
        #expect(try h.state().devices.first?.status == .leased)

        h.clock.advance(minutes: 2)
        let report = try h.pool.collectGarbage()
        #expect(report.reclaimed == [device.name])
        let after = try #require(try h.state().devices.first)
        #expect(after.status == .available)
        #expect(after.name != device.name)
        #expect(after.udid != device.udid)
        #expect(after.lease == nil)
        #expect(h.backend.device(device.udid) == nil)
        #expect(h.backend.device(after.udid)?.state == "Shutdown")
        // The stale agent can no longer reach the device by name or UDID.
        #expect(throws: SimctlHouseError.deviceNotFound(device.name)) { try h.pool.release(device.name) }
        #expect(throws: SimctlHouseError.deviceNotFound(device.udid!)) { try h.pool.renew(device.udid!) }
    }

    @Test func renewExtendsTheLease() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        h.clock.advance(minutes: 25)
        let renewed = try h.pool.renew(device.name, leaseId: device.leaseId)
        #expect(renewed.expiresAt == h.clock.now.addingTimeInterval(30 * 60))
        h.clock.advance(minutes: 25)
        #expect(try h.pool.collectGarbage().reclaimed.isEmpty)
        try h.pool.release(device.name)
        #expect(throws: SimctlHouseError.notLeased(device: device.name)) { try h.pool.renew(device.name) }
    }

    @Test func idleFreeDevicesShutDownAfter15Minutes() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(device.name)
        h.clock.advance(minutes: 14)
        #expect(try h.pool.collectGarbage().shutDown.isEmpty)
        h.clock.advance(minutes: 1)
        #expect(try h.pool.collectGarbage().shutDown == [device.name])
        let after = try #require(try h.state().devices.first)
        #expect(after.status == .available)
        #expect(after.udid == device.udid)
        #expect(h.backend.device(device.udid)?.state == "Shutdown")
    }

    @Test func configuredTimeoutsApply() throws {
        let config = try PoolConfig.fromEnvironment(["SIMCTLHOUSE_LEASE_SECONDS": "120", "SIMCTLHOUSE_IDLE_SECONDS": "0"])
        let pool = h.pool(config: config)
        let device = try pool.acquire(AcquireRequest())
        #expect(device.expiresAt == h.clock.now.addingTimeInterval(120))
        try pool.release(device.name)
        // An idle timeout of 0 shuts a released device down on the very next command.
        #expect(try pool.collectGarbage().shutDown == [device.name])
    }

    @Test func idleShutdownSparesDevicesInForeignUse() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(device.name)
        h.scanner.set(["xcrun simctl install \(device.udid!) App.app"])
        h.clock.advance(minutes: 20)
        #expect(try h.pool.collectGarbage().shutDown.isEmpty)
        #expect(try h.pool.collectGarbage(shutDownAllFree: true).shutDown.isEmpty)
        #expect(h.backend.device(device.udid)?.state == "Booted")
    }

    @Test func leasedDevicesAreNeverShutDown() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        h.clock.advance(minutes: 20)
        #expect(try h.pool.collectGarbage().shutDown.isEmpty)
        #expect(try h.pool.collectGarbage(shutDownAllFree: true).shutDown.isEmpty)
        #expect(h.backend.device(device.udid)?.state == "Booted")
    }

    @Test func gcCommandShutsDownEveryFreeDeviceRightAway() throws {
        let devices = try (0..<4).map { _ in try h.pool.acquire(AcquireRequest()) }
        for device in devices.dropLast() { try h.pool.release(device.name) }
        #expect(try h.pool.collectGarbage().shutDown.isEmpty)
        let report = try h.pool.collectGarbage(shutDownAllFree: true)
        #expect(Set(report.shutDown) == Set(devices.dropLast().map(\.name)))
        #expect(try h.pool.list().map(\.state) == ["Shutdown", "Shutdown", "Shutdown", "Booted"])
    }

    @Test func listReportsStateAfterGCChangedIt() throws {
        let device = try h.pool.acquire(AcquireRequest())
        try h.pool.release(device.name)
        #expect(try h.pool.list().map(\.state) == ["Booted"])
        h.clock.advance(minutes: 15)
        // This list's GC shuts the device down, so it must not show GC's earlier snapshot.
        #expect(try h.pool.list().map(\.state) == ["Shutdown"])
    }

    @Test func forgetsDevicesDeletedBehindOurBack() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        h.backend.removeBehindOurBack(device.udid!)
        #expect(try h.pool.collectGarbage().forgotten == [device.name])
        #expect(try h.state().devices.isEmpty)
    }

    @Test func recoversFromAbandonedProvisioning() throws {
        let name = "brave-otter"
        try StateStore(paths: HousePaths(root: h.root)).transaction { state in
            state.devices.append(
                PoolDevice(
                    name: name, udid: nil, deviceTypeIdentifier: "type.iPhone-18-Pro", runtimeIdentifier: "rt.iOS-27-0", status: .provisioning, now: h.clock.now
                ))
        }
        let orphan = h.backend.addForeignDevice(name: name, booted: false)
        h.clock.advance(minutes: 5)
        #expect(try h.pool.collectGarbage().forgotten.isEmpty)
        h.clock.advance(minutes: 6)
        #expect(try h.pool.collectGarbage().forgotten == [name])
        #expect(h.backend.device(orphan) == nil)
    }

    @Test func failedBootDropsTheDevice() throws {
        h.backend.failBoot = true
        #expect(throws: (any Error).self) { try h.pool.acquire(AcquireRequest(spec: DeviceSpec())) }
        #expect(try h.state().devices.isEmpty)
    }

    @Test func createAddsAFreeShutDownDevice() throws {
        let created = try h.pool.create(DeviceSpec(family: .ipad))
        #expect(created.status == .available)
        #expect(created.state == "Shutdown")
        let acquired = try h.pool.acquire(AcquireRequest(spec: DeviceSpec(family: .ipad)))
        #expect(acquired.udid == created.udid)
    }

    @Test func deleteRefusesLeasedDevicesWithoutForce() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec(), holder: "agent-7"))
        #expect(throws: SimctlHouseError.deviceLeased(device: device.name, holder: "agent-7")) { try h.pool.delete([device.name], force: false) }
        #expect(try h.pool.delete([device.name], force: true) == [device.name])
        #expect(h.backend.device(device.udid) == nil)
        #expect(try h.state().devices.isEmpty)
    }

    @Test func deleteAllRemovesEveryDevice() throws {
        _ = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        _ = try h.pool.create(DeviceSpec())
        #expect(try h.pool.deleteAll(force: true).count == 2)
        #expect(try h.state().devices.isEmpty)
        #expect(try h.backend.devices().isEmpty)
    }

    @Test func resetErasesInPlaceKeepingNameAndUDID() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(throws: SimctlHouseError.deviceLeased(device: device.name, holder: nil)) { try h.pool.reset(device.name, force: false) }
        try h.pool.release(device.name)
        let reset = try h.pool.reset(device.name, force: false)
        #expect(reset.name == device.name)
        #expect(reset.udid == device.udid)
        #expect(reset.state == "Shutdown")
        #expect(reset.status == .available)
        #expect(h.backend.callCount(prefix: "erase") == 1)
        #expect(h.backend.callCount(prefix: "delete") == 0)
        #expect(h.backend.callCount(prefix: "create") == 1)
    }

    @Test func resetOfAVanishedDeviceFailsAndGCRetiresIt() throws {
        let device = try h.pool.create(DeviceSpec())
        h.backend.failErase = true
        #expect(throws: (any Error).self) { try h.pool.reset(device.name, force: false) }
        #expect(try h.state().devices.first?.status == .available)
        h.backend.removeBehindOurBack(device.udid!)
        #expect(try h.pool.collectGarbage().forgotten == [device.name])
    }

    @Test func concurrentAcquiresNeverShareADevice() async throws {
        let pool = h.pool
        let udids = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask { try pool.acquire(AcquireRequest(spec: DeviceSpec(), holder: "agent-\(index)")).udid! }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(udids).count == 8)
        #expect(h.backend.callCount(prefix: "create") == 8)
        #expect(try h.state().devices.allSatisfy { $0.status == .leased })
    }

    // MARK: - acquire / list by name or UDID

    @Test func acquireLeasesASpecificDeviceByNameOrUDID() throws {
        let a = try h.pool.create(DeviceSpec())
        let b = try h.pool.create(DeviceSpec())
        #expect(try h.pool.acquire(AcquireRequest(device: b.name, holder: "me")).udid == b.udid)
        #expect(try h.pool.acquire(AcquireRequest(device: a.udid!.lowercased())).udid == a.udid)
        #expect(h.backend.callCount(prefix: "create") == 2)
    }

    @Test func acquireOfASpecificDeviceRefusesWhenNotFree() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "agent-1"))
        #expect(throws: SimctlHouseError.deviceLeased(device: device.name, holder: "agent-1")) {
            try h.pool.acquire(AcquireRequest(device: device.name))
        }
        try h.pool.release(device.name)
        h.scanner.set(["/usr/bin/xcodebuild test -destination id=\(device.udid!)"])
        #expect(throws: SimctlHouseError.deviceInUse(device: device.name)) { try h.pool.acquire(AcquireRequest(device: device.name)) }
        #expect(throws: SimctlHouseError.deviceNotFound("ghost-town")) { try h.pool.acquire(AcquireRequest(device: "ghost-town")) }
        #expect(try h.state().devices.map(\.status) == [.available])
    }

    @Test func udidResolvesANameOrUDID() throws {
        let device = try h.pool.create(DeviceSpec())
        #expect(try h.pool.udid(of: device.name) == device.udid)
        #expect(try h.pool.udid(of: device.udid!.lowercased()) == device.udid)
        #expect(throws: SimctlHouseError.deviceNotFound("ghost-town")) { try h.pool.udid(of: "ghost-town") }
    }

    @Test func udidOfADeviceBeingCreatedIsBusy() throws {
        try StateStore(paths: HousePaths(root: h.root)).transaction { state in
            state.devices.append(
                PoolDevice(
                    name: "brave-otter", udid: nil, deviceTypeIdentifier: "type.iPhone-18-Pro", runtimeIdentifier: "rt.iOS-27-0", status: .provisioning,
                    now: h.clock.now))
        }
        #expect(throws: SimctlHouseError.deviceBusy(device: "brave-otter", status: .provisioning)) { try h.pool.udid(of: "brave-otter") }
    }

    @Test func listFiltersByNameOrUDID() throws {
        let a = try h.pool.create(DeviceSpec())
        let b = try h.pool.create(DeviceSpec(family: .ipad))
        #expect(try h.pool.list().count == 2)
        #expect(try h.pool.list([b.udid!]).map(\.name) == [b.name])
        #expect(try h.pool.list([b.name, a.name]).map(\.name) == [b.name, a.name])
        #expect(throws: SimctlHouseError.deviceNotFound("ghost-town")) { try h.pool.list(["ghost-town"]) }
    }

    // MARK: - history

    @Test func historyRecordsHolderAcquireAndRelease() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "agent-1", pid: 42, cwd: "/src/app"))
        let acquiredAt = h.clock.now
        h.clock.advance(minutes: 10)
        try h.pool.renew(device.name)
        h.clock.advance(minutes: 5)
        try h.pool.release(device.name)

        let history = try #require(try h.pool.history(device.name).first)
        let lease = try #require(history.leases.first)
        #expect(history.leases.count == 1)
        #expect(history.retiredAt == nil)
        #expect(lease.holder == "agent-1")
        #expect(lease.pid == 42)
        #expect(lease.cwd == "/src/app")
        #expect(lease.udid == device.udid)
        #expect(lease.leaseId == device.leaseId)
        #expect(lease.acquiredAt == acquiredAt)
        #expect(lease.endedAt == h.clock.now)
        #expect(lease.outcome == .released)
    }

    @Test func historyShowsTheActiveLeaseLast() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "first"))
        try h.pool.release(device.name)
        _ = try h.pool.acquire(AcquireRequest(device: device.name, holder: "second"))
        let leases = try #require(try h.pool.history(device.udid!).first).leases
        #expect(leases.map(\.holder) == ["first", "second"])
        #expect(leases.map(\.outcome) == [.released, nil])
        #expect(leases.last?.endedAt == nil)
    }

    @Test func historyKeepsTheLastFiveLeases() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "agent-0"))
        try h.pool.release(device.name)
        for index in 1...6 {
            _ = try h.pool.acquire(AcquireRequest(device: device.name, holder: "agent-\(index)"))
            try h.pool.release(device.name)
        }
        let leases = try #require(try h.pool.history(device.name).first).leases
        #expect(leases.map(\.holder) == (2...6).map { "agent-\($0)" })
    }

    @Test func expiredDeviceIsStillInHistoryUnderItsOldNameAndUDID() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "slow-agent"))
        h.clock.advance(minutes: 31)
        try h.pool.collectGarbage()
        let renamed = try #require(try h.state().devices.first)

        for ref in [device.name, device.udid!] {
            let history = try #require(try h.pool.history(ref).first)
            #expect(history.name == device.name)
            #expect(history.retiredReason == .expired)
            #expect(history.leases.map(\.holder) == ["slow-agent"])
            #expect(history.leases.map(\.outcome) == [.expired])
        }
        // The erased device starts with a clean slate under its new name.
        #expect(try h.pool.history(renamed.name).first?.leases.isEmpty == true)
        #expect(try h.pool.history().map(\.name) == [device.name, renamed.name])
    }

    @Test func vanishedAndDeletedDevicesStayInHistory() throws {
        let vanished = try h.pool.acquire(AcquireRequest(holder: "victim"))
        let deleted = try h.pool.acquire(AcquireRequest(holder: "owner"))
        h.backend.removeBehindOurBack(vanished.udid!)
        try h.pool.delete([deleted.name], force: true)

        let lost = try #require(try h.pool.history(vanished.name).first)
        #expect(lost.retiredReason == .vanished)
        #expect(lost.leases.map(\.outcome) == [.vanished])
        let gone = try #require(try h.pool.history(deleted.udid!).first)
        #expect(gone.retiredReason == .deleted)
        #expect(gone.leases.map(\.outcome) == [.deleted])
        #expect(throws: SimctlHouseError.deviceNotFound("ghost-town")) { try h.pool.history("ghost-town") }
    }

    @Test func forcedResetEndsTheLease() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "agent-1"))
        try h.pool.reset(device.name, force: true)
        let history = try #require(try h.pool.history(device.udid!).first)
        #expect(history.name == device.name)
        #expect(history.leases.map(\.outcome) == [.reset])
        #expect(try h.state().devices.first?.lease == nil)
    }

    @Test func retiredDevicesAreCapped() throws {
        for _ in 0..<(PoolState.retiredLimit + 3) {
            let device = try h.pool.create(DeviceSpec())
            try h.pool.delete([device.name], force: false)
        }
        #expect(try h.state().retired.count == PoolState.retiredLimit)
    }

    @Test func newNamesDoNotReuseRetiredOnes() throws {
        let device = try h.pool.create(DeviceSpec())
        try h.pool.delete([device.name], force: false)
        #expect(try h.state().retired.map(\.name) == [device.name])
        for _ in 0..<20 { #expect(try h.pool.create(DeviceSpec()).name != device.name) }
    }
}

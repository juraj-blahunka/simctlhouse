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

    @Test func leaseStartsOnceTheDeviceHasBooted() throws {
        h.backend.onBoot = { [unowned h] in
            h.backend.onBoot = nil
            h.clock.advance(minutes: 10)
        }
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(device.expiresAt == h.clock.now.addingTimeInterval(PoolConfig().leaseDuration))
    }

    @Test func bootOutlastingTheLeaseFailsLikeAStaleAgent() throws {
        h.backend.onBoot = { [unowned h] in
            h.backend.onBoot = nil
            h.clock.advance(minutes: 31)
            #expect((try? h.pool.collectGarbage())?.reclaimed.count == 1)
        }
        let error = try #require(throws: SimctlHouseError.self) { try h.pool.acquire(AcquireRequest(spec: DeviceSpec())) }
        #expect(error.exitCode == 3)
        let record = try #require(try h.state().devices.first)
        #expect(record.status == .available)
        #expect(record.lease == nil)
        #expect(try h.backend.devices().count == 1)
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

    @Test func aFreeBootedDeviceShowsWhenItShutsDown() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(device.shutdownAt == nil)
        h.clock.advance(minutes: 5)
        let released = try h.pool.release(device.name)
        #expect(released.shutdownAt == h.clock.now.addingTimeInterval(15 * 60))
        h.clock.advance(minutes: 15)
        try h.pool.collectGarbage()
        let shutDown = try #require(try h.pool.list().first)
        #expect(shutDown.state == "Shutdown")
        #expect(shutDown.shutdownAt == nil)
    }

    @Test func foreignUsePostponesTheShutdown() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(device.name)
        h.scanner.set(["xcrun simctl install \(device.udid!) App.app"])
        h.clock.advance(minutes: 20)
        #expect(try h.pool.list().first?.shutdownAt == h.clock.now.addingTimeInterval(15 * 60))
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

    @Test func failedBootDropsTheDevice() throws {
        h.backend.failBoot = true
        #expect(throws: (any Error).self) { try h.pool.acquire(AcquireRequest(spec: DeviceSpec(), holder: "agent-1")) }
        #expect(try h.state().devices.isEmpty)
        #expect(try h.backend.devices().isEmpty)
        let retired = try #require(try h.state().retired.last)
        #expect(retired.reason == .failed)
        #expect(retired.history.map(\.outcome) == [.failed])
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

    @Test func failedDeleteHandsTheDeviceBackAndDeletesTheRest() throws {
        let stuck = try h.pool.acquire(AcquireRequest(spec: DeviceSpec(), holder: "agent-1"))
        let other = try h.pool.create(DeviceSpec())
        h.backend.failDelete = [stuck.name]
        #expect(throws: (any Error).self) { try h.pool.delete([stuck.name, other.name], force: true) }
        #expect(h.backend.device(other.udid) == nil)
        let record = try #require(try h.state().devices.first)
        #expect(try h.state().devices.count == 1)
        #expect(record.name == stuck.name)
        #expect(record.status == .leased)
        #expect(record.lease?.holder == "agent-1")
        #expect(record.history.isEmpty)
    }

    @Test func deleteNamesEachDeviceOnce() throws {
        let device = try h.pool.create(DeviceSpec())
        #expect(try h.pool.delete([device.name, device.udid!], force: false) == [device.name])
        #expect(h.backend.callCount(prefix: "delete") == 1)
    }

    @Test func deleteAllRemovesEveryDevice() throws {
        _ = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        _ = try h.pool.create(DeviceSpec())
        #expect(try h.pool.deleteAll(force: true).count == 2)
        #expect(try h.state().devices.isEmpty)
        #expect(try h.backend.devices().isEmpty)
    }

    @Test func eraseKeepsNameAndUDID() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(throws: SimctlHouseError.deviceLeased(device: device.name, holder: nil)) { try h.pool.erase(device.name, force: false) }
        try h.pool.release(device.name)
        let erased = try h.pool.erase(device.name, force: false)
        #expect(erased.name == device.name)
        #expect(erased.udid == device.udid)
        #expect(erased.state == "Shutdown")
        #expect(erased.status == .available)
        #expect(h.backend.callCount(prefix: "erase") == 1)
        #expect(h.backend.callCount(prefix: "delete") == 0)
        #expect(h.backend.callCount(prefix: "create") == 1)
    }

    @Test func failedEraseReturnsTheDeviceAndGCRetiresItIfGone() throws {
        let device = try h.pool.create(DeviceSpec())
        h.backend.failErase = true
        #expect(throws: (any Error).self) { try h.pool.erase(device.name, force: false) }
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

    @Test func listFiltersLikeSimctl() throws {
        let leased = try h.pool.acquire(AcquireRequest(holder: "agent-7"))
        let phone = try h.pool.create(DeviceSpec())
        let pad = try h.pool.create(DeviceSpec(family: .ipad))
        func names(_ arguments: String...) throws -> [String] { try h.pool.list(DeviceFilter(arguments)).map(\.name) }

        #expect(try names() == [leased.name, phone.name, pad.name])
        #expect(try names(pad.udid!.lowercased()) == [pad.name])
        #expect(try names(pad.name, phone.name) == [phone.name, pad.name])
        #expect(try names("ipad") == [pad.name])
        #expect(try names("iOS 27.0", "ghost") == [leased.name, phone.name, pad.name])
        #expect(try names("AGENT-7") == [leased.name])
        #expect(try names("booted") == [leased.name])
        #expect(try names("Shutdown", "available") == [phone.name, pad.name])
        #expect(try names("available", "ipad") == [pad.name])
        #expect(try names("leased", "ipad").isEmpty)
        #expect(try names("ghost-town").isEmpty)
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

    // MARK: - delete --unused

    static let week: TimeInterval = 7 * 24 * 3600

    @Test func deletesFreeDevicesUnusedForAWeek() throws {
        let old = try h.pool.acquire(AcquireRequest())
        let recent = try h.pool.acquire(AcquireRequest())
        try h.pool.release(old.name)
        try h.pool.release(recent.name)
        h.clock.advance(minutes: 24 * 60)
        _ = try h.pool.acquire(AcquireRequest(device: recent.name))
        try h.pool.release(recent.name)
        h.clock.advance(minutes: 6 * 24 * 60)
        let announced = Messages()
        let deleted = try h.pool.deleteUnused(age: Self.week) { announced.append($0.name) }
        #expect(deleted.map(\.name) == [old.name])
        #expect(announced.all == [old.name])
        #expect(deleted.first?.bytes == 2_400_000_000)
        #expect(deleted.first?.lastUsedAt == h.clock.now.addingTimeInterval(-Self.week))
        #expect(!h.backend.existsOnDisk(udid: old.udid!))
        #expect(try h.pool.history(old.name).first?.retiredReason == .deleted)
        #expect(try h.state().devices.map(\.name) == [recent.name])
    }

    @Test func anAcquireOrRenewCountsAsUse() throws {
        let device = try h.pool.acquire(AcquireRequest())
        try h.pool.release(device.name)
        h.clock.advance(minutes: 6 * 24 * 60)
        _ = try h.pool.acquire(AcquireRequest())
        h.clock.advance(minutes: 20)
        _ = try h.pool.renew(device.name)
        try h.pool.release(device.name)
        h.clock.advance(minutes: 3 * 24 * 60)
        #expect(try h.pool.deleteUnused(age: Self.week).isEmpty)
    }

    @Test func neverDeletesLeasedOrForeignUsedDevices() throws {
        // A lease long enough to outlast the ten days below.
        var config = PoolConfig()
        config.leaseDuration = 30 * 24 * 3600
        let pool = h.pool(config: config)
        let leased = try pool.acquire(AcquireRequest())
        let foreign = try pool.acquire(AcquireRequest())
        try pool.release(foreign.name)
        h.scanner.set(["xcodebuild test -destination id=\(foreign.udid!)"])
        h.clock.advance(minutes: 10 * 24 * 60)
        // A 0 age takes every free device that nobody uses.
        #expect(try pool.deleteUnused(age: 0).isEmpty)
        #expect(Set(try h.state().devices.map(\.name)) == [leased.name, foreign.name])
    }

    @Test func aDryRunDeletesNothing() throws {
        let device = try h.pool.acquire(AcquireRequest())
        try h.pool.release(device.name)
        h.clock.advance(minutes: 8 * 24 * 60)
        let wouldGo = try h.pool.deleteUnused(age: Self.week, dryRun: true)
        #expect(wouldGo.map(\.name) == [device.name])
        #expect(wouldGo.first?.bytes == 2_400_000_000)
        #expect(h.backend.existsOnDisk(udid: device.udid!))
        #expect(try h.state().devices.map(\.name) == [device.name])
    }

    @Test func aZeroAgeDeletesEveryFreeDevice() throws {
        let device = try h.pool.acquire(AcquireRequest())
        try h.pool.release(device.name)
        #expect(try h.pool.deleteUnused(age: 0).map(\.name) == [device.name])
    }

    @Test func aDeviceLeftOutOfOneListingIsKept() throws {
        let leased = try h.pool.acquire(AcquireRequest(holder: "agent-1"))
        let free = try h.pool.acquire(AcquireRequest())
        try h.pool.release(free.name)
        // CoreSimulator answers without them once, as while its service restarts; both are still on disk.
        h.backend.setListed(leased.udid!, false)
        h.backend.setListed(free.udid!, false)
        let report = try h.pool.collectGarbage()
        #expect(report.forgotten.isEmpty)
        #expect(try h.state().retired.isEmpty)
        h.backend.setListed(leased.udid!, true)
        h.backend.setListed(free.udid!, true)
        // The next listing has them again, and the lease goes on as before.
        let renewed = try h.pool.renew(leased.name)
        #expect(renewed.udid == leased.udid)
        #expect(renewed.holder == "agent-1")
        #expect(try h.pool.acquire(AcquireRequest()).udid == free.udid)
    }

    @Test func aDeviceMissingFromListingAndDiskStillVanishes() throws {
        let device = try h.pool.acquire(AcquireRequest())
        h.backend.removeBehindOurBack(device.udid!)
        #expect(try h.pool.collectGarbage().forgotten == [device.name])
        #expect(try h.state().retired.last?.reason == .vanished)
    }

    @Test func anUnlistedDeviceIsNotIdleShutDownOrHandedOut() throws {
        let device = try h.pool.acquire(AcquireRequest())
        try h.pool.release(device.name)
        h.backend.setListed(device.udid!, false)
        h.clock.advance(minutes: 20)
        #expect(try h.pool.collectGarbage().shutDown.isEmpty)
        // acquire creates another device instead of handing out one it cannot see.
        #expect(try h.pool.acquire(AcquireRequest()).udid != device.udid)
    }

    @Test func deletingAnUnlistedDeviceStillDeletesItsSimulator() throws {
        let device = try h.pool.acquire(AcquireRequest())
        try h.pool.release(device.name)
        h.backend.setListed(device.udid!, false)
        #expect(try h.pool.delete([device.name], force: false) == [device.name])
        #expect(!h.backend.existsOnDisk(udid: device.udid!))
        #expect(try h.state().retired.last?.reason == .deleted)
    }

    @Test func anExpiredLeaseLeftOutOfTheListingIsReclaimedOnceListed() throws {
        let device = try h.pool.acquire(AcquireRequest())
        h.backend.setListed(device.udid!, false)
        h.clock.advance(minutes: 31)
        #expect(try h.pool.collectGarbage().reclaimed.isEmpty)
        h.backend.setListed(device.udid!, true)
        #expect(try h.pool.collectGarbage().reclaimed.count == 1)
        // The old simulator is deleted, not left behind.
        #expect(!h.backend.existsOnDisk(udid: device.udid!))
    }

    @Test func vanishedAndDeletedDevicesStayInHistory() throws {
        let vanished = try h.pool.acquire(AcquireRequest(holder: "victim"))
        let deleted = try h.pool.acquire(AcquireRequest(holder: "owner"))
        h.backend.removeBehindOurBack(vanished.udid!)
        _ = try h.pool.delete([deleted.name], force: true)

        let lost = try #require(try h.pool.history(vanished.name).first)
        #expect(lost.retiredReason == .vanished)
        #expect(lost.leases.map(\.outcome) == [.vanished])
        let gone = try #require(try h.pool.history(deleted.udid!).first)
        #expect(gone.retiredReason == .deleted)
        #expect(gone.leases.map(\.outcome) == [.deleted])
        #expect(throws: SimctlHouseError.deviceNotFound("ghost-town")) { try h.pool.history("ghost-town") }
    }

    @Test func forcedEraseEndsTheLease() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "agent-1"))
        _ = try h.pool.erase(device.name, force: true)
        let history = try #require(try h.pool.history(device.udid!).first)
        #expect(history.name == device.name)
        #expect(history.leases.map(\.outcome) == [.erased])
        #expect(try h.state().devices.first?.lease == nil)
    }

    @Test func retiredDevicesAreCapped() throws {
        for _ in 0..<(PoolState.retiredLimit + 3) {
            let device = try h.pool.create(DeviceSpec())
            _ = try h.pool.delete([device.name], force: false)
        }
        #expect(try h.state().retired.count == PoolState.retiredLimit)
    }

    @Test func newNamesDoNotReuseRetiredOnes() throws {
        let device = try h.pool.create(DeviceSpec())
        _ = try h.pool.delete([device.name], force: false)
        #expect(try h.state().retired.map(\.name) == [device.name])
        for _ in 0..<20 { #expect(try h.pool.create(DeviceSpec()).name != device.name) }
    }

    // MARK: - claims on provisioning and maintenance

    @Test func slowWorkOfALiveProcessIsNeverTakenOver() throws {
        let device = try h.pool.create(DeviceSpec())
        h.backend.onErase = { [unowned h] in
            h.backend.onErase = nil
            h.clock.advance(minutes: 59)
            #expect((try? h.pool.collectGarbage())?.isEmpty == true)
            #expect((try? h.pool.acquire(AcquireRequest(spec: DeviceSpec(), holder: "agent-2")))?.name != device.name)
        }
        #expect(try h.pool.erase(device.name, force: false).status == .available)
        #expect(h.backend.callCount(prefix: "create") == 2)
    }

    @Test func workRepairedAsHungNeverOverwritesTheNextHolder() throws {
        let device = try h.pool.create(DeviceSpec())
        h.backend.onErase = { [unowned h] in
            h.backend.onErase = nil
            h.clock.advance(minutes: 61)
            #expect((try? h.pool.acquire(AcquireRequest(device: device.name, holder: "agent-2")))?.status == .leased)
        }
        #expect(throws: SimctlHouseError.takenOver(device: device.name)) { try h.pool.erase(device.name, force: false) }
        let record = try #require(try h.state().devices.first)
        #expect(record.status == .leased)
        #expect(record.lease?.holder == "agent-2")
        #expect(record.claim == nil)
    }

    @Test func workOfACrashedProcessIsRepairedRightAway() throws {
        let device = try h.pool.create(DeviceSpec())
        let crashing = h.pool(processID: 4242)
        h.backend.onErase = { [unowned h] in
            h.backend.onErase = nil
            h.scanner.exit(4242)
            #expect((try? h.pool.collectGarbage())?.recovered == [device.name])
        }
        #expect(throws: SimctlHouseError.takenOver(device: device.name)) { try crashing.erase(device.name, force: false) }
        #expect(try h.state().devices.map(\.status) == [.available])
    }

    @Test func recoversFromAbandonedProvisioning() throws {
        try addRecord("brave-otter", .provisioning, claim: Claim(id: "c1", pid: 4242, processStartedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let orphan = h.backend.addForeignDevice(name: "brave-otter", booted: false)
        h.clock.advance(minutes: 30)
        #expect(try h.pool.collectGarbage().forgotten.isEmpty)
        h.scanner.exit(4242)
        #expect(try h.pool.collectGarbage().forgotten == ["brave-otter"])
        #expect(h.backend.device(orphan) == nil)
        #expect(try h.state().retired.map(\.reason) == [.abandoned])
    }

    @Test func aRecycledPidDoesNotKeepAClaimAlive() throws {
        try addRecord("brave-otter", .provisioning, claim: Claim(id: "c1", pid: 4242, processStartedAt: Date(timeIntervalSince1970: 1_600_000_000)))
        #expect(try h.pool.collectGarbage().forgotten == ["brave-otter"])
    }

    @Test func recordsWithoutAClaimAreRepairedOnlyAfterTheHungTimeout() throws {
        try addRecord("brave-otter", .provisioning, claim: nil)
        h.clock.advance(minutes: 59)
        #expect(try h.pool.collectGarbage().forgotten.isEmpty)
        h.clock.advance(minutes: 2)
        #expect(try h.pool.collectGarbage().forgotten == ["brave-otter"])
    }

    @Test func creationRepairedAsHungLeavesNoSimulatorBehind() throws {
        h.backend.onCreate = { [unowned h] in
            h.backend.onCreate = nil
            h.clock.advance(minutes: 61)
            #expect((try? h.pool.collectGarbage())?.forgotten.count == 1)
        }
        let error = try #require(throws: SimctlHouseError.self) { try h.pool.acquire(AcquireRequest(spec: DeviceSpec())) }
        #expect(error.exitCode == 5)
        #expect(try h.state().devices.isEmpty)
        #expect(try h.backend.devices().isEmpty)
    }

    @Test func reclaimRepairedAsHungLeavesNoSimulatorBehind() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        h.clock.advance(minutes: 31)
        h.backend.onCreate = { [unowned h] in
            h.backend.onCreate = nil
            h.clock.advance(minutes: 61)
            #expect((try? h.pool.collectGarbage())?.forgotten.count == 1)
        }
        #expect(try h.pool.collectGarbage().reclaimed == [device.name])
        #expect(try h.state().devices.isEmpty)
        #expect(try h.backend.devices().isEmpty)
    }

    @Test func failedForcedEraseKeepsTheLease() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "agent-1"))
        h.backend.failErase = true
        #expect(throws: (any Error).self) { try h.pool.erase(device.name, force: true) }
        let record = try #require(try h.state().devices.first)
        #expect(record.status == .leased)
        #expect(record.lease?.holder == "agent-1")
        #expect(record.history.isEmpty)
    }

    @Test func repairHandsBackTheLeaseOfACrashedForcedErase() throws {
        let device = try h.pool.acquire(AcquireRequest(holder: "agent-1"))
        let crashing = h.pool(processID: 4242)
        h.backend.onErase = { [unowned h] in
            h.backend.onErase = nil
            h.scanner.exit(4242)
            #expect((try? h.pool.collectGarbage())?.recovered == [device.name])
        }
        #expect(throws: SimctlHouseError.takenOver(device: device.name)) { try crashing.erase(device.name, force: true) }
        let record = try #require(try h.state().devices.first)
        #expect(record.status == .leased)
        #expect(record.lease?.holder == "agent-1")
    }

    @Test func expiredUDIDIsNeverHandedOutWhileItsDeleteFails() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        let oldUDID = try #require(device.udid)
        h.clock.advance(minutes: 31)
        h.backend.failDelete = [device.name]
        #expect(try h.pool(processID: 4242).collectGarbage().reclaimed == [device.name])
        let record = try #require(try h.state().devices.first)
        #expect(record.status == .provisioning)
        #expect(record.udid == nil)
        #expect(record.replacedUDID == oldUDID)
        #expect(throws: SimctlHouseError.deviceNotFound(oldUDID)) { try h.pool.release(oldUDID) }
        #expect(try h.pool.acquire(AcquireRequest(spec: DeviceSpec())).udid != oldUDID)

        // Once the reclaiming process is gone, GC deletes the old simulator, retrying until it succeeds.
        h.scanner.exit(4242)
        #expect(try h.pool(processID: 4343).collectGarbage().forgotten == [record.name])
        #expect(h.backend.device(oldUDID) != nil)
        #expect(try h.state().devices.contains { $0.name == record.name })
        h.backend.failDelete = []
        h.scanner.exit(4343)
        #expect(try h.pool.collectGarbage().forgotten == [record.name])
        #expect(h.backend.device(oldUDID) == nil)
        #expect(try !h.state().devices.contains { $0.name == record.name })
        #expect(try h.state().retired.last?.reason == .abandoned)
    }

    @Test func idleShutdownHandsTheDeviceBackWithoutAClaim() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(device.name)
        h.clock.advance(minutes: 16)
        #expect(try h.pool.collectGarbage().shutDown == [device.name])
        let record = try #require(try h.state().devices.first)
        #expect(record.status == .available)
        #expect(record.claim == nil)
    }

    private func addRecord(_ name: String, _ status: PoolDevice.Status, claim: Claim?) throws {
        let now = h.clock.now
        try StateStore(paths: HousePaths(root: h.root)).transaction { state in
            state.devices.append(
                PoolDevice(
                    name: name, udid: nil, deviceTypeIdentifier: "type.iPhone-18-Pro", runtimeIdentifier: "rt.iOS-27-0", status: status, claim: claim,
                    now: now))
        }
    }
}

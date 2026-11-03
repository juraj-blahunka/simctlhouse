import Foundation
import Testing
@testable import SimctlHouseCore

@Suite struct DaemonTests {
    let h = Harness()
    let build = DaemonBuild(executable: "/opt/homebrew/Cellar/simctlhouse/0.2.0/bin/simctlhouse", inode: 1, modifiedAt: 1)

    // MARK: - nextWake

    @Test func nothingToWatchInAnEmptyOrShutDownPool() throws {
        #expect(h.pool.nextWake(in: try h.state(), collectedAt: h.clock.now) == nil)
        _ = try h.pool.create(DeviceSpec())
        h.clock.advance(minutes: 16)
        #expect(h.pool.nextWake(in: try h.state(), collectedAt: h.clock.now) == nil)
    }

    @Test func wakesForTheEarliestLeaseExpiryOrIdleShutdown() throws {
        let leased = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(h.pool.nextWake(in: try h.state(), collectedAt: h.clock.now) == leased.expiresAt)
        h.clock.advance(minutes: 1)
        let released = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(released.name)
        #expect(h.pool.nextWake(in: try h.state(), collectedAt: h.clock.now) == h.clock.now.addingTimeInterval(15 * 60))
    }

    @Test func aFreeDeviceCountsUntilACollectionRanAfterItsIdleTime() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        let collectedAt = h.clock.now
        h.clock.advance(minutes: 1)
        try h.pool.release(device.name)
        let idleEnds = h.clock.now.addingTimeInterval(15 * 60)
        h.clock.advance(minutes: 20)
        // Past its idle time but not collected since: still booted, so the daemon must not exit.
        #expect(h.pool.nextWake(in: try h.state(), collectedAt: collectedAt) == idleEnds)
        #expect(h.pool.nextWake(in: try h.state(), collectedAt: h.clock.now) == nil)
    }

    @Test func aDeviceReleasedRightAfterACollectionCountsDespiteWholeSecondTimestamps() throws {
        var config = PoolConfig()
        config.idleShutdown = 0.5
        let pool = h.pool(config: config)
        let device = try pool.acquire(AcquireRequest(spec: DeviceSpec()))
        h.clock.advance(minutes: 0.6 / 60)
        let collectedAt = h.clock.now
        h.clock.advance(minutes: 0.3 / 60)
        // Stored as the whole second before the collection.
        try pool.release(device.name)
        #expect(pool.nextWake(in: try h.state(), collectedAt: collectedAt) != nil)
    }

    @Test func workInProgressKeepsTheDaemonUntilTheHungBackstop() throws {
        let device = try h.pool.create(DeviceSpec())
        h.backend.onErase = { [unowned h] in
            h.backend.onErase = nil
            #expect(h.pool.nextWake(in: try! h.state(), collectedAt: h.clock.now) == h.clock.now.addingTimeInterval(60 * 60))
        }
        _ = try h.pool.erase(device.name, force: false)
    }

    // MARK: - serve

    @Test func reclaimsAnExpiredLeaseOnTimeThenExitsOnceIdle() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(try daemon().serve() == .idle)
        let retired = try #require(try h.state().retired.last)
        #expect(retired.name == device.name)
        #expect(retired.reason == .expired)
        #expect(retired.retiredAt.timeIntervalSince(device.expiresAt!) < Daemon.pollInterval)
        let replacement = try #require(try h.state().devices.first)
        #expect(replacement.status == .available)
        #expect(h.backend.device(replacement.udid)?.state == "Shutdown")
        #expect(try !DaemonLock.isHeld(at: h.root.appending(path: "daemon.lock")))
    }

    @Test func shutsDownAnIdleDeviceOnTime() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(device.name)
        let released = h.clock.now
        #expect(try daemon().serve() == .idle)
        #expect(h.backend.device(device.udid)?.state == "Shutdown")
        #expect(h.clock.now.timeIntervalSince(released) < 15 * 60 + Daemon.pollInterval)
    }

    @Test func onlyOneDaemonRuns() throws {
        _ = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        let record = DaemonRecord(pid: 4242, processStartedAt: nil, startedAt: h.clock.now, version: "other", build: build)
        let held = try #require(try DaemonLock.acquire(at: h.root.appending(path: "daemon.lock"), record: record))
        #expect(try daemon().serve() == .alreadyRunning(record))
        held.release()
    }

    @Test func stopsWhenAsked() throws {
        _ = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        let signals = DaemonSignals()
        let daemon = Daemon(pool: h.pool, version: "test", build: build, signals: signals, sleep: { _ in signals.stop() })
        #expect(try daemon.serve() == .stopped)
        #expect(try !DaemonLock.isHeld(at: h.root.appending(path: "daemon.lock")))
    }

    @Test func exitsWhenItsHomeIsDeleted() throws {
        _ = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        let root = h.root
        let daemon = Daemon(
            pool: h.pool, version: "test", build: build, signals: DaemonSignals(), sleep: { _ in try? FileManager.default.removeItem(at: root) })
        #expect(try daemon.serve() == .idle)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aReleaseWakesTheDaemonAtOnce() async throws {
        // Real time: the daemon would otherwise sleep until the lease's expiry, capped at a minute.
        var config = PoolConfig()
        config.idleShutdown = 0.5
        let pool = Pool(paths: HousePaths(root: h.root), backend: h.backend, scanner: h.scanner, config: config)
        let device = try pool.acquire(AcquireRequest(spec: DeviceSpec()))
        let daemon = Daemon(pool: pool, version: "test", build: build)
        let served = Task.detached { try daemon.serve() }
        try await Task.sleep(for: .milliseconds(300))
        try pool.release(device.name)
        let started = Date()
        #expect(try await served.value == .idle)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(h.backend.device(device.udid)?.state == "Shutdown")
    }

    @Test func aStateChangeEndsTheSleep() async throws {
        let signals = DaemonSignals()
        let slept = Task.detached {
            let started = Date()
            signals.sleep(30)
            return Date().timeIntervalSince(started)
        }
        try await Task.sleep(for: .milliseconds(100))
        signals.stateChanged()
        #expect(await slept.value < 10)
    }

    // MARK: - launcher

    @Test func startsADaemonWhenNoneRuns() throws {
        let spawned = Counter()
        #expect(try launcher(spawned).ensureRunning() == .started)
        #expect(spawned.value == 1)
    }

    @Test func startWaitsForTheDaemonItStarted() throws {
        let lockPath = h.root.appending(path: "daemon.lock")
        let record = DaemonRecord(pid: 4343, processStartedAt: nil, startedAt: h.clock.now, version: "test", build: build)
        let held = Held()
        let launcher = DaemonLauncher(
            paths: HousePaths(root: h.root), build: build, scanner: h.scanner,
            spawn: { _ in
                held.lock = try DaemonLock.acquire(at: lockPath, record: record)
                return 4343
            }, signal: { _ in })
        #expect(try launcher.start(timeout: 1) == (.started, .running))
        // A daemon with nothing to watch exits at once; its record stays behind in the lock file.
        held.lock?.release()
        let exited = DaemonLauncher(
            paths: HousePaths(root: h.root), build: build, scanner: h.scanner,
            spawn: { _ in
                try DaemonLock.acquire(at: lockPath, record: record)?.release()
                return 4343
            }, signal: { _ in })
        #expect(try exited.start(timeout: 1) == (.started, .exited))
    }

    @Test func leavesADaemonOfThisBuildAlone() throws {
        let held = try holdLock(build: build)
        let spawned = Counter()
        let signalled = Counter()
        #expect(try launcher(spawned, signalled).ensureRunning() == .running)
        #expect(spawned.value == 0)
        #expect(signalled.value == 0)
        held.release()
    }

    @Test func replacesADaemonOfAnotherBuildWithoutWaitingForIt() throws {
        let held = try holdLock(build: DaemonBuild(executable: build.executable, inode: 1, modifiedAt: 0))
        let takeOvers = Messages()
        let signalled = Counter()
        let launcher = DaemonLauncher(
            paths: HousePaths(root: h.root), build: build, scanner: h.scanner,
            spawn: { takeOver in
                takeOvers.append("\(takeOver)")
                return 4343
            },
            signal: { _ in signalled.increment() })
        // The old daemon is still busy: the command returns at once and leaves the wait to the replacement.
        #expect(try launcher.ensureRunning() == .replacing)
        #expect(signalled.value == 1)
        #expect(takeOvers.all == ["true"])
        held.release()
    }

    @Test func startsOnlyOneReplacement() throws {
        let held = try holdLock(build: DaemonBuild(executable: build.executable, inode: 1, modifiedAt: 0))
        let record = DaemonRecord(pid: 4343, processStartedAt: nil, startedAt: h.clock.now, version: "test", build: build)
        let waiting = try #require(try DaemonLock.acquire(at: h.root.appending(path: "daemon.next.lock"), record: record))
        let spawned = Counter()
        let signalled = Counter()
        #expect(try launcher(spawned, signalled).ensureRunning() == .replacing)
        #expect(spawned.value == 0)
        #expect(signalled.value == 0)
        waiting.release()
        held.release()
    }

    @Test func aReplacementTakesOverOnceTheOldDaemonExits() async throws {
        let held = try holdLock(build: DaemonBuild(executable: build.executable, inode: 1, modifiedAt: 0))
        _ = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        let signals = DaemonSignals()
        let daemon = Daemon(pool: h.pool, version: "test", build: build, signals: signals, sleep: { _ in signals.stop() })
        let served = Task.detached { try daemon.serve(takeOver: true) }
        try await Task.sleep(for: .milliseconds(300))
        // Waiting: it holds the next lock, not the daemon lock.
        #expect(try DaemonLock.isHeld(at: h.root.appending(path: "daemon.next.lock")))
        held.release()
        #expect(try await served.value == .stopped)
        #expect(DaemonLock.record(at: h.root.appending(path: "daemon.lock"))?.build == build)
        #expect(try !DaemonLock.isHeld(at: h.root.appending(path: "daemon.next.lock")))
    }

    @Test func withoutTakeOverASecondDaemonLeaves() throws {
        let held = try holdLock(build: build)
        #expect(try daemon().serve() == .alreadyRunning(DaemonLock.record(at: h.root.appending(path: "daemon.lock"))))
        held.release()
    }

    @Test func neverSignalsARecycledPid() throws {
        let held = try holdLock(build: DaemonBuild(executable: "/old/simctlhouse", inode: 1, modifiedAt: 1), processStartedAt: Date(timeIntervalSince1970: 1))
        let spawned = Counter()
        let signalled = Counter()
        #expect(try launcher(spawned, signalled).ensureRunning() == .running)
        #expect(try !launcher(spawned, signalled).stop(timeout: 0))
        #expect(signalled.value == 0)
        #expect(spawned.value == 0)
        held.release()
    }

    @Test func statusReportsTheRunningBuild() throws {
        #expect(try launcher(Counter()).status() == DaemonStatus(running: false))
        let held = try holdLock(build: build)
        let status = try launcher(Counter()).status()
        #expect(status.running)
        #expect(status.daemon?.pid == 4242)
        #expect(status.isCurrentBuild == true)
        held.release()
    }

    @Test func theDaemonCanBeTurnedOff() throws {
        #expect(try DaemonLauncher.isEnabled([:]))
        #expect(try DaemonLauncher.isEnabled(["SIMCTLHOUSE_DAEMON": "1"]))
        #expect(try !DaemonLauncher.isEnabled(["SIMCTLHOUSE_DAEMON": "0"]))
        #expect(throws: SimctlHouseError.invalidEnvironment(variable: "SIMCTLHOUSE_DAEMON", value: "no", expected: "0 or 1")) {
            try DaemonLauncher.isEnabled(["SIMCTLHOUSE_DAEMON": "no"])
        }
    }

    // MARK: - helpers

    /// A daemon whose sleep advances the test clock instead of waiting.
    private func daemon() -> Daemon {
        Daemon(pool: h.pool, version: "test", build: build, signals: DaemonSignals(), sleep: { [unowned h] seconds in h.clock.advance(minutes: seconds / 60) })
    }

    private func launcher(_ spawned: Counter, _ signalled: Counter = Counter()) -> DaemonLauncher {
        DaemonLauncher(
            paths: HousePaths(root: h.root), build: build, scanner: h.scanner,
            spawn: { _ in
                spawned.increment(); return 4343
            }, signal: { _ in signalled.increment() })
    }

    /// Holds the daemon lock the way another daemon process would.
    private func holdLock(build: DaemonBuild, processStartedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)) throws -> DaemonLock {
        let record = DaemonRecord(pid: 4242, processStartedAt: processStartedAt, startedAt: h.clock.now, version: "test", build: build)
        return try #require(try DaemonLock.acquire(at: h.root.appending(path: "daemon.lock"), record: record))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class Held: @unchecked Sendable {
    var lock: DaemonLock?
}

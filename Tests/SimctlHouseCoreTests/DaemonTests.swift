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

    @Test func onlyAPoolWithSomethingToWatchNeedsADaemon() throws {
        #expect(try !h.pool.hasWorkForDaemon())
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(try h.pool.hasWorkForDaemon())
        try h.pool.release(device.name)
        // Released and still booted: the daemon has its idle shutdown to do.
        #expect(try h.pool.hasWorkForDaemon())
        h.clock.advance(minutes: 16)
        // Asking collects first, which shuts the idle device down, so nothing is left.
        #expect(try !h.pool.hasWorkForDaemon())
        let udid = try #require(device.udid)
        #expect(h.backend.device(udid)?.state == "Shutdown")
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

    @Test func keepsWatchingALeaseBoundToAProcessAndReclaimsItOnceTheProcessExits() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec(), owner: 4242))
        let exitAt = h.clock.now.addingTimeInterval(3 * 60 * 60)
        let daemon = Daemon(
            pool: h.pool, version: "test", build: build, signals: DaemonSignals(),
            sleep: { [unowned h] seconds in
                h.clock.advance(minutes: seconds / 60)
                if h.clock.now >= exitAt { h.scanner.exit(4242) }
            })
        #expect(try daemon.serve() == .idle)
        let retired = try #require(try h.state().retired.last)
        #expect(retired.name == device.name)
        #expect(retired.reason == .abandoned)
        #expect(retired.retiredAt >= exitAt)
        #expect(retired.retiredAt.timeIntervalSince(exitAt) <= Daemon.pollInterval)
    }

    @Test func shutsDownAnIdleDeviceOnTime() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(device.name)
        let released = h.clock.now
        #expect(try daemon().serve() == .idle)
        #expect(h.backend.device(device.udid)?.state == "Shutdown")
        #expect(h.clock.now.timeIntervalSince(released) < 15 * 60 + Daemon.pollInterval)
    }

    @Test func aKeepAliveKeepsAnIdleDaemonRunning() throws {
        let started = h.clock.now
        let daemon = daemon()
        let served = try daemon.serve(keepAlive: 30 * 60) {
            #expect(DaemonLock.record(at: h.root.appending(path: "daemon.lock"))?.keepAliveUntil == started.addingTimeInterval(30 * 60))
        }
        #expect(served == .idle)
        #expect(h.clock.now == started.addingTimeInterval(30 * 60))
        #expect(try !DaemonLock.isHeld(at: h.root.appending(path: "daemon.lock")))
    }

    @Test func aDaemonKeptAliveStillDoesItsWorkOnTime() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        try h.pool.release(device.name)
        let started = h.clock.now
        let shutDown = Moment()
        let daemon = Daemon(
            pool: h.pool, version: "test", build: build, signals: DaemonSignals(),
            sleep: { [unowned h] seconds in
                // Checked before sleeping on, so it is the time of the collection that shut the device down.
                if h.backend.device(device.udid)?.state == "Shutdown" { shutDown.setOnce(h.clock.now) }
                h.clock.advance(minutes: seconds / 60)
            })
        #expect(try daemon.serve(keepAlive: 20 * 60) == .idle)
        // The idle shutdown happens on time, and the daemon then stays until its keep-alive ends.
        let shutDownAfter = try #require(shutDown.value).timeIntervalSince(started)
        #expect(shutDownAfter >= 15 * 60 && shutDownAfter < 15 * 60 + Daemon.pollInterval)
        #expect(h.clock.now == started.addingTimeInterval(20 * 60))
    }

    @Test func aDaemonKeptAliveNoticesAKilledRunWithinItsPoll() throws {
        let woken = Counter()
        let exitAt = h.clock.now.addingTimeInterval(5 * 60)
        let daemon = Daemon(
            pool: h.pool, version: "test", build: build, signals: DaemonSignals(),
            sleep: { [unowned h] seconds in
                woken.increment()
                guard woken.value > 1 else {
                    // Waiting out its keep-alive, the daemon is woken by a `run` taking a lease.
                    h.clock.advance(minutes: 1 / 60)
                    _ = try? h.pool.acquire(AcquireRequest(spec: DeviceSpec(), owner: 4242))
                    return
                }
                h.clock.advance(minutes: seconds / 60)
                if h.clock.now >= exitAt { h.scanner.exit(4242) }
            })
        #expect(try daemon.serve(keepAlive: 30 * 60) == .idle)
        let retired = try #require(try h.state().retired.last)
        #expect(retired.reason == .abandoned)
        #expect(retired.retiredAt.timeIntervalSince(exitAt) <= Daemon.pollInterval)
    }

    @Test func workOutlastingTheKeepAliveKeepsTheDaemonLonger() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        #expect(try daemon().serve(keepAlive: 5 * 60) == .idle)
        #expect(try h.state().retired.last?.name == device.name)
        #expect(h.clock.now >= device.expiresAt!)
    }

    @Test func aFailedCollectionIsRetriedAtThePoll() throws {
        let device = try h.pool.acquire(AcquireRequest(spec: DeviceSpec()))
        h.backend.failListing = true
        let sleeps = Locked<[TimeInterval]>([])
        let daemon = Daemon(
            pool: h.pool, version: "test", build: build, signals: DaemonSignals(),
            sleep: { [unowned h] seconds in
                sleeps.mutate { $0.append(seconds) }
                h.backend.failListing = false
                h.clock.advance(minutes: seconds / 60)
            })
        #expect(try daemon.serve() == .idle)
        #expect(sleeps.value.first == Daemon.pollInterval)
        #expect(try h.state().retired.last?.name == device.name)
    }

    @Test func stopSignalsTheDaemonAndWaitsForItToExit() throws {
        let held = try holdLock(build: build)
        let launcher = DaemonLauncher(
            paths: HousePaths(root: h.root), build: build, scanner: h.scanner, spawn: { _ in 0 },
            signal: { pid in
                #expect(pid == 4242)
                // Exits a moment later, once its collection is done.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { held.release() }
            })
        #expect(try launcher.stop(timeout: 10))
        #expect(try !launcher.status().running)
        #expect(try launcher.stop(timeout: 0))
    }

    @Test func stopGivesUpOnADaemonThatDoesNotExit() throws {
        let held = try holdLock(build: build)
        let signalled = Counter()
        #expect(try !launcher(Counter(), signalled).stop(timeout: 0.2))
        #expect(signalled.value == 1)
        held.release()
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
        let served = Background { try daemon.serve() }
        try await Task.sleep(for: .milliseconds(300))
        try pool.release(device.name)
        let started = Date()
        #expect(try await served.value == .idle)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(h.backend.device(device.udid)?.state == "Shutdown")
    }

    @Test func aStateChangeEndsTheSleep() async throws {
        let signals = DaemonSignals()
        let slept = Background {
            let started = Date()
            signals.sleep(30)
            return Date().timeIntervalSince(started)
        }
        try await Task.sleep(for: .milliseconds(100))
        signals.stateChanged()
        #expect(try await slept.value < 10)
    }

    // MARK: - launcher

    @Test func startsADaemonWhenNoneRuns() throws {
        let spawned = Counter()
        #expect(try launcher(spawned).ensureRunning() == .started)
        #expect(spawned.value == 1)
    }

    @Test func aCommandStartsTheDaemonOnlyOnceItSucceeded() throws {
        let spawned = Counter()
        let launcher = launcher(spawned)
        let result = try launcher.ensureRunning(
            after: { () -> Int in
                #expect(spawned.value == 0)
                return 7
            }, environment: [:], warn: { Issue.record("unexpected warning: \($0)") })
        #expect(result == 7)
        #expect(spawned.value == 1)

        #expect(throws: SimctlHouseError.deviceNotFound("amber-falcon")) {
            try launcher.ensureRunning(after: { throw SimctlHouseError.deviceNotFound("amber-falcon") }, environment: [:], warn: { _ in })
        }
        #expect(spawned.value == 1)
    }

    @Test func aCommandLeavesTheDaemonAloneWhenItIsTurnedOff() throws {
        let spawned = Counter()
        let ran = Counter()
        try launcher(spawned).ensureRunning(after: { ran.increment() }, environment: ["SIMCTLHOUSE_DAEMON": "0"], warn: { _ in })
        #expect(ran.value == 1)
        #expect(spawned.value == 0)
    }

    @Test func anInvalidDaemonSettingFailsTheCommandBeforeItRuns() {
        let ran = Counter()
        #expect(throws: SimctlHouseError.invalidEnvironment(variable: "SIMCTLHOUSE_DAEMON", value: "yes", expected: "0 or 1")) {
            try launcher(Counter()).ensureRunning(after: { ran.increment() }, environment: ["SIMCTLHOUSE_DAEMON": "yes"], warn: { _ in })
        }
        #expect(ran.value == 0)
    }

    @Test func aDaemonThatCannotStartOnlyWarns() throws {
        let launcher = DaemonLauncher(
            paths: HousePaths(root: h.root), build: build, scanner: h.scanner,
            spawn: { _ in throw SimctlHouseError.io("Cannot start the daemon") }, signal: { _ in })
        let warnings = Messages()
        let result = try launcher.ensureRunning(after: { "done" }, environment: [:], warn: warnings.append)
        #expect(result == "done")
        #expect(warnings.all == ["warning: could not start the simctlhouse daemon: Cannot start the daemon"])
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

    @Test func startPassesTheKeepAliveToTheDaemon() throws {
        let launched = Launches()
        #expect(try launcher(launched).start(keepAlive: 1800, timeout: 1) == (.started, .exited))
        #expect(launched.all == [ServeOptions(keepAlive: 1800)])
        #expect(ServeOptions(keepAlive: 1800).arguments == ["daemon", "serve", "--log-file", "--keep-alive", "1800"])
        // Always explicit: `serve` run by hand keeps running for 30 minutes, which a command's daemon must not.
        #expect(ServeOptions().arguments == ["daemon", "serve", "--log-file", "--keep-alive", "0"])
        #expect(ServeOptions(takeOver: true).arguments == ["daemon", "serve", "--log-file", "--take-over", "--keep-alive", "0"])
    }

    @Test func aLongerKeepAliveRestartsADaemonOfThisBuild() throws {
        // Started by a command, so without a keep-alive.
        let held = try holdLock(build: build)
        let launched = Launches()
        let signalled = Counter()
        #expect(try launcher(launched, signalled).ensureRunning() == .running)
        #expect(launched.all.isEmpty)
        // The fake replacement never takes the lock, as if the old daemon were still finishing its collection.
        #expect(try launcher(launched, signalled).start(keepAlive: 1800, timeout: 0.1) == (.restarting, .waiting))
        #expect(signalled.value == 1)
        #expect(launched.all == [ServeOptions(takeOver: true, keepAlive: 1800)])
        held.release()
    }

    @Test func aShorterKeepAliveLeavesTheDaemonAlone() throws {
        let held = try holdLock(build: build, keepAliveUntil: Date().addingTimeInterval(3600))
        #expect(try launcher(Launches()).start(keepAlive: 3500, timeout: 0.1) == (.running, .running))
        let launched = Launches()
        let signalled = Counter()
        #expect(try launcher(launched, signalled).start(keepAlive: 1800, timeout: 0.1) == (.running, .running))
        #expect(signalled.value == 0)
        #expect(launched.all.isEmpty)
        held.release()
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
            spawn: { options in
                takeOvers.append("\(options.takeOver)")
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
        let served = Background { try daemon.serve(takeOver: true) }
        // Waiting: it holds the next lock, not the daemon lock.
        #expect(try await eventually { try DaemonLock.isHeld(at: h.root.appending(path: "daemon.next.lock")) })
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

    /// Records each daemon it starts. Each one takes the lock and exits at once, as with nothing to watch,
    /// or finds it held, as while the daemon it replaces still runs.
    private func launcher(_ launched: Launches, _ signalled: Counter = Counter()) -> DaemonLauncher {
        let lockPath = h.root.appending(path: "daemon.lock")
        let record = DaemonRecord(pid: 4343, processStartedAt: nil, startedAt: Date(), version: "test", build: build)
        return DaemonLauncher(
            paths: HousePaths(root: h.root), build: build, scanner: h.scanner,
            spawn: { options in
                launched.append(options)
                try DaemonLock.acquire(at: lockPath, record: record)?.release()
                return 4343
            }, signal: { _ in signalled.increment() })
    }

    /// Holds the daemon lock the way another daemon process would.
    /// Started now on the wall clock, which the launcher compares keep-alives against.
    private func holdLock(
        build: DaemonBuild, processStartedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000), keepAliveUntil: Date? = nil
    ) throws -> DaemonLock {
        let record = DaemonRecord(
            pid: 4242, processStartedAt: processStartedAt, startedAt: Date(), version: "test", build: build, keepAliveUntil: keepAliveUntil)
        return try #require(try DaemonLock.acquire(at: h.root.appending(path: "daemon.lock"), record: record))
    }
}

/// The first moment set, from any thread.
final class Moment: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?

    var value: Date? { lock.withLock { date } }
    func setOnce(_ moment: Date) { lock.withLock { date = date ?? moment } }
}

final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var options: [ServeOptions] = []

    var all: [ServeOptions] { lock.withLock { options } }
    func append(_ launch: ServeOptions) { lock.withLock { options.append(launch) } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Whether `condition` becomes true within `timeout`, checked every 20ms.
/// Waits on a state instead of a fixed time, because background work starts late on a loaded machine.
func eventually(timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return try condition()
}

/// Runs blocking work, such as `Daemon.serve`, on a GCD thread while the test goes on and later awaits its result.
///
/// `Task.detached` would run it on Swift's cooperative pool, which has one thread per core (3 on a CI runner).
/// The blocked work would then hold a thread that the test needs to resume and unblock it, and the run hangs.
final class Background<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    init(_ work: @escaping @Sendable () throws -> T) {
        DispatchQueue.global().async { self.finish(Result { try work() }) }
    }

    var value: T {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let done = lock.withLock {
                    if result == nil { waiter = continuation }
                    return result
                }
                if let done { continuation.resume(with: done) }
            }
        }
    }

    private func finish(_ done: Result<T, Error>) {
        let waiting = lock.withLock {
            result = done
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(with: done)
    }
}

final class Held: @unchecked Sendable {
    var lock: DaemonLock?
}

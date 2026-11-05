import Foundation
import Testing
@testable import SimctlHouseCore

/// Stands in for the command `run` starts: records what it was given and reacts like a process would.
final class FakeLauncher: CommandLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [(arguments: [String], environment: [String: String])] = []
    private var _signals: [Int32] = []
    private var events: RunEvents?
    var startError: CommandNotStarted?
    /// Runs once the command started, with the events it would post to.
    var onStart: (@Sendable (RunEvents) -> Void)?
    /// Runs for every signal sent to the command.
    var onSignal: (@Sendable (Int32, RunEvents) -> Void)?

    var started: [(arguments: [String], environment: [String: String])] { lock.withLock { _started } }
    var signals: [Int32] { lock.withLock { _signals } }

    func start(_ arguments: [String], environment: [String: String], events: RunEvents) throws -> Int32 {
        if let startError { throw startError }
        lock.withLock {
            _started.append((arguments, environment))
            self.events = events
        }
        onStart?(events)
        return 777
    }

    func signal(_ pid: Int32, _ signal: Int32) {
        let events = lock.withLock {
            _signals.append(signal)
            return self.events
        }
        if let events { onSignal?(signal, events) }
    }

    /// Exits with the signal it was sent, as a command with default handlers does.
    func diesOnSignal() {
        onSignal = { signal, events in events.post(.exited(status: signal)) }
    }

    static func exitStatus(_ code: Int32) -> Int32 { code << 8 }
}

final class FakeSignals: RunSignals, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }
    func install(_ events: RunEvents) { lock.withLock { log.append("install") } }
    func restore() { lock.withLock { log.append("restore") } }
}

@Suite struct RunnerTests {
    let h = Harness()
    let launcher = FakeLauncher()
    let signals = FakeSignals()
    let messages = Locked<[String]>([])
    let commits = Locked(0)
    /// The pid of the simctlhouse process running the command, which its leases are bound to.
    let runPid: Int32 = 4242

    func runner(gracePeriod: TimeInterval = 5) -> Runner {
        let messages = messages
        let commits = commits
        return Runner(
            pool: h.pool(processID: runPid), launcher: launcher, signals: signals, gracePeriod: gracePeriod,
            log: { message in messages.mutate { $0.append(message) } }, afterCommit: { commits.mutate { $0 += 1 } })
    }

    func request(_ command: [String], count: Int = 1, timeout: TimeInterval? = nil, spec: DeviceSpec = DeviceSpec()) -> RunRequest {
        RunRequest(acquire: AcquireRequest(spec: spec, holder: "test"), count: count, command: command, timeout: timeout, environment: ["PATH": "/usr/bin"])
    }

    @Test func runsTheCommandOnALeasedDeviceAndPassesItsExitCodeThrough() throws {
        launcher.onStart = { [h, runPid] events in
            // While it runs, the device is leased to this run and bound to its process.
            let lease = try? h.state().devices.first?.lease
            #expect(lease?.owner?.pid == runPid)
            #expect(lease?.holder == "test")
            events.post(.exited(status: FakeLauncher.exitStatus(65)))
        }
        let outcome = try runner().run(request(["xcrun", "simctl", "launch", "{udid}", "com.example.app"]))
        #expect(outcome == .exited(65))
        #expect(outcome.exitCode == 65)

        let device = try #require(try h.state().devices.first)
        let started = try #require(launcher.started.first)
        #expect(started.arguments == ["xcrun", "simctl", "launch", device.udid!, "com.example.app"])
        #expect(started.environment["SIMCTLHOUSE_UDID"] == device.udid)
        #expect(started.environment["PATH"] == "/usr/bin")
        #expect(device.status == .available)
        #expect(device.history.last?.outcome == .released)
        #expect(signals.calls == ["install", "restore"])
        // The daemon is made sure of after acquiring and after releasing.
        #expect(commits.value == 2)
    }

    @Test func addsTheDestinationToXcodebuildAndSaysSo() throws {
        launcher.onStart = { events in events.post(.exited(status: 0)) }
        #expect(try runner().run(request(["xcodebuild", "test", "-scheme", "App"])) == .exited(0))
        let udid = try #require(try h.state().devices.first?.udid)
        #expect(launcher.started.first?.arguments.suffix(2) == ["-destination", "id=\(udid)"])
        #expect(messages.value.contains("Added -destination id=\(udid) to xcodebuild."))
    }

    @Test func leasesSeveralDevicesForXcodebuildWithCount() throws {
        launcher.onStart = { events in events.post(.exited(status: 0)) }
        #expect(try runner().run(request(["xcodebuild", "test", "-scheme", "App"], count: 2)) == .exited(0))
        let devices = try h.state().devices
        #expect(devices.count == 2)
        #expect(Set(devices.map(\.status)) == [.available])
        let arguments = try #require(launcher.started.first?.arguments)
        for device in devices { #expect(arguments.contains("id=\(device.udid!)")) }
        #expect(launcher.started.first?.environment["SIMCTLHOUSE_UDIDS"]?.split(separator: " ").count == 2)
    }

    @Test func aFailedAcquireStartsNothing() throws {
        #expect(throws: SimctlHouseError.unknownModel("Nope 1")) {
            try runner().run(request(["true"], spec: DeviceSpec(model: "Nope 1")))
        }
        #expect(launcher.started.isEmpty)
    }

    @Test func aCommandNoLeaseCouldFixIsRefusedFirst() throws {
        #expect(throws: SimctlHouseError.self) {
            try runner().run(request(["xcodebuild", "test", "-destination", "platform=iOS Simulator,name=iPhone 18 Pro"]))
        }
        // Refused before leasing, so no device was booted for nothing.
        #expect(launcher.started.isEmpty)
        #expect(try h.state().devices.isEmpty)
    }

    @Test func aDestinationNamingAnotherDeviceIsRefusedOnceTheLeasedOneIsKnown() throws {
        #expect(throws: SimctlHouseError.self) {
            try runner().run(request(["xcodebuild", "test", "-destination", "id=00000000-0000-0000-0000-000000000000"]))
        }
        #expect(launcher.started.isEmpty)
        #expect(try h.state().devices.first?.status == .available)
    }

    @Test func aCommandThatCannotStartReleasesTheDevice() throws {
        launcher.startError = CommandNotStarted(errno: ENOENT)
        let outcome = try runner().run(request(["no-such-command"]))
        #expect(outcome == .notStarted(errno: ENOENT))
        #expect(outcome.exitCode == 127)
        #expect(try h.state().devices.first?.status == .available)
    }

    @Test func forwardsASignalFromAProcessAndReportsTheCommandsDeath() throws {
        launcher.diesOnSignal()
        launcher.onStart = { events in events.post(.signal(SIGTERM, fromProcess: true)) }
        let outcome = try runner().run(request(["sleep", "60"]))
        #expect(outcome == .signaled(SIGTERM))
        #expect(outcome.exitCode == 143)
        #expect(launcher.signals == [SIGTERM])
        #expect(try h.state().devices.first?.status == .available)
    }

    @Test func doesNotForwardASignalTheTerminalSentToTheCommandToo() throws {
        launcher.onStart = { events in
            events.post(.signal(SIGINT, fromProcess: false))
            events.post(.exited(status: SIGINT))
        }
        #expect(try runner().run(request(["sleep", "60"])) == .signaled(SIGINT))
        #expect(launcher.signals.isEmpty)
    }

    @Test func killsACommandThatOutlastsTheGracePeriod() throws {
        launcher.onSignal = { signal, events in
            if signal == SIGKILL { events.post(.exited(status: SIGKILL)) }
        }
        launcher.onStart = { events in events.post(.signal(SIGTERM, fromProcess: true)) }
        #expect(try runner(gracePeriod: 0.05).run(request(["sleep", "60"])) == .signaled(SIGKILL))
        #expect(launcher.signals == [SIGTERM, SIGKILL])
    }

    @Test func aSecondSignalKillsTheCommandRightAway() throws {
        launcher.onSignal = { signal, events in
            if signal == SIGKILL { events.post(.exited(status: SIGKILL)) }
        }
        launcher.onStart = { events in
            events.post(.signal(SIGINT, fromProcess: false))
            events.post(.signal(SIGINT, fromProcess: false))
        }
        #expect(try runner(gracePeriod: 60).run(request(["sleep", "60"])) == .signaled(SIGKILL))
        #expect(launcher.signals == [SIGKILL])
    }

    @Test func stopsTheCommandAtTheTimeout() throws {
        launcher.diesOnSignal()
        let outcome = try runner().run(request(["sleep", "60"], timeout: 0.05))
        #expect(outcome == .timedOut)
        #expect(outcome.exitCode == 124)
        #expect(launcher.signals == [SIGTERM])
        #expect(try h.state().devices.first?.status == .available)
    }

    @Test func stopsTheCommandWhenSomeoneElseReleasesItsDevice() throws {
        launcher.diesOnSignal()
        launcher.onStart = { [h] _ in
            // Another agent releases the device by name while the command runs.
            let name = (try? h.state())?.devices.first?.name ?? ""
            _ = try? h.pool.release(name)
        }
        let outcome = try runner().run(request(["sleep", "60"]))
        #expect(outcome == .leaseLost)
        #expect(outcome.exitCode == 125)
        #expect(launcher.signals == [SIGTERM])
        #expect(messages.value.contains { $0.contains("ended while the command ran") })
    }

    @Test func noticesALeaseLostWhileTheCommandRuns() throws {
        launcher.diesOnSignal()
        launcher.onStart = { [h] _ in
            // A thread of its own: with every core busy, the global queues could hold the delete back.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.2)
                let name = (try? h.state())?.devices.first?.name ?? ""
                _ = try? h.pool.delete([name], force: true)
            }
        }
        #expect(try runner().run(request(["sleep", "60"])) == .leaseLost)
    }
}

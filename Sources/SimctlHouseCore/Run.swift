import Foundation

/// What `simctlhouse run` was asked to do.
public struct RunRequest: Sendable {
    /// How to lease each device. `Runner` binds the leases to its own process.
    public var acquire: AcquireRequest
    /// How many devices to lease, for xcodebuild testing on several simulators at once.
    public var count: Int
    public var command: [String]
    /// Stop the command after this long.
    public var timeout: TimeInterval?
    /// The command's environment, before the device variables are added.
    public var environment: [String: String]

    public init(acquire: AcquireRequest, count: Int = 1, command: [String], timeout: TimeInterval? = nil, environment: [String: String]) {
        self.acquire = acquire
        self.count = count
        self.command = command
        self.timeout = timeout
        self.environment = environment
    }
}

/// How a `simctlhouse run` ended, once its command had been started or failed to start.
/// A failure before that (acquire, an invalid command) is thrown as a `SimctlHouseError` instead.
public enum RunOutcome: Equatable, Sendable {
    /// The command exited with this status.
    case exited(Int32)
    /// The command was ended by this signal.
    case signaled(Int32)
    /// `--timeout` passed, and the command was stopped.
    case timedOut
    /// A device's lease ended while the command ran (someone released or deleted it), and the command was stopped.
    case leaseLost
    /// The command could not be started: `errno` from `posix_spawnp`.
    case notStarted(errno: Int32)

    /// The command's own status, or one of the codes `env` and `timeout` use for their own failures (D34):
    /// 124 timed out, 125 simctlhouse failed, 126 not executable, 127 not found, 128+N killed by signal N.
    public var exitCode: Int32 {
        switch self {
        case .exited(let status): status
        case .signaled(let signal): 128 + signal
        case .timedOut: RunExitCode.timedOut
        case .leaseLost: RunExitCode.failed
        case .notStarted(let errno): errno == ENOENT ? RunExitCode.notFound : RunExitCode.notExecutable
        }
    }
}

/// The exit codes of `simctlhouse run` itself; every other code is the command's own.
public enum RunExitCode {
    public static let timedOut: Int32 = 124
    public static let failed: Int32 = 125
    public static let notExecutable: Int32 = 126
    public static let notFound: Int32 = 127
}

/// Something the run loop reacts to.
public enum RunEvent: Equatable, Sendable {
    /// The command ended; the raw `waitpid` status.
    case exited(status: Int32)
    /// A signal arrived. `fromProcess` is false for one the terminal sent to the whole foreground process group
    /// (Ctrl-C), which the command has received itself.
    case signal(Int32, fromProcess: Bool)
    /// `state.json` changed.
    case stateChanged
}

/// The run loop's inbox, filled from the command's waiter thread, the signal handler and the state watcher.
public final class RunEvents: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [RunEvent] = []

    public init() {}

    public func post(_ event: RunEvent) {
        condition.withLock {
            queue.append(event)
            condition.broadcast()
        }
    }

    /// The next event, or nil once `deadline` has passed without one.
    func next(until deadline: Date?) -> RunEvent? {
        condition.withLock {
            while queue.isEmpty {
                if let deadline {
                    guard condition.wait(until: deadline) else { return queue.isEmpty ? nil : queue.removeFirst() }
                } else {
                    condition.wait()
                }
            }
            return queue.removeFirst()
        }
    }

    /// Takes every queued event without waiting.
    func drain() -> [RunEvent] {
        condition.withLock {
            defer { queue.removeAll() }
            return queue
        }
    }
}

/// Starts the command and signals it. The seam that keeps `RunnerTests` free of real processes.
public protocol CommandLauncher: Sendable {
    /// Starts the command and returns its pid; posts `.exited` to `events` once it ends.
    /// Throws `CommandNotStarted` when `posix_spawnp` fails.
    func start(_ arguments: [String], environment: [String: String], events: RunEvents) throws -> Int32
    func signal(_ pid: Int32, _ signal: Int32)
}

public struct CommandNotStarted: Error, Equatable {
    public var errno: Int32
}

/// Delivers signals sent to `simctlhouse run` as events instead of letting them end it, so it can stop the command
/// and release its devices first. Installed only once the command starts: a signal during acquire still ends
/// simctlhouse at once, and GC repairs or reclaims what it left behind.
public protocol RunSignals: Sendable {
    func install(_ events: RunEvents)
    /// Puts the default handlers back, so the command's signal can be raised again on simctlhouse itself.
    func restore()
}

/// Runs a command on leased devices, keeps the leases while it runs, and releases them however it ends.
///
/// The leases are bound to this process instead of being renewed on a timer: they do not expire while it runs,
/// and if it is killed without a chance to release them, GC reclaims the devices (D33).
public struct Runner: Sendable {
    /// How long a command may take to exit after it was asked to stop, before it is killed.
    public static let defaultGracePeriod: TimeInterval = 15
    /// How often the leases are checked even without a state change, in case the watcher missed one.
    static let leaseCheckInterval: TimeInterval = 60

    let pool: Pool
    let launcher: CommandLauncher
    let signals: RunSignals
    let gracePeriod: TimeInterval
    let log: @Sendable (String) -> Void
    /// Called after each change this run commits (acquire, release), to make sure a daemon runs (D29).
    let afterCommit: @Sendable () -> Void

    public init(
        pool: Pool, launcher: CommandLauncher = PosixCommandLauncher(), signals: RunSignals = PosixRunSignals(),
        gracePeriod: TimeInterval = Runner.defaultGracePeriod, log: @escaping @Sendable (String) -> Void,
        afterCommit: @escaping @Sendable () -> Void = {}
    ) {
        self.pool = pool
        self.launcher = launcher
        self.signals = signals
        self.gracePeriod = gracePeriod
        self.log = log
        self.afterCommit = afterCommit
    }

    public func run(_ request: RunRequest) throws -> RunOutcome {
        try RunCommand.check(request.command, count: request.count)
        let devices = try acquire(request)
        afterCommit()
        let events = RunEvents()
        defer {
            // Still under our signal handlers, so a signal cannot cut the release short.
            release(devices)
            afterCommit()
            signals.restore()
        }
        let command = try RunCommand(request.command, devices: devices)
        for destination in command.addedDestinations { log("Added -destination \(destination) to xcodebuild.") }

        signals.install(events)
        let pid: Int32
        do {
            pid = try launcher.start(command.arguments, environment: RunEnvironment.adding(devices, to: request.environment), events: events)
        } catch let error as CommandNotStarted {
            log("Cannot run \(request.command[0]): \(String(cString: strerror(error.errno))).")
            return .notStarted(errno: error.errno)
        }
        let watcher = try? watchState(in: pool.store.paths.root) { events.post(.stateChanged) }
        defer { watcher?.cancel() }
        return wait(for: pid, devices: devices, timeout: request.timeout, events: events)
    }

    private func acquire(_ request: RunRequest) throws -> [RunDevice] {
        var acquire = request.acquire
        acquire.owner = pool.processID
        let results = Locked<[Result<DeviceInfo, Error>]>([])
        // Each acquire is mostly waiting on a boot, so several devices boot at the same time.
        concurrentForEach(Array(0..<max(request.count, 1))) { [acquire] _ in
            let result = Result { try pool.acquire(acquire) }
            results.mutate { $0.append(result) }
        }
        let infos = results.value.compactMap { try? $0.get() }
        let devices = infos.map { RunDevice(name: $0.name, udid: $0.udid!, leaseId: $0.leaseId!) }
        for case .failure(let error) in results.value {
            release(devices)
            throw error
        }
        for info in infos {
            log("Leased \(info.name) (\(info.model), iOS \(info.os), \(info.udid!)) until the command exits.")
        }
        return devices
    }

    private func release(_ devices: [RunDevice]) {
        for device in devices {
            do {
                if try pool.releaseLease(device.leaseId) != nil {
                    log("Released \(device.name).")
                } else {
                    log("\(device.name) was no longer leased to this run; nothing to release.")
                }
            } catch {
                log("Releasing \(device.name) failed: \(error). It is reclaimed once this process has exited.")
            }
        }
    }

    /// Waits for the command to exit, stopping it on a signal, the timeout or a lost lease:
    /// SIGTERM first (or the signal received), then SIGKILL after the grace period or a second signal.
    private func wait(for pid: Int32, devices: [RunDevice], timeout: TimeInterval?, events: RunEvents) -> RunOutcome {
        var timeoutAt = timeout.map { Date().addingTimeInterval($0) }
        var killAt: Date?
        var stopping = false
        var stopReason: RunOutcome?
        var nextLeaseCheck = Date().addingTimeInterval(Self.leaseCheckInterval)

        func stop(_ signal: Int32, forward: Bool = true) {
            if stopping {
                kill()
                return
            }
            stopping = true
            if forward { launcher.signal(pid, signal) }
            killAt = Date().addingTimeInterval(gracePeriod)
        }
        func kill() {
            launcher.signal(pid, SIGKILL)
            killAt = nil
        }
        func checkLeases() {
            guard stopReason != .leaseLost, let held = try? pool.heldLeases(devices.map(\.leaseId)) else { return }
            let lost = devices.filter { !held.contains($0.leaseId) }
            guard !lost.isEmpty else { return }
            log(
                "The lease on \(lost.map(\.name).joined(separator: ", ")) ended while the command ran (released or deleted by someone else); "
                    + "stopping the command so it cannot use a device another agent may hold.")
            stopReason = .leaseLost
            stop(SIGTERM)
        }

        // Covers a change between acquiring and starting the watcher.
        checkLeases()
        while true {
            // A pool per event: this loop never returns to a run loop, and a command can run for hours.
            let outcome = autoreleasepool { () -> RunOutcome? in
                let deadline = [timeoutAt, killAt, nextLeaseCheck].compactMap { $0 }.min()
                switch events.next(until: deadline) {
                case .exited(let status):
                    if let stopReason { return stopReason }
                    let signal = status & 0x7f
                    return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
                case .signal(let signal, let fromProcess):
                    if stopping {
                        log("Received another signal; killing the command.")
                    } else {
                        log("Received signal \(signal); stopping the command, and killing it if it has not exited in \(Int(gracePeriod))s.")
                    }
                    // A signal from the terminal reached the whole process group, the command included.
                    stop(signal, forward: fromProcess)
                case .stateChanged:
                    checkLeases()
                case nil:
                    let now = Date()
                    if let killAt, now >= killAt {
                        log("The command did not exit within \(Int(gracePeriod))s of being stopped; killing it.")
                        kill()
                    }
                    if let deadline = timeoutAt, now >= deadline {
                        timeoutAt = nil
                        log("The command ran longer than its --timeout of \(Int(timeout ?? 0))s; stopping it.")
                        if stopReason == nil { stopReason = .timedOut }
                        if !stopping { stop(SIGTERM) }
                    }
                    if now >= nextLeaseCheck {
                        nextLeaseCheck = now.addingTimeInterval(Self.leaseCheckInterval)
                        checkLeases()
                    }
                }
                return nil
            }
            if let outcome { return outcome }
        }
    }
}

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

// MARK: - Real processes and signals

/// Starts the command with `posix_spawnp`, with simctlhouse's stdin, stdout and stderr and nothing else.
public struct PosixCommandLauncher: CommandLauncher {
    /// Signals `simctlhouse run` handles; the command gets their default action back.
    static let resetSignals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE]

    public init() {}

    public func start(_ arguments: [String], environment: [String: String], events: RunEvents) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // In simctlhouse's process group, so Ctrl-C and a harness that kills the group reach the command directly.
        // No descriptor but stdio is inherited, so the command never holds simctlhouse's lock files.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in Self.resetSignals { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in [0, 1, 2] { posix_spawn_file_actions_addinherit_np(&actions, descriptor) }

        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawnp(&pid, arguments[0], &actions, &attributes, argv, envp)
        guard result == 0 else { throw CommandNotStarted(errno: result) }
        let child = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1, errno == EINTR {}
            events.post(.exited(status: status))
        }
        return child
    }

    /// A stop signal goes to the command alone, so it can wind down its own processes (xcodebuild cancels its build).
    /// SIGKILL goes to every process it started too, which would otherwise keep running, re-parented to launchd.
    public func signal(_ pid: Int32, _ signal: Int32) {
        let tree = signal == SIGKILL ? ProcessTable.descendants(of: pid) : []
        _ = Darwin.kill(pid, signal)
        for process in tree { _ = Darwin.kill(process, signal) }
    }
}

/// The write end of the pipe the signal handler reports to. A C signal handler cannot capture context.
nonisolated(unsafe) private var signalPipe: Int32 = -1

/// Writes the signal number to `signalPipe`; `write` is async-signal-safe.
private let reportSignal: @convention(c) (Int32) -> Void = { signal in
    let saved = errno
    var number = UInt8(truncatingIfNeeded: signal)
    _ = write(signalPipe, &number, 1)
    errno = saved
}

public struct PosixRunSignals: RunSignals {
    static let handled = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    public init() {}

    public func install(_ events: RunEvents) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return }
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        signalPipe = descriptors[1]
        let reader = descriptors[0]
        Thread.detachNewThread {
            var number: UInt8 = 0
            while true {
                let count = read(reader, &number, 1)
                if count == 1 {
                    let signal = Int32(number)
                    events.post(.signal(signal, fromProcess: !(Self.terminalSignals.contains(signal) && Self.inForegroundOfTerminal())))
                } else if count <= 0, errno != EINTR {
                    return
                }
            }
        }
        for signal in Self.handled {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = reportSignal
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    /// Signals a terminal sends to its whole foreground process group (Ctrl-C, Ctrl-\\, hangup).
    static let terminalSignals: Set<Int32> = [SIGINT, SIGQUIT, SIGHUP]

    /// Whether this process group is in the foreground of its controlling terminal, so the terminal's signals reach the
    /// command (which shares the group) directly. macOS leaves `si_pid` and `si_code` unreliable, so the sender cannot tell.
    /// A `kill -INT` aimed at simctlhouse alone while it runs in the foreground is then not forwarded,
    /// and the command is killed after the grace period instead.
    static func inForegroundOfTerminal() -> Bool {
        let terminal = open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC)
        guard terminal >= 0 else { return false }
        defer { close(terminal) }
        return tcgetpgrp(terminal) == getpgrp()
    }

    public func restore() {
        for signal in Self.handled { Darwin.signal(signal, SIG_DFL) }
    }
}

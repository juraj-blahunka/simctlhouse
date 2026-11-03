import Foundation

/// The binary a daemon runs. A command run by a different build replaces the daemon,
/// so an upgrade never leaves an old build rewriting a state file it may not fully understand.
public struct DaemonBuild: Codable, Equatable, Sendable {
    /// With symlinks resolved, so a Homebrew upgrade, which moves `bin/simctlhouse` to a new version, counts as a new build.
    public var executable: String
    /// Inode and modification time tell a binary rebuilt in place (`swift build`) from the one the daemon started with.
    public var inode: UInt64
    public var modifiedAt: Int64

    public static func current() -> DaemonBuild {
        let executable = SkillInstaller.currentExecutable().resolvingSymlinksInPath().path
        var info = stat()
        guard stat(executable, &info) == 0 else { return DaemonBuild(executable: executable, inode: 0, modifiedAt: 0) }
        return DaemonBuild(executable: executable, inode: UInt64(info.st_ino), modifiedAt: Int64(info.st_mtimespec.tv_sec))
    }
}

/// What the running daemon writes into `daemon.lock`, so commands can see which build runs and stop it.
public struct DaemonRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    /// When `pid` started, in whole seconds, so a recycled pid is never signalled.
    public var processStartedAt: Date?
    public var startedAt: Date
    public var version: String
    public var build: DaemonBuild
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public var running: Bool
    /// Nil when none runs, or while a daemon that just started has not recorded itself yet.
    public var daemon: DaemonRecord?
    /// Whether the daemon runs this very binary; the next command run by this binary replaces it otherwise.
    public var isCurrentBuild: Bool?
}

/// The daemon's single-instance lock: an exclusive `flock` on `daemon.lock`, held for the daemon's whole life.
/// The kernel drops it when the daemon dies, so a crash never leaves a stale lock,
/// and knowing whether a daemon runs needs neither a pid check nor a port.
final class DaemonLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { release() }

    /// Takes the lock and records `record` in the file, or returns nil while another daemon holds it.
    static func acquire(at path: URL, record: DaemonRecord) throws -> DaemonLock? {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posixError("Cannot open \(path.path)") }
        guard try tryLock(descriptor, path: path) else {
            close(descriptor)
            return nil
        }
        let held = DaemonLock(descriptor: descriptor)
        let data = try StateStore.encoder.encode(record)
        let written = data.withUnsafeBytes { buffer in ftruncate(descriptor, 0) == 0 ? pwrite(descriptor, buffer.baseAddress, buffer.count, 0) : -1 }
        guard written == data.count else { throw posixError("Cannot write \(path.path)") }
        return held
    }

    /// Releases the lock. Idempotent.
    func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    /// Whether a daemon holds the lock right now.
    static func isHeld(at path: URL) throws -> Bool {
        let descriptor = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            // No home directory yet means no daemon has ever run here.
            if errno == ENOENT { return false }
            throw posixError("Cannot open \(path.path)")
        }
        defer { close(descriptor) }
        guard try tryLock(descriptor, path: path) else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// The running daemon's record. Nil while a daemon that just took the lock has not written it yet.
    static func record(at path: URL) -> DaemonRecord? {
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return nil }
        return try? StateStore.decoder.decode(DaemonRecord.self, from: data)
    }

    private static func tryLock(_ descriptor: Int32, path: URL) throws -> Bool {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { return false }
            throw posixError("Cannot lock \(path.path)")
        }
        return true
    }

    private static func posixError(_ message: String) -> SimctlHouseError {
        .io("\(message): \(String(cString: strerror(errno)))")
    }
}

/// Wakes `Daemon.serve` from its sleep: to stop, from a signal handler, or because the state changed.
public final class DaemonSignals: @unchecked Sendable {
    private let condition = NSCondition()
    private var stopRequested = false
    private var changed = false

    public init() {}

    public func stop() {
        condition.withLock {
            stopRequested = true
            condition.broadcast()
        }
    }

    func stateChanged() {
        condition.withLock {
            changed = true
            condition.broadcast()
        }
    }

    var isStopRequested: Bool { condition.withLock { stopRequested } }

    /// Sleeps for `seconds`, or until a stop is requested or the state changes.
    func sleep(_ seconds: TimeInterval) {
        condition.withLock {
            let deadline = Date().addingTimeInterval(seconds)
            while !stopRequested, !changed, condition.wait(until: deadline) {}
            changed = false
        }
    }
}

/// Enforces lease expiry and idle shutdown on time, instead of on the next command.
///
/// Commands start it after they add work (`DaemonLauncher.ensureRunning`); it runs GC whenever something comes due,
/// and exits once nothing can come due. It talks to no one: all coordination goes through `state.json` and its lock.
/// It watches the home directory, so a command that moves a deadline (`release`, `renew`, `delete`) wakes it at once.
public struct Daemon: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Another daemon holds the lock.
        case alreadyRunning(DaemonRecord?)
        /// Nothing left to watch.
        case idle
        case stopped
    }

    /// The longest time between collections. It bounds how late the daemon notices a crashed process's claim
    /// and retries a failed collection; deadlines in the state wake it on time regardless.
    static let pollInterval: TimeInterval = 60
    /// The shortest time between collections, so a deadline that a collection could not clear never spins the daemon.
    static let minimumInterval: TimeInterval = 1
    /// How long a daemon of a new build waits for the one it replaces to finish its collection and exit.
    /// Re-creating devices on a loaded machine can take minutes; a command started after this gives up retries.
    static let takeOverTimeout: TimeInterval = 10 * 60

    let pool: Pool
    let version: String
    let build: DaemonBuild
    let signals: DaemonSignals
    let sleep: @Sendable (TimeInterval) -> Void

    public init(pool: Pool, version: String, build: DaemonBuild = .current(), signals: DaemonSignals = DaemonSignals()) {
        self.init(pool: pool, version: version, build: build, signals: signals, sleep: { signals.sleep($0) })
    }

    init(pool: Pool, version: String, build: DaemonBuild, signals: DaemonSignals, sleep: @escaping @Sendable (TimeInterval) -> Void) {
        self.pool = pool
        self.version = version
        self.build = build
        self.signals = signals
        self.sleep = sleep
    }

    /// Runs until nothing is left to watch or a stop is requested. `onLocked` runs once this process is the daemon,
    /// before any work, so a losing duplicate never touches the log.
    /// With `takeOver`, it waits for a running daemon to exit instead of leaving, as the replacement for another build.
    public func serve(takeOver: Bool = false, onLocked: () throws -> Void = {}) throws -> Outcome {
        let paths = pool.store.paths
        let record = DaemonRecord(
            pid: pool.processID, processStartedAt: pool.scanner.startTime(of: pool.processID), startedAt: pool.now(), version: version, build: build)
        guard let lock = try DaemonLock.acquire(at: paths.daemonLock, record: record) ?? (takeOver ? waitToTakeOver(record) : nil) else {
            return .alreadyRunning(DaemonLock.record(at: paths.daemonLock))
        }
        defer { lock.release() }
        try onLocked()
        let watcher = try watch(paths.root)
        defer { watcher.cancel() }
        pool.log("Daemon \(version) started (pid \(record.pid)).")
        // When the last successful collection started, and the last attempt.
        var collectedAt = Date.distantPast
        var lastCollection: Date?
        var nextCollection = pool.now()
        while !signals.isStopRequested {
            // A deleted home (a throwaway test home) has nothing left to watch; going on would only recreate it.
            guard FileManager.default.fileExists(atPath: paths.root.path) else { return .idle }
            do {
                if pool.now() >= nextCollection {
                    let started = pool.now()
                    lastCollection = started
                    nextCollection = started.addingTimeInterval(Self.pollInterval)
                    try pool.collectGarbage()
                    collectedAt = started
                }
                // Re-read on every wake, also when no collection was due: a command may have moved a deadline.
                let wake = try pool.store.transaction { state -> Date? in
                    let wake = pool.nextWake(in: state, collectedAt: collectedAt)
                    // Released under the state lock: a command that adds work commits after this,
                    // then finds no daemon and starts one, so no work is ever left unwatched.
                    if wake == nil { lock.release() }
                    return wake
                }
                guard let wake else {
                    pool.log("Nothing left to watch; exiting.")
                    return .idle
                }
                nextCollection = min(nextCollection, wake)
                if let lastCollection { nextCollection = max(nextCollection, lastCollection.addingTimeInterval(Self.minimumInterval)) }
            } catch {
                pool.log("Collecting garbage failed: \(error). Retrying in \(Int(Self.pollInterval))s.")
            }
            sleep(max(nextCollection.timeIntervalSince(pool.now()), 0))
        }
        pool.log("Daemon stopped.")
        return .stopped
    }

    /// Waits for the running daemon to exit and takes its lock, holding `daemon.next.lock` meanwhile so that commands
    /// start only one replacement. Nil if another replacement already waits, or the running daemon outlasts the timeout.
    private func waitToTakeOver(_ record: DaemonRecord) throws -> DaemonLock? {
        let paths = pool.store.paths
        guard let next = try DaemonLock.acquire(at: paths.daemonNextLock, record: record) else { return nil }
        defer { next.release() }
        let deadline = Date().addingTimeInterval(Self.takeOverTimeout)
        while Date() < deadline, !signals.isStopRequested {
            if let lock = try DaemonLock.acquire(at: paths.daemonLock, record: record) { return lock }
            signals.sleep(0.2)
        }
        return nil
    }

    /// Wakes the daemon whenever an entry in `directory` changes: every state write renames `state.json` into place.
    private func watch(_ directory: URL) throws -> DispatchSourceFileSystemObject {
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SimctlHouseError.io("Cannot watch \(directory.path): \(String(cString: strerror(errno)))") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename])
        source.setEventHandler { [signals] in signals.stateChanged() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}

/// How commands find, start, replace and stop the daemon.
public struct DaemonLauncher: Sendable {
    public static let variable = "SIMCTLHOUSE_DAEMON"

    public enum Outcome: Equatable, Sendable {
        case running
        case started
        /// A daemon of another build was asked to stop; one of this build takes over once it has exited.
        case replacing
    }

    public enum StartState: Equatable, Sendable {
        case running
        /// It found nothing leased, booted or in progress, and exited again.
        case exited
        /// The daemon being replaced has not exited yet; the new one takes over when it does.
        case waiting
    }

    public let paths: HousePaths
    let build: DaemonBuild
    let scanner: ProcessScanner
    /// Starts a daemon process and returns its pid; `takeOver` makes it wait for the running daemon to exit.
    let spawn: @Sendable (_ takeOver: Bool) throws -> Int32
    let signal: @Sendable (Int32) -> Void

    public init(paths: HousePaths, build: DaemonBuild = .current(), scanner: ProcessScanner = PSProcessScanner()) {
        self.init(
            paths: paths, build: build, scanner: scanner,
            spawn: { takeOver in try Self.spawnDetached(build.executable, ["daemon", "serve", "--log-file"] + (takeOver ? ["--take-over"] : [])) },
            signal: { pid in _ = kill(pid, SIGTERM) }
        )
    }

    init(
        paths: HousePaths, build: DaemonBuild, scanner: ProcessScanner, spawn: @escaping @Sendable (_ takeOver: Bool) throws -> Int32,
        signal: @escaping @Sendable (Int32) -> Void
    ) {
        self.paths = paths
        self.build = build
        self.scanner = scanner
        self.spawn = spawn
        self.signal = signal
    }

    /// Whether commands start the daemon: `SIMCTLHOUSE_DAEMON=0` turns it off, for CI and throwaway homes.
    public static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        switch environment[variable] {
        case nil, "", "1": return true
        case "0": return false
        case let value?: throw SimctlHouseError.invalidEnvironment(variable: variable, value: value, expected: "0 or 1")
        }
    }

    /// Starts the daemon unless one of this build runs. Call it after the command's own state change has committed:
    /// a daemon exiting concurrently releases its lock only after checking the state under the state lock, so either it
    /// sees the new work and stays, or this call sees it gone and starts another.
    /// A daemon of another build is asked to stop, and a replacement waits for it in the background, so the command
    /// never waits for the old daemon to finish its collection.
    @discardableResult
    public func ensureRunning() throws -> Outcome {
        try ensure().outcome
    }

    /// `spawned` is the pid of the daemon this call started, if it started one.
    private func ensure() throws -> (outcome: Outcome, spawned: Int32?) {
        guard try DaemonLock.isHeld(at: paths.daemonLock) else { return (.started, try spawn(false)) }
        // No record yet means a daemon is still starting; it is ours to leave alone.
        guard let record = DaemonLock.record(at: paths.daemonLock), record.build != build else { return (.running, nil) }
        // A replacement already waits for it; it signalled the old daemon when it was started.
        if try DaemonLock.isHeld(at: paths.daemonNextLock) { return (.replacing, nil) }
        guard signalIfAlive(record) else { return (.running, nil) }
        return (.replacing, try spawn(true))
    }

    /// Sends the stop signal, but only while the record's pid still has the recorded start time, so a recycled pid is never signalled.
    private func signalIfAlive(_ record: DaemonRecord) -> Bool {
        guard let started = record.processStartedAt, scanner.startTime(of: record.pid) == started else { return false }
        signal(record.pid)
        return true
    }

    public func status() throws -> DaemonStatus {
        guard try DaemonLock.isHeld(at: paths.daemonLock) else { return DaemonStatus(running: false) }
        let record = DaemonLock.record(at: paths.daemonLock)
        return DaemonStatus(running: true, daemon: record, isCurrentBuild: record.map { $0.build == build })
    }

    /// Starts the daemon like `ensureRunning`, then waits until the daemon it started has taken its lock.
    @discardableResult
    public func start(timeout: TimeInterval = 10) throws -> (outcome: Outcome, state: StartState) {
        let (outcome, spawned) = try ensure()
        guard let spawned else { return (outcome, outcome == .running ? .running : .waiting) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // The lock file keeps the last daemon's record after it exits.
            if DaemonLock.record(at: paths.daemonLock)?.pid == spawned {
                return (outcome, try DaemonLock.isHeld(at: paths.daemonLock) ? .running : .exited)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard outcome == .replacing else { throw SimctlHouseError.io("The daemon did not start within \(Int(timeout))s. See \(paths.daemonLog.path).") }
        return (outcome, .waiting)
    }

    /// Asks the daemon to stop and waits for it to exit. Returns whether no daemon runs afterwards.
    /// Only signals the pid in the record while that process still has the recorded start time.
    public func stop(timeout: TimeInterval = 10) throws -> Bool {
        guard try DaemonLock.isHeld(at: paths.daemonLock) else { return true }
        guard let record = DaemonLock.record(at: paths.daemonLock), signalIfAlive(record) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while try DaemonLock.isHeld(at: paths.daemonLock) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    /// Starts `executable arguments` detached from the caller: in its own session, so closing the terminal does not end it,
    /// with stdin, stdout and stderr on /dev/null and no other descriptor inherited, so it never holds a caller's pipe
    /// open (`UDID=$(simctlhouse acquire)` would otherwise wait for the daemon to exit). Does not wait for it.
    static func spawnDetached(_ executable: String, _ arguments: [String]) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard result == 0 else { throw SimctlHouseError.io("Cannot start the daemon (\(executable)): \(String(cString: strerror(result)))") }
        return pid
    }

    /// Points stdout and stderr at `daemon.log`, keeping the previous run's log as `daemon.log.1`.
    public static func redirectOutput(to paths: HousePaths) throws {
        let log = paths.daemonLog.path
        _ = rename(log, log + ".1")
        let descriptor = open(log, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw SimctlHouseError.io("Cannot open \(log): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        guard dup2(descriptor, 1) >= 0, dup2(descriptor, 2) >= 0 else {
            throw SimctlHouseError.io("Cannot redirect output to \(log): \(String(cString: strerror(errno)))")
        }
    }
}

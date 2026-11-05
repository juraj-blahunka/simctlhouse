import ArgumentParser
import Foundation
import SimctlHouseCore

@main
struct SimctlHouse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simctlhouse",
        abstract: "Device Hub for Agents: a pool of iOS simulators that agents lease exclusively.",
        discussion: """
            Each agent acquires its own simulator, uses it via its UDID, and releases it when done,
            or wraps a command in `run`, which does all three: `simctlhouse run -- xcodebuild test -scheme App`.
            Leases expire after 30 minutes (extend with `renew`); expired devices are re-created under a new name and returned to the pool.
            Free devices shut down after 15 minutes of inactivity. simctlhouse only touches devices it created.
            Both timeouts can be changed with environment variables, see below; an idle time of 0 shuts free devices down on the next command.
            `acquire`, `release`, `renew` and `run` start a background daemon that enforces both on time; it exits once the pool is idle.
            Wherever a command takes a device, its name and its UDID both work.

            Machine-readable output goes to stdout, human messages to stderr.
            Commands that print device information accept --json (short: -j) for JSON on stdout.

            Environment:
              SIMCTLHOUSE_LEASE_SECONDS  lease length in seconds (default 1800)
              SIMCTLHOUSE_IDLE_SECONDS   idle seconds before shutdown (default 900)
              SIMCTLHOUSE_HOLDER         default --holder label (otherwise: the agent and directory)
              SIMCTLHOUSE_HOME           state directory (default ~/.simctlhouse)
              SIMCTLHOUSE_DAEMON         0 to never start the daemon (default 1)
            """,
        version: "0.1.1",
        subcommands: [
            Acquire.self, Release.self, Renew.self, Run.self, List.self, UDID.self, History.self, Create.self, Delete.self, Erase.self, GC.self,
            DaemonCommand.self, Home.self, Skill.self, Version.self,
        ]
    )

    /// `run` reports its own failures with 125, so they never look like an exit code of the command it wraps (D34).
    /// ArgumentParser exits with 64 for a usage error before `Run.run` gets a say, so map that here.
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            var command = try parseAsRoot(arguments)
            try command.run()
        } catch {
            if arguments.first == Run.configuration.commandName, exitCode(for: error) == .validationFailure {
                FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
                Foundation.exit(RunExitCode.failed)
            }
            exit(withError: error)
        }
    }
}

// MARK: - Shared options

struct SpecOptions: ParsableArguments {
    @Option(name: .long, help: "Device family: iphone or ipad. Default: iphone.")
    var family: DeviceSpec.Family?

    @Option(name: .long, help: "Exact model name or device type identifier, e.g. \"iPhone 17 Pro\". Default: latest iPhone Pro / iPad Pro 11-inch.")
    var model: String?

    @Option(name: .long, help: "iOS version, e.g. 26 or 26.5. Default: latest installed runtime supporting the model.")
    var os: String?

    var spec: DeviceSpec { DeviceSpec(family: family, model: model, os: os) }
    var isEmpty: Bool { family == nil && model == nil && os == nil }
}

extension DeviceSpec.Family: ExpressibleByArgument {}

struct OutputOptions: ParsableArguments {
    @Flag(name: [.customShort("j"), .long], help: "Print JSON to stdout instead of text.")
    var json = false
}

/// Every positional device argument is shown the same way, because names and UDIDs are interchangeable everywhere.
enum DeviceRef {
    static let valueName = "name|udid"
}

enum Runtime {
    static let version = SimctlHouse.configuration.version

    static func pool(log: @escaping @Sendable (String) -> Void = note) throws -> Pool {
        Pool(paths: HousePaths.fromEnvironment(), config: try PoolConfig.fromEnvironment(), log: log)
    }

    /// Runs a command body, mapping simctlhouse errors to a stderr message and a distinct exit code.
    static func run(_ body: (Pool) throws -> Void) throws {
        try run { try body(pool()) }
    }

    /// Runs a command that leaves something for the daemon to watch, then makes sure a daemon runs.
    static func runStartingDaemon(_ body: (Pool) throws -> Void) throws {
        try run {
            try DaemonLauncher(paths: HousePaths.fromEnvironment()).ensureRunning(after: { try body(pool()) }, warn: note)
        }
    }

    static func run(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as SimctlHouseError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            throw ExitCode(error.exitCode)
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        print(try json(value))
    }

    /// What `--json` prints. Scripts read it, so its keys and formats are API like the exit codes.
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: - Commands

struct Acquire: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lease a free matching device (creating one if needed), boot it, and print its UDID.",
        discussion: """
            Use the UDID with `xcodebuild -destination id=<UDID>` or `xcrun simctl <cmd> <UDID>`. Release it when done.
            Pass a device name or UDID to lease that specific free device instead, e.g. one you used before.
            """
    )

    @Argument(help: ArgumentHelp("Lease this free pool device instead of any matching one.", valueName: DeviceRef.valueName))
    var device: String?

    @OptionGroup var spec: SpecOptions
    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Label identifying the agent/task holding the lease. Default: $SIMCTLHOUSE_HOLDER, else the agent and directory.")
    var holder: String?

    func validate() throws {
        if device != nil && !spec.isEmpty { throw ValidationError("Pass a device name/UDID or --family/--model/--os, not both.") }
    }

    func run() throws {
        try Runtime.runStartingDaemon { pool in
            let request = AcquireRequest(
                spec: spec.spec,
                device: device,
                holder: holder ?? ProcessInfo.processInfo.environment["SIMCTLHOUSE_HOLDER"] ?? DefaultHolder.label(),
                pid: getppid(),
                cwd: FileManager.default.currentDirectoryPath
            )
            let device = try pool.acquire(request)
            if output.json {
                try Runtime.printJSON(device)
            } else {
                Runtime.note("Acquired \(device.name) (\(device.model), iOS \(device.os)). Lease expires in \(Format.leaseLength(pool.config.leaseDuration)).")
                print(device.udid ?? "")
            }
        }
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Return a leased device to the pool. It stays booted for fast reuse.")

    @Argument(help: ArgumentHelp("The leased device.", valueName: DeviceRef.valueName))
    var device: String

    @Option(name: .long, help: "Only release if the device is still held under this lease ID.")
    var leaseId: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runtime.runStartingDaemon { pool in
            let info = try pool.release(device, leaseId: leaseId)
            if output.json { try Runtime.printJSON(info) } else { Runtime.note(Format.released(info, idleShutdown: pool.config.idleShutdown)) }
        }
    }
}

struct Renew: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Extend a lease by another full lease length (default 30 minutes) from now.")

    @Argument(help: ArgumentHelp("The leased device.", valueName: DeviceRef.valueName))
    var device: String

    @Option(name: .long, help: "Only renew if the device is still held under this lease ID.")
    var leaseId: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runtime.runStartingDaemon { pool in
            let info = try pool.renew(device, leaseId: leaseId)
            if output.json {
                try Runtime.printJSON(info)
            } else {
                Runtime.note("Renewed \(info.name). Lease expires in \(Format.leaseLength(pool.config.leaseDuration)).")
            }
        }
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Lease a device, run a command on it, and release the device when the command exits.",
        discussion: """
            simctlhouse run --holder "fix login" -- xcodebuild test -scheme App

            run is for one self-contained command, such as an end-to-end test run: the device goes back to the pool \
            when the command exits, and the next run may get another. For several steps on one device \
            (install, launch, screenshot), use acquire and release.

            xcodebuild run directly gets -destination id=<UDID> added; a -destination naming another simulator is \
            refused. Elsewhere, {udid} and {name} in the command are replaced, and the command sees \
            $SIMCTLHOUSE_UDID, $SIMCTLHOUSE_DEVICE and $SIMCTLHOUSE_LEASE_ID. With --count N, xcodebuild gets one \
            -destination per device (it tests on all of them at once), and other commands read the space-separated \
            $SIMCTLHOUSE_UDIDS and $SIMCTLHOUSE_DEVICES.

            The lease lasts as long as the command: no renew needed. The devices are released however the command \
            ends, also on failure, Ctrl-C or SIGTERM (forwarded to the command, which is killed if it has not exited \
            15s later). If simctlhouse itself is killed, the devices are reclaimed within a minute. stdout is the \
            command's alone; simctlhouse writes to stderr, prefixed with "simctlhouse:".

            Exit code: the command's own, or 128+N if signal N ended it. simctlhouse's own failures use codes \
            commands rarely do: 124 --timeout passed, 125 simctlhouse failed (see stderr; also when the lease was \
            lost mid-run), 126 the command cannot be executed, 127 the command was not found.
            """
    )

    @Argument(help: ArgumentHelp("Lease this free pool device instead of any matching one.", valueName: DeviceRef.valueName))
    var device: String?

    @OptionGroup var spec: SpecOptions

    @Option(name: .long, help: "Label identifying the agent/task holding the lease. Default: $SIMCTLHOUSE_HOLDER, else the agent, directory and command.")
    var holder: String?

    @Option(name: .long, help: "How many devices to lease, for xcodebuild testing on several simulators at once.")
    var count = 1

    @Option(name: .long, help: ArgumentHelp("Stop the command after this many seconds and exit with 124.", valueName: "seconds"))
    var timeout: Double?

    @Argument(parsing: .postTerminator, help: ArgumentHelp("The command to run, after --.", valueName: "command"))
    var command: [String] = []

    func validate() throws {
        if device != nil && !spec.isEmpty { throw ValidationError("Pass a device name/UDID or --family/--model/--os, not both.") }
        if count < 1 { throw ValidationError("--count must be 1 or more.") }
        if device != nil && count > 1 { throw ValidationError("A specific device is one device; drop --count or the device.") }
        if let timeout, !(timeout > 0 && timeout.isFinite) { throw ValidationError("--timeout must be more than 0 seconds.") }
        if command.isEmpty { throw ValidationError("Pass the command after --, e.g. simctlhouse run -- xcodebuild test -scheme App.") }
    }

    func run() throws {
        let outcome: RunOutcome
        do {
            let daemonEnabled = try DaemonLauncher.isEnabled()
            let pool = try Runtime.pool(log: Self.note)
            let launcher = DaemonLauncher(paths: pool.store.paths)
            let runner = Runner(pool: pool, log: Self.note) {
                guard daemonEnabled else { return }
                do { try launcher.ensureRunning() } catch { Self.note("warning: could not start the simctlhouse daemon: \(error)") }
            }
            let environment = ProcessInfo.processInfo.environment
            let request = AcquireRequest(
                spec: spec.spec,
                device: device,
                holder: holder ?? environment["SIMCTLHOUSE_HOLDER"] ?? DefaultHolder.label(command: command),
                pid: getppid(),
                cwd: FileManager.default.currentDirectoryPath
            )
            outcome = try runner.run(RunRequest(acquire: request, count: count, command: command, timeout: timeout, environment: environment))
        } catch {
            Self.note("error: \((error as? SimctlHouseError)?.description ?? "\(error)")")
            throw ExitCode(RunExitCode.failed)
        }
        if case .signaled(let signal) = outcome, Self.reraised.contains(signal) {
            // Die of the same signal, so a calling shell sees the command was interrupted (and stops its script on Ctrl-C).
            Darwin.signal(signal, SIG_DFL)
            kill(getpid(), signal)
        }
        if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }

    /// Signals that end a process without a crash report. Re-raising a crash signal (SIGSEGV, SIGABRT) would file
    /// a crash report against simctlhouse, so the command's crash is reported as 128+N instead.
    static let reraised: Set<Int32> = [SIGINT, SIGTERM, SIGHUP, SIGKILL, SIGPIPE, SIGALRM, SIGUSR1, SIGUSR2]

    static func note(_ message: String) { Runtime.note("simctlhouse: \(message)") }
}

struct UDID: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "udid",
        abstract: "Print a device's UDID.",
        discussion: "For scripts that know a device by name: `xcodebuild -destination \"id=$(simctlhouse udid amber-falcon)\"`."
    )

    @Argument(help: ArgumentHelp("The device.", valueName: DeviceRef.valueName))
    var device: String

    func run() throws {
        try Runtime.run { pool in print(try pool.udid(of: device)) }
    }
}

/// `simctlhouse version`, for everyone who types it instead of `--version`.
struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the version, like --version.")

    func run() throws {
        print(Runtime.version)
    }
}

struct Home: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the state directory, or open it in Finder.",
        discussion: """
            It holds state.json, the daemon's log and the locks: ~/.simctlhouse, or $SIMCTLHOUSE_HOME.
            For scripts: `tail "$(simctlhouse home)/daemon.log"`.
            """
    )

    @Flag(name: .long, help: "Open it in Finder.")
    var open = false

    func run() throws {
        try Runtime.run {
            let root = HousePaths.fromEnvironment().root
            print(root.path)
            guard open else { return }
            // Nothing has run here yet; an empty directory beats an error.
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let finder = Process()
            finder.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            finder.arguments = [root.path]
            do {
                try finder.run()
                finder.waitUntilExit()
            } catch {
                throw SimctlHouseError.io("Cannot open \(root.path) in Finder: \(error.localizedDescription)")
            }
            guard finder.terminationStatus == 0 else { throw SimctlHouseError.io("Cannot open \(root.path) in Finder.") }
        }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List simctlhouse devices.",
        discussion: """
            Filters work like `simctl list devices`:
              simctlhouse list booted      by state: booted, shutdown
              simctlhouse list leased      by status: available, leased,
                                           provisioning, maintenance
              simctlhouse list agent-7     by search term: name, UDID, model,
                                           iOS version or holder
            Every keyword must match; a device matching any search term is shown.
            No match prints nothing. `simctlhouse udid` fails with exit code 3.
            """
    )

    @Argument(help: ArgumentHelp("State or status keywords and search terms. Default: all devices.", valueName: "filter"))
    var filters: [String] = []

    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runtime.run { pool in
            let devices = try pool.list(DeviceFilter(filters))
            if output.json {
                try Runtime.printJSON(devices)
                return
            }
            guard !devices.isEmpty else {
                Runtime.note(filters.isEmpty ? "No devices yet. `simctlhouse acquire` creates one on demand." : "No matching devices.")
                return
            }
            print(Format.table(devices))
        }
    }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show who held devices, when, and how each lease ended.",
        discussion: """
            Each device remembers its last \(PoolDevice.historyLimit) leases. Devices that left the pool (deleted, vanished, \
            or renamed after an expired lease) stay queryable by their old name or UDID; the last \(PoolState.retiredLimit) are kept.
            Times are local.
            """
    )

    @Argument(help: ArgumentHelp("Only this device, including one that left the pool. Default: every device.", valueName: DeviceRef.valueName))
    var device: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runtime.run { pool in
            let histories = try pool.history(device)
            if output.json {
                try Runtime.printJSON(histories)
                return
            }
            if device != nil, let history = histories.first {
                print(Format.historyHeader(history))
                if history.leases.isEmpty {
                    Runtime.note("No leases recorded.")
                } else {
                    print("")
                    print(Format.leaseTable(history.leases.map { (history, $0) }, showDevice: false))
                }
                return
            }
            let leases = histories.flatMap { history in history.leases.map { (history, $0) } }.sorted { $0.1.acquiredAt < $1.1.acquiredAt }
            guard !leases.isEmpty else {
                Runtime.note("No leases recorded yet.")
                return
            }
            print(Format.leaseTable(leases, showDevice: true))
        }
    }
}

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add a new free device to the pool without leasing it.")

    @OptionGroup var spec: SpecOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runtime.run { pool in
            let info = try pool.create(spec.spec)
            if output.json {
                try Runtime.printJSON(info)
            } else {
                Runtime.note("Created \(info.name) (\(info.model), iOS \(info.os)).")
                print(info.name)
            }
        }
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shut down and delete pool devices.",
        discussion: """
            --unused deletes free devices that nobody acquired, released or renewed for --for (default 7d), to get their disk space back:
            a simulator that has booted takes about 2.4 GB. Leased and busy devices, and free ones another process uses, are skipped.
            The next acquire that needs such a device creates a new one, whose first boot takes about 30s.
            """
    )

    @Argument(help: ArgumentHelp("Devices to delete.", valueName: DeviceRef.valueName))
    var devices: [String] = []

    @Flag(name: .long, help: "Delete every simctlhouse device.")
    var all = false

    @Flag(name: .long, help: "Delete free devices nobody has used for --for.")
    var unused = false

    @Option(
        name: .customLong("for"),
        help: ArgumentHelp("With --unused: how long unused, e.g. 7d, 12h, 30m, 45s, or 0 for every free device.", valueName: "duration"))
    var age: Age?

    @Flag(name: .long, help: "With --unused: show what would be deleted, and delete nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Delete even if leased.")
    var force = false

    @Flag(name: [.customShort("j"), .long], help: "With --unused: print the deleted devices as JSON to stdout.")
    var json = false

    func validate() throws {
        if [!devices.isEmpty, all, unused].filter({ $0 }).count != 1 {
            throw ValidationError("Pass device names/UDIDs, --all or --unused: exactly one of them.")
        }
        if !unused, age != nil || dryRun || json { throw ValidationError("--for, --dry-run and --json go with --unused.") }
        if unused, force { throw ValidationError("--unused never deletes leased devices; --force does not apply.") }
    }

    func run() throws {
        try Runtime.run { pool in
            guard unused else {
                _ = all ? try pool.deleteAll(force: force) : try pool.delete(devices, force: force)
                return
            }
            let age = self.age ?? .week
            let verb = dryRun ? "Would delete" : "Deleted"
            let devices = try pool.deleteUnused(age: age.seconds, dryRun: dryRun) { device in
                let size = device.bytes.map { Format.bytes($0) + ", " } ?? ""
                Runtime.note("\(verb) \(device.name) (\(size)unused for \(Format.age(since: device.lastUsedAt))).")
            }
            if json { try Runtime.printJSON(devices) }
            Runtime.note(Format.unusedSummary(devices, age: age, dryRun: dryRun))
        }
    }

    /// How long a device must have gone unused: a number with a unit, d, h, m or s, or 0.
    struct Age: ExpressibleByArgument, Equatable {
        static let week = Age(seconds: 7 * 24 * 3600, text: "7d")

        var seconds: TimeInterval
        var text: String

        init(seconds: TimeInterval, text: String) {
            self.seconds = seconds
            self.text = text
        }

        init?(argument: String) {
            if argument == "0" {
                self.init(seconds: 0, text: "0s")
                return
            }
            let units: [Character: TimeInterval] = ["d": 24 * 3600, "h": 3600, "m": 60, "s": 1]
            guard let unit = argument.last.flatMap({ units[$0] }), let count = Int(argument.dropLast()), count >= 0 else { return nil }
            self.init(seconds: TimeInterval(count) * unit, text: argument)
        }
    }
}

struct Erase: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Erase a device back to a pristine, shut down state. Keeps its name and UDID.")

    @Argument(help: ArgumentHelp("The device to erase.", valueName: DeviceRef.valueName))
    var device: String

    @Flag(name: .long, help: "Erase even if leased (ends the lease).")
    var force = false

    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runtime.run { pool in
            let info = try pool.erase(device, force: force)
            if output.json { try Runtime.printJSON(info) } else { Runtime.note("Erased \(info.name).") }
        }
    }
}

struct GC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Reclaim expired leases and shut down every free booted device now.",
        discussion: """
            The daemon, and every command first, already reclaim expired leases and shut down devices idle for 15 minutes ($SIMCTLHOUSE_IDLE_SECONDS).
            `gc` also shuts down free devices that have not been idle that long, for example to free CPU and memory.
            Devices another process is using are left running.
            """
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runtime.run { pool in
            let report = try pool.collectGarbage(shutDownAllFree: true)
            if output.json { try Runtime.printJSON(report) } else if report.isEmpty { Runtime.note("Nothing to do.") }
        }
    }
}

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Inspect or control the background daemon that enforces lease expiry and idle shutdown on time.",
        discussion: """
            `acquire`, `release` and `renew` start the daemon when none runs, or when one of another simctlhouse build runs.
            It reclaims expired leases and shuts down idle free devices as they come due, and exits once nothing is leased, booted or in progress.
            Without it, every command still does the same work first.
            It logs to <home>/daemon.log. Set SIMCTLHOUSE_DAEMON=0 to never start it.
            """,
        subcommands: [Start.self, Serve.self, Status.self, Stop.self]
    )

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the daemon in the background unless it runs, and wait until it does.",
            discussion: """
                It takes its timeouts from this command's environment, e.g. SIMCTLHOUSE_IDLE_SECONDS=1 simctlhouse daemon start.
                It keeps running for --keep-alive seconds even with nothing to watch, and after that until nothing is leased, booted or in progress.
                A running daemon that would stop sooner is restarted with the longer keep-alive.
                Daemons that commands start have no keep-alive; when a command replaces this one after an upgrade, the keep-alive ends.
                With --keep-alive 0 and nothing to watch, it starts nothing: the daemon would exit right away.
                """
        )

        @Option(name: .long, help: ArgumentHelp("Seconds to keep running, even with nothing to watch.", valueName: "seconds"))
        var keepAlive: Int = 30 * 60

        func validate() throws {
            guard keepAlive >= 0 else { throw ValidationError("--keep-alive must be 0 or more seconds.") }
        }

        func run() throws {
            try Runtime.run { pool in
                if keepAlive == 0, try !pool.hasWorkForDaemon() {
                    Runtime.note("Not started: nothing is leased, booted or in progress. The next acquire, release or renew starts it.")
                    return
                }
                let launcher = DaemonLauncher(paths: HousePaths.fromEnvironment())
                let (outcome, state) = try launcher.start(keepAlive: TimeInterval(keepAlive))
                let until = (try? launcher.status())?.daemon?.keepAliveUntil.map { " It keeps running until \(Format.timestamp($0))." } ?? ""
                switch (outcome, state) {
                case (.running, _): Runtime.note("Already running.\(until)")
                case (_, .exited): Runtime.note("Started, but nothing is leased, booted or in progress, so it exited again.")
                case (.restarting, .waiting): Runtime.note("Asked the running daemon to stop; one kept alive longer takes over once it has.")
                case (_, .waiting): Runtime.note("Asked the daemon of another build to stop; this build takes over once it has.")
                case (.started, .running): Runtime.note("Started.\(until)")
                case (.replacing, .running): Runtime.note("Replaced the daemon of another build.\(until)")
                case (.restarting, .running): Runtime.note("Restarted it to keep it running longer.\(until)")
                }
            }
        }
    }

    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the daemon in the foreground. Commands start it on their own.",
            discussion: """
                It keeps running for --keep-alive seconds even with nothing to watch, and after that until nothing is leased, booted or in progress.
                Commands start it with --keep-alive 0, so it exits as soon as the pool is idle.
                """
        )

        @Flag(name: .long, help: "Log to <home>/daemon.log instead of stderr, as commands start it.")
        var logFile = false

        @Flag(name: .long, help: "Wait for a running daemon to exit and take over, as commands start the replacement for another build.")
        var takeOver = false

        @Option(name: .long, help: ArgumentHelp("Seconds to keep running, even with nothing to watch.", valueName: "seconds"))
        var keepAlive: Int = 30 * 60

        func validate() throws {
            guard keepAlive >= 0 else { throw ValidationError("--keep-alive must be 0 or more seconds.") }
        }

        func run() throws {
            try Runtime.run {
                let signals = DaemonSignals()
                let handlers = [SIGTERM, SIGINT].map { number in
                    signal(number, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: number)
                    source.setEventHandler { signals.stop() }
                    source.resume()
                    return source
                }
                defer { handlers.forEach { $0.cancel() } }
                signal(SIGHUP, SIG_IGN)
                // Hold no directory busy, such as the one of the command that started it.
                chdir("/")
                let pool = try Runtime.pool { message in Runtime.note("\(Format.timestamp(Date()))  \(message)") }
                let daemon = Daemon(pool: pool, version: Runtime.version, signals: signals)
                let outcome = try daemon.serve(takeOver: takeOver, keepAlive: TimeInterval(keepAlive)) {
                    if logFile { try DaemonLauncher.redirectOutput(to: pool.store.paths) }
                }
                if case .alreadyRunning(let record) = outcome {
                    Runtime.note("A daemon is already running\(record.map { " (pid \($0.pid))" } ?? "").")
                }
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the daemon runs, and which build.")

        @OptionGroup var output: OutputOptions

        func run() throws {
            try Runtime.run {
                let status = try DaemonLauncher(paths: HousePaths.fromEnvironment()).status()
                if output.json {
                    try Runtime.printJSON(status)
                    return
                }
                guard status.running else {
                    let enabled = (try? DaemonLauncher.isEnabled()) ?? true
                    Runtime.note(
                        enabled
                            ? "Not running. The next acquire, release or renew starts it."
                            : "Not running. SIMCTLHOUSE_DAEMON=0 keeps commands from starting it.")
                    return
                }
                guard let daemon = status.daemon else {
                    Runtime.note("Starting.")
                    return
                }
                print("Running since \(Format.timestamp(daemon.startedAt)), pid \(daemon.pid), version \(daemon.version)")
                if let until = daemon.keepAliveUntil, until > Date() {
                    print("Kept alive until \(Format.timestamp(until)), then until nothing is leased, booted or in progress")
                }
                print(
                    "Binary: \(Format.path(daemon.build.executable))\(status.isCurrentBuild == false ? " (another build; the next command replaces it)" : "")")
                print("Log: \(Format.path(HousePaths.fromEnvironment().daemonLog.path))")
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the daemon. The next acquire, release or renew starts it again; until then every command does its work."
        )

        func run() throws {
            try Runtime.run {
                let launcher = DaemonLauncher(paths: HousePaths.fromEnvironment())
                guard try launcher.status().running else {
                    Runtime.note("Not running.")
                    return
                }
                guard try launcher.stop() else { throw SimctlHouseError.io("The daemon did not stop. See `simctlhouse daemon status`.") }
                Runtime.note("Stopped.")
            }
        }
    }
}

struct Skill: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Link the agent skill into your coding agents' skills directories.",
        discussion: """
            The skill ships with the binary in <prefix>/share/simctlhouse/skills.
            `skill install` links it into the skills directory of each agent set up here:
              Claude Code  ~/.claude/skills
              Codex        ~/.codex/skills
              pi           ~/.pi/agent/skills ($PI_CODING_AGENT_DIR/skills)
            or into the --skills-dir directories you name instead.
            --source links another skill directory, such as a checkout's skills/simctlhouse (scripts/install.sh does that).
            The links point at the prefix, so `brew upgrade simctlhouse` updates the skill.
            Anything else at the link location is left alone.
            """,
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    struct DirectoryOptions: ParsableArguments {
        @Option(name: .long, help: "A skills directory to use instead of the detected agents' ones. Repeatable.")
        var skillsDir: [String] = []

        var directories: [URL] {
            skillsDir.isEmpty
                ? SkillInstaller.fromEnvironment().detectedSkillsDirectories()
                : skillsDir.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Link the skill shipped with this binary, or the one at --source, into each agent.")

        @Option(name: .long, help: ArgumentHelp("Link this skill directory instead, e.g. a checkout's skills/simctlhouse.", valueName: "dir"))
        var source: String?

        @OptionGroup var directories: DirectoryOptions
        @OptionGroup var output: OutputOptions

        func run() throws {
            try Runtime.run {
                let source = try source.map { try SkillInstaller.skill(at: NSString(string: $0).expandingTildeInPath) } ?? shippedSkill()
                if SkillInstaller.isVersioned(source) {
                    Runtime.note("warning: \(source.path) is versioned and goes away on the next upgrade. Run simctlhouse from $(brew --prefix)/bin instead.")
                }
                let links = try SkillInstaller.fromEnvironment().install(source, into: directories.directories)
                if output.json {
                    try Runtime.printJSON(links)
                    return
                }
                if links.isEmpty { Runtime.note(Skill.noAgentsFound) }
                for link in links { Runtime.note("Linked \(Format.path(link.path)) -> \(Format.path(link.target))") }
            }
        }

        private func shippedSkill() throws -> URL {
            let executable = SkillInstaller.currentExecutable()
            guard let source = SkillInstaller.shippedSkill(executable: executable) else { throw SimctlHouseError.skillNotShipped(executable: executable.path) }
            return source
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the skill links, including broken ones left by an uninstalled package.")

        @OptionGroup var directories: DirectoryOptions
        @OptionGroup var output: OutputOptions

        func run() throws {
            try Runtime.run {
                let before = SkillInstaller.fromEnvironment().status(in: directories.directories)
                let links = try SkillInstaller.fromEnvironment().uninstall(from: directories.directories)
                if output.json {
                    try Runtime.printJSON(links)
                    return
                }
                for (old, new) in zip(before, links) {
                    switch old.status {
                    case .linked, .broken: Runtime.note("Removed \(Format.path(new.path))")
                    case .missing: Runtime.note("No skill link at \(Format.path(new.path))")
                    case .foreign: Runtime.note("Left \(Format.path(new.path)) alone: not a simctlhouse skill link")
                    }
                }
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show where each agent's skill link points and whether it works.")

        @OptionGroup var directories: DirectoryOptions
        @OptionGroup var output: OutputOptions

        func run() throws {
            try Runtime.run {
                let links = SkillInstaller.fromEnvironment().status(in: directories.directories)
                if output.json {
                    try Runtime.printJSON(links)
                    return
                }
                guard !links.isEmpty else {
                    Runtime.note(Skill.noAgentsFound)
                    return
                }
                print(Format.skillTable(links))
            }
        }
    }

    static let noAgentsFound = "No agent skills directory found (looked for Claude Code, Codex and pi). Pass --skills-dir for your agent."
}

// MARK: - Formatting

enum Format {
    static func minutes(until date: Date?) -> String {
        guard let date else { return "-" }
        return remaining(date.timeIntervalSinceNow)
    }

    /// How long a lease just granted by `acquire` or `renew` lasts. They set its clock right before printing,
    /// and its stored `expiresAt` lost the fraction of a second, so counting down to it would show 59s for a 60s lease.
    static func leaseLength(_ duration: TimeInterval) -> String { remaining(duration) }

    private static func remaining(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds <= 0 { return "expired" }
        return seconds < 60 ? "\(seconds)s" : "\((seconds + 30) / 60)m"
    }

    /// How long ago, in the largest whole unit: 9d, 5h, 12m, 30s.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds >= 24 * 3600 { return "\(seconds / (24 * 3600))d" }
        if seconds >= 3600 { return "\(seconds / 3600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func unusedSummary(_ devices: [UnusedDevice], age: Delete.Age, dryRun: Bool) -> String {
        guard !devices.isEmpty else {
            return age.seconds == 0 ? "No free device to delete." : "No free device has been unused for \(age.text)."
        }
        let count = devices.count == 1 ? "1 device" : "\(devices.count) devices"
        let total = bytes(devices.compactMap(\.bytes).reduce(0, +))
        return dryRun ? "Would delete \(count), freeing \(total)." : "Deleted \(count), freed \(total)."
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(String(format: "%02d", seconds % 3600 / 60))m"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

    static func path(_ path: String?) -> String {
        guard let path else { return "-" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func table(_ devices: [DeviceInfo]) -> String {
        let header = ["NAME", "STATUS", "STATE", "MODEL", "OS", "HOLDER", "NEXT", "UDID"]
        let rows = devices.map { device in
            [
                device.name,
                device.status.rawValue,
                device.state,
                device.model,
                device.os,
                device.holder ?? "-",
                next(device),
                device.udid ?? "-",
            ]
        }
        return columns([header] + rows)
    }

    /// What the daemon does to the device next, and when: a lease expiring, or a free device shutting down.
    static func next(_ device: DeviceInfo) -> String {
        if device.status == .leased, let pid = device.ownerPid { return "until pid \(pid) exits" }
        if device.status == .leased, let expiresAt = device.expiresAt {
            let left = minutes(until: expiresAt)
            return left == "expired" ? "expired" : "expires in \(left)"
        }
        if let shutdownAt = device.shutdownAt {
            let left = minutes(until: shutdownAt)
            return left == "expired" ? "shutdown due" : "shutdown in \(left)"
        }
        return "-"
    }

    /// Tells whoever released the device how long it stays warm for the next agent.
    /// A device released just now shows the full idle time, for the same reason as `leaseLength`;
    /// one that was already free (release is idempotent) counts down to its stored shutdown time.
    static func released(_ device: DeviceInfo, idleShutdown: TimeInterval) -> String {
        guard let shutdownAt = device.shutdownAt else { return "Released \(device.name)." }
        let interval = shutdownAt.timeIntervalSinceNow
        let left = remaining(idleShutdown - interval < 2 ? idleShutdown : interval)
        if left == "expired" { return "Released \(device.name). It shuts down now." }
        return "Released \(device.name). It stays booted for \(left) for the next agent."
    }

    static func skillTable(_ links: [SkillLink]) -> String {
        columns([["LINK", "STATUS", "TARGET"]] + links.map { [path($0.path), $0.status.rawValue, path($0.target)] })
    }

    static func historyHeader(_ history: DeviceHistory) -> String {
        var lines = ["\(history.name)  \(history.model), iOS \(history.os)  \(history.udid ?? "no UDID")"]
        if let retiredAt = history.retiredAt, let reason = history.retiredReason {
            lines.append("Created \(timestamp(history.createdAt)), left the pool \(timestamp(retiredAt)) (\(reason.rawValue)).")
        } else {
            lines.append("Created \(timestamp(history.createdAt)), in the pool.")
        }
        return lines.joined(separator: "\n")
    }

    static func leaseTable(_ leases: [(DeviceHistory, LeaseRecord)], showDevice: Bool) -> String {
        let header = (showDevice ? ["DEVICE"] : []) + ["ACQUIRED", "ENDED", "HELD", "OUTCOME", "HOLDER", "PID", "CWD"]
        let rows = leases.map { history, lease in
            (showDevice ? [history.name] : []) + [
                timestamp(lease.acquiredAt),
                lease.endedAt.map(timestamp) ?? "-",
                duration(from: lease.acquiredAt, to: lease.endedAt ?? Date()),
                lease.outcome?.rawValue ?? "active",
                lease.holder ?? "-",
                lease.pid.map(String.init) ?? "-",
                path(lease.cwd),
            ]
        }
        return columns([header] + rows)
    }

    private static func columns(_ rows: [[String]]) -> String {
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max()! }
        return
            rows
            .map { row in row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }
}

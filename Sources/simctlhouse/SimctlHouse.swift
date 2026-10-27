import ArgumentParser
import Foundation
import SimctlHouseCore

@main
struct SimctlHouse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simctlhouse",
        abstract: "Device Hub for Agents: a pool of iOS simulators that agents lease exclusively.",
        discussion: """
            Each agent acquires its own simulator, uses it via its UDID, and releases it when done.
            Leases expire after 30 minutes (extend with `renew`); expired devices are erased and returned to the pool.
            Free devices shut down after 15 minutes of inactivity. simctlhouse only touches devices it created.
            Both timeouts can be changed with environment variables, see below; an idle time of 0 shuts free devices down on the next command.
            Wherever a command takes a device, its name and its UDID both work.

            Machine-readable output goes to stdout, human messages to stderr.
            Commands that print device information accept --json (short: -j) for JSON on stdout.

            Environment:
              SIMCTLHOUSE_LEASE_SECONDS  lease length in seconds (default 1800)
              SIMCTLHOUSE_IDLE_SECONDS   idle seconds before shutdown (default 900)
              SIMCTLHOUSE_HOLDER         default --holder label
              SIMCTLHOUSE_HOME           state directory (default ~/.simctlhouse)
            """,
        version: "0.1.0",
        subcommands: [Acquire.self, Release.self, Renew.self, List.self, UDID.self, History.self, Create.self, Delete.self, Erase.self, GC.self]
    )
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
    static func pool() throws -> Pool {
        Pool(
            paths: HousePaths.fromEnvironment(),
            config: try PoolConfig.fromEnvironment(),
            log: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) }
        )
    }

    /// Runs a command body, mapping simctlhouse errors to a stderr message and a distinct exit code.
    static func run(_ body: (Pool) throws -> Void) throws {
        do {
            try body(pool())
        } catch let error as SimctlHouseError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            throw ExitCode(error.exitCode)
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
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

    @Option(name: .long, help: "Label identifying the agent/task holding the lease. Default: $SIMCTLHOUSE_HOLDER.")
    var holder: String?

    func validate() throws {
        if device != nil && !spec.isEmpty { throw ValidationError("Pass a device name/UDID or --family/--model/--os, not both.") }
    }

    func run() throws {
        try Runtime.run { pool in
            let request = AcquireRequest(
                spec: spec.spec,
                device: device,
                holder: holder ?? ProcessInfo.processInfo.environment["SIMCTLHOUSE_HOLDER"],
                pid: getppid(),
                cwd: FileManager.default.currentDirectoryPath
            )
            let device = try pool.acquire(request)
            if output.json {
                try Runtime.printJSON(device)
            } else {
                Runtime.note("Acquired \(device.name) (\(device.model), iOS \(device.os)). Lease expires in \(Format.minutes(until: device.expiresAt)).")
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
        try Runtime.run { pool in
            let info = try pool.release(device, leaseId: leaseId)
            if output.json { try Runtime.printJSON(info) } else { Runtime.note("Released \(info.name).") }
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
        try Runtime.run { pool in
            let info = try pool.renew(device, leaseId: leaseId)
            if output.json {
                try Runtime.printJSON(info)
            } else {
                Runtime.note("Renewed \(info.name). Lease expires in \(Format.minutes(until: info.expiresAt)).")
            }
        }
    }
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
    static let configuration = CommandConfiguration(abstract: "Shut down and delete pool devices.")

    @Argument(help: ArgumentHelp("Devices to delete.", valueName: DeviceRef.valueName))
    var devices: [String] = []

    @Flag(name: .long, help: "Delete every simctlhouse device.")
    var all = false

    @Flag(name: .long, help: "Delete even if leased.")
    var force = false

    func validate() throws {
        if all != devices.isEmpty { throw ValidationError("Pass device names/UDIDs or --all, not both or neither.") }
    }

    func run() throws {
        try Runtime.run { pool in
            _ = all ? try pool.deleteAll(force: force) : try pool.delete(devices, force: force)
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
            Every command already reclaims expired leases and shuts down devices idle for 15 minutes ($SIMCTLHOUSE_IDLE_SECONDS) first.
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

// MARK: - Formatting

enum Format {
    static func minutes(until date: Date?) -> String {
        guard let date else { return "-" }
        let seconds = Int(date.timeIntervalSinceNow.rounded())
        if seconds <= 0 { return "expired" }
        return seconds < 60 ? "\(seconds)s" : "\((seconds + 30) / 60)m"
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
        let header = ["NAME", "STATUS", "STATE", "MODEL", "OS", "HOLDER", "EXPIRES", "UDID"]
        let rows = devices.map { device in
            [
                device.name,
                device.status.rawValue,
                device.state,
                device.model,
                device.os,
                device.holder ?? "-",
                device.status == .leased ? minutes(until: device.expiresAt) : "-",
                device.udid ?? "-",
            ]
        }
        return columns([header] + rows)
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

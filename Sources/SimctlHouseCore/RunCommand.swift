import Foundation

/// A device leased for `simctlhouse run`.
public struct RunDevice: Equatable, Sendable {
    public var name: String
    public var udid: String
    public var leaseId: String

    public init(name: String, udid: String, leaseId: String) {
        self.name = name
        self.udid = udid
        self.leaseId = leaseId
    }
}

/// Turns the command given to `simctlhouse run` into the one it starts, with the leased devices filled in.
///
/// `{udid}` and `{name}` are replaced in every argument. A direct `xcodebuild` (or `xcrun xcodebuild`) without a
/// `-destination` gets one `-destination id=<UDID>` per device; one whose `-destination` names another simulator is
/// refused, because that is how agents end up on a device someone else holds (D34).
public struct RunCommand: Equatable, Sendable {
    public static let udidPlaceholder = "{udid}"
    public static let namePlaceholder = "{name}"

    /// xcodebuild invocations that act on no destination: injecting one would at best be ignored,
    /// and for `archive` it would build for the simulator instead of the generic device the archive needs.
    static let destinationFreeArguments: Set<String> = [
        "-list", "-version", "-showsdks", "-showBuildSettings", "-showdestinations", "-showTestPlans", "-showComponent",
        "-exportArchive", "-exportNotarizedApp", "-exportLocalizations", "-importLocalizations", "-resolvePackageDependencies",
        "-usage", "-help", "-h", "archive",
    ]
    /// xcrun options that take a value, so the tool name can be found after them.
    static let xcrunValueOptions: Set<String> = ["-sdk", "--sdk", "-toolchain", "--toolchain"]

    /// The command to start.
    public var arguments: [String]
    /// The `-destination` options added to an xcodebuild command, to tell the caller.
    public var addedDestinations: [String]

    public init(_ command: [String], devices: [RunDevice]) throws {
        guard !command.isEmpty, !command[0].isEmpty else { throw SimctlHouseError.invalidRunCommand("Pass the command to run after --.") }
        var arguments = command
        if devices.count == 1 {
            arguments = arguments.map {
                $0.replacingOccurrences(of: Self.udidPlaceholder, with: devices[0].udid).replacingOccurrences(of: Self.namePlaceholder, with: devices[0].name)
            }
        } else if arguments.contains(where: { $0.contains(Self.udidPlaceholder) || $0.contains(Self.namePlaceholder) }) {
            throw SimctlHouseError.invalidRunCommand(
                "\(Self.udidPlaceholder) and \(Self.namePlaceholder) stand for one device; with --count, read $\(RunEnvironment.udids) instead.")
        }
        self.addedDestinations = []
        if let tool = Self.xcodebuildIndex(arguments) {
            let added = try Self.destinations(for: Array(arguments[(tool + 1)...]), devices: devices)
            arguments += added
            self.addedDestinations = added.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        }
        self.arguments = arguments
    }

    /// Refuses, before any device is leased, a command that no lease could make valid: placeholders with several
    /// devices, or an xcodebuild `-destination` that is not generic and names neither `{udid}` nor any UDID.
    /// A destination with a literal UDID can only be checked against the leased device, by `init`.
    public static func check(_ command: [String], count: Int) throws {
        let placeholder = RunDevice(name: namePlaceholder, udid: udidPlaceholder, leaseId: "")
        let probe = Array(repeating: placeholder, count: max(count, 1))
        guard !command.isEmpty, !command[0].isEmpty else { throw SimctlHouseError.invalidRunCommand("Pass the command to run after --.") }
        guard let tool = xcodebuildIndex(command) else {
            if count > 1 { _ = try RunCommand(command, devices: probe) }
            return
        }
        let mentionsUDID = command.contains { $0.range(of: udidPattern, options: .regularExpression) != nil }
        if mentionsUDID { return }
        _ = try destinations(for: Array(command[(tool + 1)...]), devices: probe)
        if count > 1 { _ = try RunCommand(command, devices: probe) }
    }

    static let udidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// Where `xcodebuild` sits in the command, when the command runs it directly.
    static func xcodebuildIndex(_ arguments: [String]) -> Int? {
        func name(_ argument: String) -> String { (argument as NSString).lastPathComponent }
        if name(arguments[0]) == "xcodebuild" { return 0 }
        guard name(arguments[0]) == "xcrun" else { return nil }
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if Self.xcrunValueOptions.contains(argument) {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                return name(argument) == "xcodebuild" ? index : nil
            }
        }
        return nil
    }

    /// The `-destination` arguments to append, after checking those already given.
    static func destinations(for arguments: [String], devices: [RunDevice]) throws -> [String] {
        if arguments.contains(where: destinationFreeArguments.contains) { return [] }
        let given = arguments.indices.compactMap { index -> String? in
            guard arguments[index] == "-destination" else { return nil }
            return index + 1 < arguments.count ? arguments[index + 1] : ""
        }
        let udids = devices.map { $0.udid.uppercased() }
        for destination in given {
            let upper = destination.uppercased()
            if upper.hasPrefix("GENERIC/") || udids.contains(where: upper.contains) { continue }
            throw SimctlHouseError.invalidRunCommand(
                "-destination '\(destination)' is not the leased simulator, so xcodebuild would use a device another agent may hold. "
                    + "Drop it: simctlhouse run adds -destination id=<UDID> itself.")
        }
        guard given.isEmpty else { return [] }
        return devices.flatMap { ["-destination", "id=\($0.udid)"] }
    }
}

/// The variables `simctlhouse run` sets for its command.
public enum RunEnvironment {
    public static let udid = "SIMCTLHOUSE_UDID"
    public static let name = "SIMCTLHOUSE_DEVICE"
    public static let leaseId = "SIMCTLHOUSE_LEASE_ID"
    public static let udids = "SIMCTLHOUSE_UDIDS"
    public static let names = "SIMCTLHOUSE_DEVICES"

    /// `environment` with the devices added. The singular variables are set only for a single device,
    /// so a script written for one device fails loudly under `--count` instead of silently using the first.
    public static func adding(_ devices: [RunDevice], to environment: [String: String]) -> [String: String] {
        var environment = environment
        for variable in [udid, name, leaseId] { environment[variable] = nil }
        environment[udids] = devices.map(\.udid).joined(separator: " ")
        environment[names] = devices.map(\.name).joined(separator: " ")
        if devices.count == 1 {
            environment[udid] = devices[0].udid
            environment[name] = devices[0].name
            environment[leaseId] = devices[0].leaseId
        }
        return environment
    }
}

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
/// `{udid}` and `{name}`, and `{udid<i>}` and `{name<i>}` for device `i`, are replaced in every argument (D38).
/// A direct `xcodebuild` (or `xcrun xcodebuild`) without a `-destination` gets one `-destination id=<UDID>` per device;
/// one whose `-destination` names another simulator is refused, because that is how agents end up on a device
/// someone else holds (D34).
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
        var arguments = try Self.substitute(command, devices: devices)
        self.addedDestinations = []
        if let tool = Self.xcodebuildIndex(arguments) {
            let added = try Self.destinations(for: Array(arguments[(tool + 1)...]), devices: devices)
            arguments += added
            self.addedDestinations = added.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        }
        self.arguments = arguments
    }

    /// Refuses, before any device is leased, a command that no lease could make valid: a placeholder for a device
    /// the run does not lease, or an xcodebuild `-destination` that is not generic and names no placeholder or UDID.
    /// A destination with a literal UDID can only be checked against the leased device, by `init`.
    public static func check(_ command: [String], count: Int) throws {
        guard !command.isEmpty, !command[0].isEmpty else { throw SimctlHouseError.invalidRunCommand("Pass the command to run after --.") }
        // Every device stands in as `{udid}`, which a destination check accepts like the leased UDID.
        let probe = Array(repeating: RunDevice(name: namePlaceholder, udid: udidPlaceholder, leaseId: ""), count: max(count, 1))
        let arguments = try substitute(command, devices: probe)
        guard let tool = xcodebuildIndex(arguments) else { return }
        let mentionsUDID = arguments.contains { $0.range(of: udidPattern, options: .regularExpression) != nil }
        if mentionsUDID { return }
        _ = try destinations(for: Array(arguments[(tool + 1)...]), devices: probe)
    }

    /// `arguments` with the placeholders replaced. `{udid}` and `{name}` stand for the only device, and are refused
    /// with several so a command written for one device fails instead of using the first; `{udid<i>}` and `{name<i>}`
    /// name device `i`, counting from 0.
    static func substitute(_ arguments: [String], devices: [RunDevice]) throws -> [String] {
        let placeholder = #/\{(?<field>udid|name)(?<index>\d*)\}/#
        return try arguments.map { argument in
            try argument.replacing(placeholder) { match in
                let field = String(match.output.field)
                let device: RunDevice
                if match.output.index.isEmpty {
                    guard devices.count == 1 else {
                        throw SimctlHouseError.invalidRunCommand(
                            "{\(field)} stands for one device, and this run leases \(devices.count); "
                                + "name each with {\(field)0} to {\(field)\(devices.count - 1)}.")
                    }
                    device = devices[0]
                } else {
                    guard let index = Int(match.output.index), devices.indices.contains(index) else {
                        let available =
                            devices.count == 1
                            ? "one device, so use {\(field)} or {\(field)0}"
                            : "\(devices.count) devices, so use {\(field)0} to {\(field)\(devices.count - 1)}"
                        throw SimctlHouseError.invalidRunCommand(
                            "\(match.output.0) names no device: this run leases \(available), or raise --count to lease more.")
                    }
                    device = devices[index]
                }
                return field == "udid" ? device.udid : device.name
            }
        }
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
    public static let name = "SIMCTLHOUSE_DEVICE_NAME"
    public static let leaseId = "SIMCTLHOUSE_LEASE_ID"
    public static let udids = "SIMCTLHOUSE_UDIDS"
    public static let names = "SIMCTLHOUSE_DEVICE_NAMES"
    /// Separates the devices in `udids` and `names`. Neither UDIDs nor generated names contain it.
    public static let separator = ","

    /// The variable for device `index`, such as `SIMCTLHOUSE_UDID_0`.
    public static func indexed(_ variable: String, _ index: Int) -> String { "\(variable)_\(index)" }

    /// `environment` with the devices added. The singular variables are set only for a single device,
    /// so a script written for one device fails loudly under `--count` instead of silently using the first.
    /// Every variable `run` owns is cleared first: one inherited from an outer `run` would point at a device
    /// this run does not hold.
    public static func adding(_ devices: [RunDevice], to environment: [String: String]) -> [String: String] {
        let owned: Set = [udid, name, leaseId, udids, names]
        let indexedPrefixes = [udid, name, leaseId].map { $0 + "_" }
        var environment = environment.filter { key, _ in
            !owned.contains(key) && !indexedPrefixes.contains { key.hasPrefix($0) && Int(key.dropFirst($0.count)) != nil }
        }
        environment[udids] = devices.map(\.udid).joined(separator: separator)
        environment[names] = devices.map(\.name).joined(separator: separator)
        for (index, device) in devices.enumerated() {
            environment[indexed(udid, index)] = device.udid
            environment[indexed(name, index)] = device.name
            environment[indexed(leaseId, index)] = device.leaseId
        }
        if devices.count == 1 {
            environment[udid] = devices[0].udid
            environment[name] = devices[0].name
            environment[leaseId] = devices[0].leaseId
        }
        return environment
    }
}

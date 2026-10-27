import Foundation

/// Resolves a user-facing `DeviceSpec` into a concrete device type and runtime.
public struct Catalog: Sendable {
    public var deviceTypes: [SimDeviceType]
    public var runtimes: [SimRuntime]

    public init(deviceTypes: [SimDeviceType], runtimes: [SimRuntime]) {
        self.deviceTypes = deviceTypes
        self.runtimes = runtimes
    }

    public init(backend: SimulatorBackend) throws {
        let (deviceTypes, runtimes) = try concurrently({ try backend.deviceTypes() }, { try backend.runtimes() })
        self.init(deviceTypes: deviceTypes, runtimes: runtimes)
    }

    public func resolve(_ spec: DeviceSpec) throws -> ResolvedSpec {
        let deviceType = try resolveDeviceType(spec)
        let candidates =
            iOSRuntimes
            .filter { runtime in runtime.supportedDeviceTypes.contains { $0.identifier == deviceType.identifier } }
            .filter { runtime in spec.os.map { Self.version(runtime.version, matches: $0) } ?? true }
        guard let runtime = candidates.max(by: { Self.compareVersions($0.version, $1.version) }) else {
            throw SimctlHouseError.noRuntime(model: deviceType.name, os: spec.os)
        }
        return ResolvedSpec(deviceType: deviceType, runtime: runtime)
    }

    /// Looks up a runtime by identifier, for describing existing pool devices.
    public func runtime(identifier: String) -> SimRuntime? {
        runtimes.first { $0.identifier == identifier }
    }

    public func deviceType(identifier: String) -> SimDeviceType? {
        deviceTypes.first { $0.identifier == identifier }
    }

    private var iOSRuntimes: [SimRuntime] {
        runtimes.filter { $0.isAvailable && ($0.platform == "iOS" || $0.identifier.contains(".SimRuntime.iOS-")) }
    }

    private var supportedTypes: [SimDeviceType] {
        deviceTypes.filter { $0.productFamily == "iPhone" || $0.productFamily == "iPad" }
    }

    private func resolveDeviceType(_ spec: DeviceSpec) throws -> SimDeviceType {
        if let model = spec.model {
            let needle = model.lowercased()
            guard let match = deviceTypes.first(where: { $0.name.lowercased() == needle || $0.identifier.lowercased() == needle }) else {
                throw SimctlHouseError.unknownModel(model)
            }
            guard supportedTypes.contains(match) else { throw SimctlHouseError.unsupportedModel(match.name) }
            if let family = spec.family, match.productFamily != family.productFamily {
                throw SimctlHouseError.unsupportedModel("\(match.name) is not an \(family.productFamily); '\(model)'")
            }
            return match
        }
        let family = spec.family ?? .iphone
        // Only consider types some installed runtime can actually run, so a brand new type without a runtime is skipped.
        let runnable = Set(iOSRuntimes.flatMap { $0.supportedDeviceTypes.map(\.identifier) })
        let candidates = supportedTypes.filter { type in
            type.productFamily == family.productFamily && runnable.contains(type.identifier) && Self.isDefaultCandidate(type.name, family: family)
        }
        guard let latest = candidates.max(by: { Self.modelOrder($0).lexicographicallyPrecedes(Self.modelOrder($1)) }) else {
            throw SimctlHouseError.unknownModel("default \(family.productFamily)")
        }
        return latest
    }

    /// Default models: the latest "iPhone N Pro" and the latest base-memory "iPad Pro 11-inch".
    static func isDefaultCandidate(_ name: String, family: DeviceSpec.Family) -> Bool {
        switch family {
        case .iphone:
            return name.wholeMatch(of: /iPhone \d+ Pro/) != nil
        case .ipad:
            let isPro11 = name.hasPrefix("iPad Pro 11-inch") || name.hasPrefix("iPad Pro (11-inch)")
            // Apple ships memory variants such as "(16GB)" next to the base model; prefer the base one.
            return isPro11 && name.firstMatch(of: /\(\d+GB\)/) == nil
        }
    }

    /// Orders device types by their hardware model identifier, e.g. `iPad17,2` > `iPad16,4`.
    static func modelOrder(_ type: SimDeviceType) -> [Int] {
        guard let identifier = type.modelIdentifier else { return [] }
        return identifier.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    static func version(_ version: String, matches requested: String) -> Bool {
        version == requested || version.hasPrefix(requested + ".")
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        return left.lexicographicallyPrecedes(right)
    }
}

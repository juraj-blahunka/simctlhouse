import Foundation

public struct SimDevice: Decodable, Equatable, Sendable {
    public var udid: String
    public var name: String
    public var state: String
    public var isAvailable: Bool
    public var deviceTypeIdentifier: String?

    public var isBooted: Bool { state == "Booted" }

    public init(udid: String, name: String, state: String, isAvailable: Bool = true, deviceTypeIdentifier: String? = nil) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.deviceTypeIdentifier = deviceTypeIdentifier
    }
}

public struct SimDeviceType: Decodable, Equatable, Hashable, Sendable {
    public var identifier: String
    public var name: String
    public var productFamily: String?
    public var modelIdentifier: String?

    public init(identifier: String, name: String, productFamily: String?, modelIdentifier: String?) {
        self.identifier = identifier
        self.name = name
        self.productFamily = productFamily
        self.modelIdentifier = modelIdentifier
    }
}

public struct SimRuntime: Decodable, Equatable, Hashable, Sendable {
    public struct SupportedType: Decodable, Equatable, Hashable, Sendable {
        public var identifier: String
    }

    public var identifier: String
    public var name: String
    public var version: String
    public var platform: String?
    public var isAvailable: Bool
    public var supportedDeviceTypes: [SupportedType]

    public init(identifier: String, name: String, version: String, platform: String?, isAvailable: Bool = true, supportedDeviceTypes: [String]) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.platform = platform
        self.isAvailable = isAvailable
        self.supportedDeviceTypes = supportedDeviceTypes.map(SupportedType.init(identifier:))
    }
}

/// Everything simctlhouse needs from CoreSimulator. `Simctl` is the real implementation; tests use a fake.
public protocol SimulatorBackend: Sendable {
    func devices() throws -> [SimDevice]
    func deviceTypes() throws -> [SimDeviceType]
    func runtimes() throws -> [SimRuntime]
    func create(name: String, deviceType: String, runtime: String) throws -> String
    /// Boots the device if needed and blocks until it has finished booting.
    func bootAndWait(udid: String) throws
    func shutdown(udid: String) throws
    func delete(udid: String) throws
    /// Wipes contents and settings of a shut down device, keeping its UDID.
    func erase(udid: String) throws
}

public struct Simctl: SimulatorBackend {
    public init() {}

    public func devices() throws -> [SimDevice] {
        struct Listing: Decodable { var devices: [String: [SimDevice]] }
        let data = try run(["list", "devices", "-j"])
        return try JSONDecoder().decode(Listing.self, from: data).devices.values.flatMap { $0 }
    }

    public func deviceTypes() throws -> [SimDeviceType] {
        struct Listing: Decodable { var devicetypes: [SimDeviceType] }
        return try JSONDecoder().decode(Listing.self, from: run(["list", "devicetypes", "-j"])).devicetypes
    }

    public func runtimes() throws -> [SimRuntime] {
        struct Listing: Decodable { var runtimes: [SimRuntime] }
        return try JSONDecoder().decode(Listing.self, from: run(["list", "runtimes", "-j"])).runtimes
    }

    public func create(name: String, deviceType: String, runtime: String) throws -> String {
        try runForUDID(["create", name, deviceType, runtime])
    }

    public func bootAndWait(udid: String) throws {
        _ = try run(["bootstatus", udid, "-b"])
    }

    public func shutdown(udid: String) throws {
        do {
            _ = try run(["shutdown", udid])
        } catch let error as SimctlHouseError {
            // Shutting down an already shut down device is not a failure for our purposes.
            if case .simctlFailed(_, _, let stderr) = error, stderr.contains("current state: Shutdown") { return }
            throw error
        }
    }

    public func erase(udid: String) throws {
        _ = try run(["erase", udid])
    }

    public func delete(udid: String) throws {
        _ = try run(["delete", udid])
    }

    private func runForUDID(_ arguments: [String]) throws -> String {
        let output = String(decoding: try run(arguments), as: UTF8.self)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ arguments: [String]) throws -> Data {
        let full = ["simctl"] + arguments
        let result = try Subprocess.run("/usr/bin/xcrun", full)
        guard result.status == 0 else {
            throw SimctlHouseError.simctlFailed(command: full.joined(separator: " "), status: result.status, stderr: result.stderr)
        }
        return result.stdout
    }
}

enum Subprocess {
    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain both pipes concurrently so a chatty stderr cannot deadlock a full stdout pipe.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
    }
}

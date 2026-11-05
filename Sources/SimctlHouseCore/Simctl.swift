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
    /// Whether the simulator still exists on disk. `devices()` can briefly leave out devices that exist,
    /// for example while CoreSimulator restarts, so a device is only taken for gone when this says so too (D23).
    func existsOnDisk(udid: String) -> Bool
    /// Disk space the simulator takes, in bytes, or nil if it cannot be measured.
    func diskUsage(udid: String) -> Int64?
}

public struct Simctl: SimulatorBackend {
    /// Runs `xcrun simctl` with the given arguments. Tests pass recorded output instead.
    let execute: @Sendable ([String]) throws -> Subprocess.Result
    /// The default device set, where every pool device lives (D6): one directory per UDID.
    let devicesDirectory: URL

    public init() {
        self.init(execute: { arguments in try Subprocess.run("/usr/bin/xcrun", ["simctl"] + arguments) })
    }

    init(
        execute: @escaping @Sendable ([String]) throws -> Subprocess.Result,
        devicesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/CoreSimulator/Devices")
    ) {
        self.execute = execute
        self.devicesDirectory = devicesDirectory
    }

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

    /// Allocated size of the device's directory, which holds all of its data. Walks the tree, so call it for a few devices only.
    public func diskUsage(udid: String) -> Int64? {
        let directory = devicesDirectory.appending(path: udid)
        guard existsOnDisk(udid: udid),
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [])
        else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// CoreSimulator keeps each device's configuration in `<UDID>/device.plist`; deleting the device removes the directory.
    public func existsOnDisk(udid: String) -> Bool {
        FileManager.default.fileExists(atPath: devicesDirectory.appending(path: udid).appending(path: "device.plist").path)
    }

    private func runForUDID(_ arguments: [String]) throws -> String {
        let output = String(decoding: try run(arguments), as: UTF8.self)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ arguments: [String]) throws -> Data {
        let result = try execute(arguments)
        guard result.status == 0 else {
            // simctl's own errors come from CoreSimulator; an `xcrun: error:` means simctl never ran.
            if result.stderr.hasPrefix("xcrun: error:") { throw SimctlHouseError.xcodeRequired(stderr: result.stderr) }
            throw SimctlHouseError.simctlFailed(command: (["simctl"] + arguments).joined(separator: " "), status: result.status, stderr: result.stderr)
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

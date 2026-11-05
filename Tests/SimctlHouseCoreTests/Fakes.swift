import Foundation
@testable import SimctlHouseCore

/// In-memory CoreSimulator mirroring the bits of `simctl` behaviour simctlhouse relies on.
final class FakeBackend: SimulatorBackend, @unchecked Sendable {
    struct Device {
        var udid: String
        var name: String
        var state: String
        var deviceType: String
        var runtime: String
    }

    private let lock = NSLock()
    private var storage: [String: Device] = [:]
    /// On disk but left out of `devices()`, as by an incomplete listing.
    private var unlisted: Set<String> = []
    private(set) var calls: [String] = []
    var failBoot = false
    var failErase = false
    /// Names of devices whose deletion fails.
    var failDelete: Set<String> = []
    /// Run outside the backend's lock, to act as another process while a slow `simctl` call is in flight.
    var onCreate: (@Sendable () -> Void)?
    var onErase: (@Sendable () -> Void)?
    var onBoot: (@Sendable () -> Void)?

    let types: [SimDeviceType] = [
        SimDeviceType(identifier: "type.iPhone-17-Pro", name: "iPhone 17 Pro", productFamily: "iPhone", modelIdentifier: "iPhone18,1"),
        SimDeviceType(identifier: "type.iPhone-18-Pro", name: "iPhone 18 Pro", productFamily: "iPhone", modelIdentifier: "iPhone19,2"),
        SimDeviceType(identifier: "type.iPhone-18-Pro-Max", name: "iPhone 18 Pro Max", productFamily: "iPhone", modelIdentifier: "iPhone19,3"),
        // Newer than everything but no installed runtime supports it: must never be a default.
        SimDeviceType(identifier: "type.iPhone-19-Pro", name: "iPhone 19 Pro", productFamily: "iPhone", modelIdentifier: "iPhone20,1"),
        SimDeviceType(identifier: "type.iPad-Pro-11-M4", name: "iPad Pro 11-inch (M4)", productFamily: "iPad", modelIdentifier: "iPad16,4"),
        SimDeviceType(identifier: "type.iPad-Pro-11-M5-16GB", name: "iPad Pro 11-inch (M5) (16GB)", productFamily: "iPad", modelIdentifier: "iPad17,2"),
        SimDeviceType(identifier: "type.iPad-Pro-11-M5", name: "iPad Pro 11-inch (M5)", productFamily: "iPad", modelIdentifier: "iPad17,2"),
        SimDeviceType(identifier: "type.iPad-Pro-13-M5", name: "iPad Pro 13-inch (M5)", productFamily: "iPad", modelIdentifier: "iPad17,4"),
        SimDeviceType(identifier: "type.Watch", name: "Apple Watch Ultra 3", productFamily: "Apple Watch", modelIdentifier: "Watch7,12"),
    ]

    lazy var runtimeList: [SimRuntime] = {
        let all = types.filter { $0.name != "iPhone 19 Pro" && $0.productFamily != "Apple Watch" }.map(\.identifier)
        return [
            SimRuntime(identifier: "rt.iOS-2-6", name: "iOS 2.6", version: "2.6", platform: "iOS", supportedDeviceTypes: all),
            SimRuntime(
                identifier: "rt.iOS-26-5", name: "iOS 26.5", version: "26.5", platform: "iOS",
                supportedDeviceTypes: all.filter { !$0.contains("18") && !$0.contains("M5") }),
            SimRuntime(identifier: "rt.iOS-27-0", name: "iOS 27.0", version: "27.0", platform: "iOS", supportedDeviceTypes: all),
            SimRuntime(identifier: "rt.iOS-27-1", name: "iOS 27.1", version: "27.1", platform: "iOS", supportedDeviceTypes: ["type.iPhone-18-Pro-Max"]),
            SimRuntime(identifier: "rt.watchOS-12", name: "watchOS 12", version: "12.0", platform: "watchOS", supportedDeviceTypes: ["type.Watch"]),
        ]
    }()

    func devices() throws -> [SimDevice] {
        lock.withLock {
            storage.values
                .filter { !unlisted.contains($0.udid) }
                .map { SimDevice(udid: $0.udid, name: $0.name, state: $0.state, deviceTypeIdentifier: $0.deviceType) }
        }
    }

    func deviceTypes() throws -> [SimDeviceType] { types }

    func runtimes() throws -> [SimRuntime] { lock.withLock { runtimeList } }

    func create(name: String, deviceType: String, runtime: String) throws -> String {
        onCreate?()
        return lock.withLock {
            calls.append("create \(name)")
            let udid = UUID().uuidString
            storage[udid] = Device(udid: udid, name: name, state: "Shutdown", deviceType: deviceType, runtime: runtime)
            return udid
        }
    }

    func bootAndWait(udid: String) throws {
        onBoot?()
        try lock.withLock {
            calls.append("boot \(storage[udid]?.name ?? udid)")
            if failBoot { throw SimctlHouseError.simctlFailed(command: "bootstatus", status: 1, stderr: "boom") }
            storage[udid]?.state = "Booted"
        }
    }

    func shutdown(udid: String) throws {
        lock.withLock {
            calls.append("shutdown \(storage[udid]?.name ?? udid)")
            storage[udid]?.state = "Shutdown"
        }
    }

    func erase(udid: String) throws {
        onErase?()
        try lock.withLock {
            calls.append("erase \(storage[udid]?.name ?? udid)")
            if failErase { throw SimctlHouseError.simctlFailed(command: "erase", status: 1, stderr: "boom") }
        }
    }

    func existsOnDisk(udid: String) -> Bool { lock.withLock { storage[udid] != nil } }

    func delete(udid: String) throws {
        try lock.withLock {
            calls.append("delete \(storage[udid]?.name ?? udid)")
            if let name = storage[udid]?.name, failDelete.contains(name) {
                throw SimctlHouseError.simctlFailed(command: "delete", status: 1, stderr: "boom")
            }
            storage[udid] = nil
        }
    }

    // Test helpers

    func device(_ udid: String?) -> Device? { lock.withLock { udid.flatMap { storage[$0] } } }

    func addForeignDevice(name: String, booted: Bool) -> String {
        lock.withLock {
            let udid = UUID().uuidString
            storage[udid] = Device(
                udid: udid, name: name, state: booted ? "Booted" : "Shutdown", deviceType: "type.iPhone-18-Pro", runtime: "rt.iOS-27-0")
            return udid
        }
    }

    func removeBehindOurBack(_ udid: String) { _ = lock.withLock { storage.removeValue(forKey: udid) } }

    /// Leaves the device out of `devices()` while it stays on disk, as CoreSimulator can while it restarts.
    func setListed(_ udid: String, _ listed: Bool) {
        lock.withLock {
            if listed { unlisted.remove(udid) } else { unlisted.insert(udid) }
        }
    }

    func setState(_ udid: String, _ state: String) { lock.withLock { storage[udid]?.state = state } }

    func callCount(prefix: String) -> Int { lock.withLock { calls.filter { $0.hasPrefix(prefix) }.count } }
}

final class FakeScanner: ProcessScanner, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var exited: Set<Int32> = []

    func set(_ lines: [String]) { lock.withLock { self.lines = lines } }
    func commandLines() throws -> [String] { lock.withLock { lines } }

    /// Every process is running, since one fixed moment, until `exit` ends it.
    func startTime(of pid: Int32) -> Date? { lock.withLock { exited.contains(pid) ? nil : Date(timeIntervalSince1970: 1_700_000_000) } }
    func exit(_ pid: Int32) { _ = lock.withLock { exited.insert(pid) } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(minutes: Double) { lock.withLock { current = current.addingTimeInterval(minutes * 60) } }
}

/// A pool home in a temp directory, removed when the test that made it is done.
final class Harness: Sendable {
    let backend = FakeBackend()
    let scanner = FakeScanner()
    let clock = TestClock()
    let root = FileManager.default.temporaryDirectory.appending(path: "simctlhouse-tests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    var pool: Pool { pool() }

    /// `processID` stands in for another simctlhouse process, which `scanner.exit` can make crash.
    func pool(config: PoolConfig = PoolConfig(), processID: Int32 = getpid()) -> Pool {
        let clock = clock
        return Pool(paths: HousePaths(root: root), backend: backend, scanner: scanner, config: config, processID: processID, now: { clock.now })
    }

    func state() throws -> PoolState { try StateStore(paths: HousePaths(root: root)).snapshot() }
}

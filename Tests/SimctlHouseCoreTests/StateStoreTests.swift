import Foundation
import Testing
@testable import SimctlHouseCore

@Suite final class StateStoreTests: Sendable {
    let paths = HousePaths(root: FileManager.default.temporaryDirectory.appending(path: "simctlhouse-tests-\(UUID().uuidString)"))
    var store: StateStore { StateStore(paths: paths) }

    deinit { try? FileManager.default.removeItem(at: paths.root) }

    @Test func missingStateIsAnEmptyPool() throws {
        #expect(try store.snapshot() == PoolState())
    }

    @Test func savesByRenamingATempFileIntoPlace() throws {
        try addDevice()
        #expect(try store.snapshot().devices.map(\.name) == ["brave-otter"])
        #expect(!FileManager.default.fileExists(atPath: paths.stateTemp.path))
    }

    @Test func unreadableStateIsAnErrorRatherThanAnEmptyPool() throws {
        try addDevice()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: paths.stateFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.stateFile.path) }
        let error = try #require(throws: SimctlHouseError.self) { try store.transaction { $0.devices.removeAll() } }
        #expect(error.exitCode == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.stateFile.path)
        #expect(try store.snapshot().devices.count == 1)
    }

    @Test(arguments: ["", "{\"version\": 1, \"devices\": [", "not json"])
    func corruptStateIsMovedAsideAndReset(contents: String) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: paths.stateFile)
        let logged = Messages()
        let store = StateStore(paths: paths) { logged.append($0) }
        #expect(try store.snapshot() == PoolState())
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.root.path).filter { $0.hasPrefix("state.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try String(contentsOf: paths.root.appending(path: backups[0]), encoding: .utf8) == contents)
        #expect(logged.all.count == 1)
        #expect(logged.all.first?.contains(backups[0]) == true)
        // Reset once: later reads find no state file, so an empty pool without another warning.
        #expect(try store.snapshot() == PoolState())
        #expect(logged.all.count == 1)
    }

    @Test func resetsNeverOverwriteAnEarlierBackup() throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        for contents in ["first", "second"] {
            try Data(contents.utf8).write(to: paths.stateFile)
            #expect(try store.snapshot() == PoolState())
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.root.path).filter { $0.hasPrefix("state.json.corrupt-") }
        #expect(Set(try backups.map { try String(contentsOf: paths.root.appending(path: $0), encoding: .utf8) }) == ["first", "second"])
    }

    @Test func stateOfAnotherVersionIsNeverReset() throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(#"{"version": 2, "devices": [], "somethingNew": true}"#.utf8).write(to: paths.stateFile)
        let error = try #require(throws: SimctlHouseError.self) { try store.snapshot() }
        #expect(error == .corruptState("unsupported version 2 in \(paths.stateFile.path)"))
        #expect(FileManager.default.fileExists(atPath: paths.stateFile.path))
    }

    private func addDevice() throws {
        try store.transaction { state in
            state.devices.append(
                PoolDevice(
                    name: "brave-otter", udid: nil, deviceTypeIdentifier: "type.iPhone-18-Pro", runtimeIdentifier: "rt.iOS-27-0", status: .available,
                    now: Date()))
        }
    }
}

final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    var all: [String] { lock.withLock { messages } }
    func append(_ message: String) { lock.withLock { messages.append(message) } }
}

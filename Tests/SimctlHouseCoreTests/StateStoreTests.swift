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

    @Test func emptyStateFileIsCorrupt() throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data().write(to: paths.stateFile)
        let error = try #require(throws: SimctlHouseError.self) { try store.snapshot() }
        guard case .corruptState = error else {
            Issue.record("expected corruptState, got \(error)")
            return
        }
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

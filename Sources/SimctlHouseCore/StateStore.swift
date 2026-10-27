import Foundation

/// File layout under the simctlhouse home (default `~/.simctlhouse`, override with `SIMCTLHOUSE_HOME`).
public struct HousePaths: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> HousePaths {
        if let custom = environment["SIMCTLHOUSE_HOME"], !custom.isEmpty {
            return HousePaths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        return HousePaths(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".simctlhouse", directoryHint: .isDirectory))
    }

    public var stateFile: URL { root.appending(path: "state.json") }
    public var stateLock: URL { root.appending(path: "state.lock") }
}

/// An exclusive `flock(2)` on a file. The kernel drops it if the process dies, so a crash never leaves the pool locked.
final class FileLock {
    private let descriptor: Int32

    init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw SimctlHouseError.io("Cannot open lock file \(path.path): \(String(cString: strerror(errno)))") }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                throw SimctlHouseError.io("Cannot lock \(path.path): \(String(cString: strerror(errno)))")
            }
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func withLock<T>(at path: URL, _ body: () throws -> T) throws -> T {
        let lock = try FileLock(path: path)
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }
}

/// Reads and writes `state.json`. Every mutation goes through `transaction`, which holds the global lock
/// only for the read-modify-write. Slow simulator work (create, boot, shutdown) happens outside of it.
public struct StateStore: Sendable {
    public let paths: HousePaths

    public init(paths: HousePaths) {
        self.paths = paths
    }

    public func transaction<T>(_ body: (inout PoolState) throws -> T) throws -> T {
        try FileLock.withLock(at: paths.stateLock) {
            var state = try load()
            let original = state
            let result = try body(&state)
            if state != original { try save(state) }
            return result
        }
    }

    /// Unlocked snapshot. Fine for display; never use it to make a decision that mutates state.
    public func snapshot() throws -> PoolState {
        try FileLock.withLock(at: paths.stateLock) { try load() }
    }

    private func load() throws -> PoolState {
        guard let data = try? Data(contentsOf: paths.stateFile), !data.isEmpty else { return PoolState() }
        do {
            let state = try Self.decoder.decode(PoolState.self, from: data)
            guard state.version == PoolState.currentVersion else {
                throw SimctlHouseError.corruptState("unsupported version \(state.version) in \(paths.stateFile.path)")
            }
            return state
        } catch let error as SimctlHouseError {
            throw error
        } catch {
            throw SimctlHouseError.corruptState("\(paths.stateFile.path): \(error)")
        }
    }

    private func save(_ state: PoolState) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        // Write to a temp file and rename over the original so readers never observe a half-written file.
        try Self.encoder.encode(state).write(to: paths.stateFile, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

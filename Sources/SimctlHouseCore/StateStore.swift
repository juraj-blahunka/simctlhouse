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
    /// Where `state.json` is written before it is renamed into place. Only the lock holder writes it, so one name suffices.
    var stateTemp: URL { root.appending(path: "state.json.tmp") }
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

    /// Read-only copy for display. Never use it to make a decision that mutates state: by the time the caller acts,
    /// another process may have changed it. Decide inside `transaction` instead.
    public func snapshot() throws -> PoolState {
        try FileLock.withLock(at: paths.stateLock) { try load() }
    }

    private func load() throws -> PoolState {
        let data: Data
        do {
            data = try Data(contentsOf: paths.stateFile)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return PoolState()
        } catch {
            // Reading anything else as an empty pool would overwrite the registry on the next save and orphan every device.
            throw SimctlHouseError.io("Cannot read \(paths.stateFile.path): \(error.localizedDescription)")
        }
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

    /// Writes a temp file, flushes it to the drive, and renames it over the original, so neither a reader, a crash
    /// nor a power loss ever sees a half-written or empty `state.json`.
    private func save(_ state: PoolState) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Self.writeDurably(try Self.encoder.encode(state), to: paths.stateTemp)
        guard rename(paths.stateTemp.path, paths.stateFile.path) == 0 else { throw Self.posixError("Cannot replace \(paths.stateFile.path)") }
        // Persists the rename itself. Losing it would only bring back the previous, consistent state, so this is best effort.
        let directory = open(paths.root.path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posixError("Cannot create \(url.path)") }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written >= 0 else { throw posixError("Cannot write \(url.path)") }
                offset += written
            }
        }
        // On macOS, fsync only hands the data to the drive's cache; F_FULLFSYNC makes the drive persist it.
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else { throw posixError("Cannot flush \(url.path)") }
    }

    private static func posixError(_ message: String) -> SimctlHouseError {
        .io("\(message): \(String(cString: strerror(errno)))")
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

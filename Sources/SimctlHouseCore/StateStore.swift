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
    let log: @Sendable (String) -> Void

    public init(paths: HousePaths, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.log = log
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
        // Another version's state is not corrupt: resetting it would wipe the pool of a newer simctlhouse.
        if let version = (try? Self.decoder.decode(Header.self, from: data))?.version, version != PoolState.currentVersion {
            throw SimctlHouseError.corruptState("unsupported version \(version) in \(paths.stateFile.path)")
        }
        do {
            return try Self.decoder.decode(PoolState.self, from: data)
        } catch {
            return try reset(corrupt: data, error: error)
        }
    }

    private struct Header: Decodable {
        var version: Int?
    }

    /// Moves a corrupt `state.json` aside and starts with an empty pool, so one bad write cannot wedge every command.
    /// Simulators the corrupt file listed are no longer managed; the moved file keeps their UDIDs for deleting by hand.
    private func reset(corrupt data: Data, error: Error) throws -> PoolState {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "state.json.corrupt-\(formatter.string(from: Date()))"
        // Never overwrite an earlier backup, even from a reset in the same second.
        let backup = (0...).lazy.map { paths.root.appending(path: $0 == 0 ? stem : "\(stem)-\($0)") }
            .first { !FileManager.default.fileExists(atPath: $0.path) }!
        guard rename(paths.stateFile.path, backup.path) == 0 else { throw Self.posixError("Cannot move corrupt \(paths.stateFile.path) aside") }
        log(
            "warning: \(paths.stateFile.path) was corrupt (\(Self.reason(error))); moved it to \(backup.lastPathComponent) and started an empty pool. "
                + "The simulators it listed are no longer managed; their UDIDs are in that file, for `xcrun simctl delete <udid>`.")
        return PoolState()
    }

    /// One line on why decoding failed, instead of the nested `DecodingError` dump.
    private static func reason(_ error: Error) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty: return "not valid JSON"
        case DecodingError.dataCorrupted(let context): return "invalid value at \(path(context.codingPath))"
        case DecodingError.keyNotFound(let key, let context): return "missing \(path(context.codingPath + [key]))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "unexpected value at \(path(context.codingPath))"
        default: return error.localizedDescription
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

import Foundation

/// Links the agent skill that ships next to the binary into each coding agent's skills directory.
///
/// A release installs the skill under `<prefix>/share/simctlhouse/skills/simctlhouse`.
/// The links point at that prefix path rather than a versioned one, so a package manager that swaps the prefix
/// on upgrade (Homebrew re-points `/opt/homebrew/share/simctlhouse`) updates the skill without a new install.
public struct SkillInstaller: Sendable {
    public static let skillName = "simctlhouse"

    public var home: URL
    public var environment: [String: String]

    public init(home: URL, environment: [String: String]) {
        self.home = home
        self.environment = environment
    }

    /// Honours `$HOME` like `install.sh` does; `homeDirectoryForCurrentUser` reads the user database and ignores it.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SkillInstaller {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return SkillInstaller(home: home ?? FileManager.default.homeDirectoryForCurrentUser, environment: environment)
    }

    /// Whether `source` sits in a Homebrew keg, whose versioned path disappears on the next upgrade and cleanup.
    public static func isVersioned(_ source: URL) -> Bool {
        source.pathComponents.contains("Cellar")
    }

    /// Skills directories of the agents set up on this machine, the same ones `install.sh` detects.
    public func detectedSkillsDirectories() -> [URL] {
        let piHome = environment["PI_CODING_AGENT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let agentHomes = [home.appending(path: ".claude"), home.appending(path: ".codex"), piHome ?? home.appending(path: ".pi/agent")]
        return agentHomes.filter { isDirectory($0) }.map { $0.appending(path: "skills", directoryHint: .isDirectory) }
    }

    /// The skill shipped with the binary at `executable`, looked up as `<dir>/../share/simctlhouse/skills/simctlhouse`.
    ///
    /// Follows the executable's symlinks one hop at a time and takes the first hit, so `/opt/homebrew/bin/simctlhouse`
    /// yields the stable `/opt/homebrew/share/...` path before the versioned Cellar one it eventually points to.
    public static func shippedSkill(executable: URL) -> URL? {
        var current = lexical(executable.path, relativeTo: "/")
        for _ in 0..<32 {
            let directory = current.deletingLastPathComponent().path
            let candidate = lexical("../share/simctlhouse/skills/\(skillName)", relativeTo: directory)
            if isSkill(candidate) { return candidate }
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { return nil }
            current = lexical(destination, relativeTo: directory)
        }
        return nil
    }

    /// A skill directory given explicitly, such as a checkout's `skills/simctlhouse` that `install.sh` links so edits take effect immediately.
    public static func skill(at path: String, relativeTo directory: String = FileManager.default.currentDirectoryPath) throws -> URL {
        let source = lexical(path, relativeTo: directory)
        guard source.lastPathComponent == skillName, isSkill(source) else { throw SimctlHouseError.notASkill(source.path) }
        return source
    }

    /// The path this process was started from, without resolving symlinks (unlike `Bundle.main.executableURL`).
    public static func currentExecutable() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return URL(fileURLWithPath: CommandLine.arguments[0]) }
        return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    public func status(in directories: [URL]) -> [SkillLink] {
        directories.map(link(in:))
    }

    /// Links `source` into every directory. Checks all of them first and changes nothing if any holds something that is not ours.
    public func install(_ source: URL, into directories: [URL]) throws -> [SkillLink] {
        let conflicts = status(in: directories).filter { $0.status == .foreign }
        if !conflicts.isEmpty { throw SimctlHouseError.skillConflict(paths: conflicts.map(\.path)) }
        for directory in directories {
            try replaceLink(at: directory.appending(path: Self.skillName), with: source.path)
        }
        return status(in: directories)
    }

    /// Removes our links, including broken ones left behind by an uninstalled package. Leaves anything else alone.
    public func uninstall(from directories: [URL]) throws -> [SkillLink] {
        try status(in: directories).map { link in
            guard link.status == .linked || link.status == .broken else { return link }
            do {
                try FileManager.default.removeItem(atPath: link.path)
            } catch {
                throw SimctlHouseError.io("Cannot remove \(link.path): \(error.localizedDescription)")
            }
            return SkillLink(path: link.path, target: link.target, status: .missing)
        }
    }

    private func link(in directory: URL) -> SkillLink {
        let path = directory.appending(path: Self.skillName).path
        guard (try? FileManager.default.attributesOfItem(atPath: path)) != nil else { return SkillLink(path: path, target: nil, status: .missing) }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return SkillLink(path: path, target: nil, status: .foreign)
        }
        let resolved = Self.lexical(target, relativeTo: directory.path)
        // Agent Skills require the directory to be named after the skill, so every simctlhouse skill lives in a `simctlhouse` directory.
        guard resolved.lastPathComponent == Self.skillName else { return SkillLink(path: path, target: target, status: .foreign) }
        if Self.isSkill(resolved) { return SkillLink(path: path, target: target, status: .linked) }
        // A dangling link to a `simctlhouse` directory is what an uninstalled package or a moved checkout leaves behind.
        return SkillLink(path: path, target: target, status: FileManager.default.fileExists(atPath: resolved.path) ? .foreign : .broken)
    }

    /// Swaps the link in with rename(2), which replaces the old link itself and never follows it, so readers never see it missing.
    private func replaceLink(at link: URL, with target: String) throws {
        let temporary = link.deletingLastPathComponent().appending(path: ".\(Self.skillName).\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
        } catch {
            throw SimctlHouseError.io("Cannot link the skill into \(link.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        guard rename(temporary.path, link.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw SimctlHouseError.io("Cannot link the skill at \(link.path): \(reason)")
        }
    }

    /// `path` made absolute with `.` and `..` removed textually.
    /// `standardizedFileURL` would also resolve symlinks, and the symlinked prefix path is the one we want to keep.
    static func lexical(_ path: String, relativeTo directory: String) -> URL {
        var components: [String] = []
        for component in ((path.hasPrefix("/") ? "" : directory + "/") + path).split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(String(component))
            }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }

    /// A directory whose SKILL.md declares `name: simctlhouse` in its frontmatter.
    static func isSkill(_ directory: URL) -> Bool {
        guard let text = try? String(contentsOf: directory.appending(path: "SKILL.md"), encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return false }
        return lines[1..<end].contains("name: \(skillName)")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// The skill entry in one agent's skills directory.
public struct SkillLink: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// A link to an installed simctlhouse skill.
        case linked
        /// Nothing there.
        case missing
        /// Our link, but its target is gone, e.g. after the package was uninstalled.
        case broken
        /// A real directory or someone else's link. Never touched.
        case foreign
    }

    public var path: String
    public var target: String?
    public var status: Status
}

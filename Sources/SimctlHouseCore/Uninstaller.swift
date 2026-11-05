import Foundation

/// What `simctlhouse uninstall` would remove, shown before it asks.
public struct UninstallPlan: Sendable {
    public struct Device: Sendable, Equatable {
        public var name: String
        /// Set while an agent holds it.
        public var holder: String?
        public var isLeased: Bool
        public var bytes: Int64?
    }

    public var devices: [Device]
    /// Links that point at a simctlhouse skill, working or broken; foreign entries are never touched.
    public var links: [SkillLink]
    public var daemonRunning: Bool
    public var home: URL
    public var homeExists: Bool

    public var totalBytes: Int64 { devices.compactMap(\.bytes).reduce(0, +) }
}

/// Removes everything simctlhouse put on this Mac besides its own binary: the pool's simulators, the daemon,
/// the skill links and the state directory (D35). Your own simulators are never touched (D3).
public struct Uninstaller: Sendable {
    let pool: Pool
    let launcher: DaemonLauncher
    let skills: SkillInstaller
    let skillsDirectories: [URL]

    public init(pool: Pool, launcher: DaemonLauncher, skills: SkillInstaller, skillsDirectories: [URL]) {
        self.pool = pool
        self.launcher = launcher
        self.skills = skills
        self.skillsDirectories = skillsDirectories
    }

    public func plan() throws -> UninstallPlan {
        let devices = try pool.list().map { device in
            UninstallPlan.Device(
                name: device.name, holder: device.holder, isLeased: device.status == .leased, bytes: device.udid.flatMap(pool.backend.diskUsage))
        }
        let home = pool.store.paths.root
        return UninstallPlan(
            devices: devices,
            links: skills.status(in: skillsDirectories).filter { $0.status == .linked || $0.status == .broken },
            daemonRunning: try launcher.status().running,
            home: home,
            homeExists: FileManager.default.fileExists(atPath: home.path)
        )
    }

    /// Stops the daemon first, so it cannot act on devices being deleted, and keeps the state and the skill links
    /// if any device could not be deleted, so that running it again finishes the job.
    public func run(log: (String) -> Void) throws {
        try stopDaemon(log: log)
        // Logs each device it deletes.
        _ = try pool.deleteAll(force: true)
        let links = skills.status(in: skillsDirectories).filter { $0.status == .linked || $0.status == .broken }
        _ = try skills.uninstall(from: skillsDirectories)
        for link in links { log("Removed the skill link \(link.path).") }
        // A command run meanwhile, such as an agent's acquire, may have started it again.
        try stopDaemon(log: { _ in })
        try removeHome(log: log)
    }

    /// How often devices that agents add while uninstalling are deleted before giving up.
    static let deleteAttempts = 3

    /// Removes the state directory under the state lock, and only once it lists no device: removing it after an agent's
    /// acquire committed would leave that simulator with nothing tracking it (D3). Such a device is deleted first.
    private func removeHome(log: (String) -> Void) throws {
        let home = pool.store.paths.root
        for _ in 0..<Self.deleteAttempts {
            guard FileManager.default.fileExists(atPath: home.path) else { return }
            let removed = try pool.store.transaction { state -> Bool in
                guard state.devices.isEmpty else { return false }
                do {
                    try FileManager.default.removeItem(at: home)
                } catch {
                    throw SimctlHouseError.io("Cannot remove \(home.path): \(error.localizedDescription)")
                }
                return true
            }
            if removed {
                log("Removed \(home.path).")
                return
            }
            _ = try pool.deleteAll(force: true)
        }
        throw SimctlHouseError.io("Agents kept adding devices while uninstalling. Stop them, then run `simctlhouse uninstall` again.")
    }

    private func stopDaemon(log: (String) -> Void) throws {
        guard try launcher.status().running else { return }
        guard try launcher.stop() else { throw SimctlHouseError.io("The daemon did not stop. See `simctlhouse daemon status`, then try again.") }
        log("Stopped the daemon.")
    }
}

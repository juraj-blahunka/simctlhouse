import Foundation
import Testing
@testable import SimctlHouseCore

@Suite final class UninstallerTests {
    let h = Harness()
    let skillsRoot = FileManager.default.temporaryDirectory.appending(path: "UninstallerTests-\(UUID().uuidString)").resolvingSymlinksInPath()
    var skillsDirectory: URL { skillsRoot.appending(path: "skills") }

    deinit { try? FileManager.default.removeItem(at: skillsRoot) }

    /// No daemon runs in these tests, so nothing is ever spawned or signalled.
    var uninstaller: Uninstaller {
        let launcher = DaemonLauncher(
            paths: HousePaths(root: h.root), build: DaemonBuild(executable: "/test", inode: 1, modifiedAt: 1), scanner: h.scanner,
            spawn: { _ in 0 }, signal: { _ in })
        return Uninstaller(
            pool: h.pool, launcher: launcher, skills: SkillInstaller(home: skillsRoot, environment: [:]), skillsDirectories: [skillsDirectory])
    }

    func linkSkill() throws {
        let source = skillsRoot.appending(path: "share/simctlhouse")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: simctlhouse\ndescription: test\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try SkillInstaller(home: skillsRoot, environment: [:]).install(source, into: [skillsDirectory])
    }

    @Test func thePlanListsEverythingItRemoves() throws {
        let leased = try h.pool.acquire(AcquireRequest(holder: "fix login"))
        let free = try h.pool.acquire(AcquireRequest())
        try h.pool.release(free.name)
        let foreign = h.backend.addForeignDevice(name: "My iPhone", booted: false)
        try linkSkill()
        let plan = try uninstaller.plan()
        #expect(Set(plan.devices.map(\.name)) == [leased.name, free.name])
        #expect(plan.devices.first { $0.isLeased }?.holder == "fix login")
        #expect(plan.totalBytes == 2 * 2_400_000_000)
        #expect(plan.links.map(\.status) == [.linked])
        #expect(plan.homeExists)
        #expect(!plan.daemonRunning)
        // Planning touches nothing.
        #expect(h.backend.existsOnDisk(udid: leased.udid!))
        #expect(h.backend.existsOnDisk(udid: foreign))
    }

    @Test func runRemovesThePoolTheLinksAndTheStateButNotYourSimulators() throws {
        let leased = try h.pool.acquire(AcquireRequest(holder: "fix login"))
        let foreign = h.backend.addForeignDevice(name: "My iPhone", booted: true)
        try linkSkill()
        try uninstaller.run(log: { _ in })
        #expect(!h.backend.existsOnDisk(udid: leased.udid!))
        #expect(h.backend.device(foreign)?.state == "Booted")
        #expect(SkillInstaller(home: skillsRoot, environment: [:]).status(in: [skillsDirectory]).map(\.status) == [.missing])
        #expect(!FileManager.default.fileExists(atPath: h.root.path))
    }

    @Test func aFailedDeleteKeepsTheStateAndTheLinksForAnotherTry() throws {
        let device = try h.pool.acquire(AcquireRequest())
        try linkSkill()
        h.backend.failDelete = [device.name]
        #expect(throws: (any Error).self) { try uninstaller.run(log: { _ in }) }
        #expect(FileManager.default.fileExists(atPath: h.root.path))
        #expect(try h.state().devices.map(\.name) == [device.name])
        #expect(SkillInstaller(home: skillsRoot, environment: [:]).status(in: [skillsDirectory]).map(\.status) == [.linked])
        h.backend.failDelete = []
        try uninstaller.run(log: { _ in })
        #expect(!FileManager.default.fileExists(atPath: h.root.path))
    }

    @Test func anEmptyMachineHasNothingToRemove() throws {
        let plan = try uninstaller.plan()
        #expect(plan.devices.isEmpty && plan.links.isEmpty && !plan.daemonRunning)
        try uninstaller.run(log: { _ in })
    }
}

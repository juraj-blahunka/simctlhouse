import Foundation
import Testing
@testable import SimctlHouseCore

/// Runs against a throwaway directory laid out like a Homebrew prefix plus a home with agent directories.
@Suite final class SkillInstallerTests {
    let root: URL
    let installer: SkillInstaller
    let claudeSkills: URL
    let codexSkills: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "SkillInstallerTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let home = root.appending(path: "home")
        installer = SkillInstaller(home: home, environment: [:])
        claudeSkills = home.appending(path: ".claude/skills")
        codexSkills = home.appending(path: ".codex/skills")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// `<prefix>/Cellar/simctlhouse/<version>` with the binary and skill, linked into `<prefix>/bin` and `<prefix>/share` like `brew link`.
    @discardableResult
    func brewInstall(_ version: String) throws -> URL {
        let prefix = root.appending(path: "brew")
        let keg = prefix.appending(path: "Cellar/simctlhouse/\(version)")
        try writeSkill(at: keg.appending(path: "share/simctlhouse/skills/simctlhouse"), name: "simctlhouse", body: version)
        try FileManager.default.createDirectory(at: keg.appending(path: "bin"), withIntermediateDirectories: true)
        try Data().write(to: keg.appending(path: "bin/simctlhouse"))
        try relink(prefix.appending(path: "bin/simctlhouse"), to: "../Cellar/simctlhouse/\(version)/bin/simctlhouse")
        try relink(prefix.appending(path: "share/simctlhouse"), to: "../Cellar/simctlhouse/\(version)/share/simctlhouse")
        return prefix
    }

    func relink(_ link: URL, to destination: String) throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }

    func writeSkill(at directory: URL, name: String, body: String = "") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: test\n---\n\n\(body)\n".write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }

    func skillBody(in skills: URL) throws -> String {
        try String(contentsOf: skills.appending(path: "simctlhouse/SKILL.md"), encoding: .utf8)
    }

    @Test func detectsInstalledAgentsOnly() {
        #expect(installer.detectedSkillsDirectories().map(\.path) == [claudeSkills.path, codexSkills.path])
    }

    @Test func piHonoursItsAgentDirVariable() throws {
        let pi = root.appending(path: "pi-agent")
        try FileManager.default.createDirectory(at: pi, withIntermediateDirectories: true)
        let installer = SkillInstaller(home: root.appending(path: "home"), environment: ["PI_CODING_AGENT_DIR": pi.path])
        #expect(installer.detectedSkillsDirectories().last?.path == pi.appending(path: "skills").path)
    }

    @Test func findsTheStablePrefixPathBeforeTheVersionedKeg() throws {
        let prefix = try brewInstall("1.0.0")
        let source = try #require(SkillInstaller.shippedSkill(executable: prefix.appending(path: "bin/simctlhouse")))
        #expect(source.path == prefix.appending(path: "share/simctlhouse/skills/simctlhouse").path)
        #expect(!SkillInstaller.isVersioned(source))
    }

    @Test func followsSymlinksWhenThePrefixHasNoShareDirectory() throws {
        let prefix = try brewInstall("1.0.0")
        try FileManager.default.removeItem(at: prefix.appending(path: "share/simctlhouse"))
        let source = try #require(SkillInstaller.shippedSkill(executable: prefix.appending(path: "bin/simctlhouse")))
        #expect(source.path.hasSuffix("Cellar/simctlhouse/1.0.0/share/simctlhouse/skills/simctlhouse"))
        #expect(SkillInstaller.isVersioned(source))
    }

    @Test func noSkillNextToABareBinary() throws {
        let binary = root.appending(path: "bin/simctlhouse")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        #expect(SkillInstaller.shippedSkill(executable: binary) == nil)
    }

    @Test func upgradeUpdatesTheLinkedSkill() throws {
        let prefix = try brewInstall("1.0.0")
        let source = try #require(SkillInstaller.shippedSkill(executable: prefix.appending(path: "bin/simctlhouse")))
        let links = try installer.install(source, into: [claudeSkills, codexSkills])
        #expect(links.map(\.status) == [.linked, .linked])
        #expect(try skillBody(in: claudeSkills).contains("1.0.0"))

        try brewInstall("1.1.0")
        try FileManager.default.removeItem(at: prefix.appending(path: "Cellar/simctlhouse/1.0.0"))
        #expect(try skillBody(in: claudeSkills).contains("1.1.0"))
        #expect(installer.status(in: [claudeSkills]).map(\.status) == [.linked])
    }

    @Test func reinstallReplacesOurLinksIncludingACheckoutOne() throws {
        let checkout = root.appending(path: "checkout/skills/simctlhouse")
        try writeSkill(at: checkout, name: "simctlhouse", body: "checkout")
        _ = try installer.install(checkout, into: [claudeSkills])

        let prefix = try brewInstall("1.0.0")
        let source = try #require(SkillInstaller.shippedSkill(executable: prefix.appending(path: "bin/simctlhouse")))
        _ = try installer.install(source, into: [claudeSkills])
        _ = try installer.install(source, into: [claudeSkills])
        #expect(try skillBody(in: claudeSkills).contains("1.0.0"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: claudeSkills.path) == ["simctlhouse"])
    }

    @Test func explicitSourceMustBeTheSimctlhouseSkill() throws {
        let checkout = root.appending(path: "checkout")
        try writeSkill(at: checkout.appending(path: "skills/simctlhouse"), name: "simctlhouse")
        try writeSkill(at: checkout.appending(path: "skills/other"), name: "simctlhouse")
        try writeSkill(at: checkout.appending(path: "other/simctlhouse"), name: "other")

        #expect(try SkillInstaller.skill(at: "./skills/../skills/simctlhouse", relativeTo: checkout.path).path == checkout.path + "/skills/simctlhouse")
        for path in ["skills/other", "other/simctlhouse", "missing/simctlhouse"] {
            #expect(throws: SimctlHouseError.notASkill(checkout.path + "/" + path)) { try SkillInstaller.skill(at: path, relativeTo: checkout.path) }
        }
    }

    @Test(arguments: ["directory", "other skill", "other link"])
    func refusesToTouchAnythingThatIsNotOurs(kind: String) throws {
        let prefix = try brewInstall("1.0.0")
        let source = try #require(SkillInstaller.shippedSkill(executable: prefix.appending(path: "bin/simctlhouse")))
        let existing = codexSkills.appending(path: "simctlhouse")
        switch kind {
        case "directory": try writeSkill(at: existing, name: "simctlhouse")
        case "other skill":
            try writeSkill(at: root.appending(path: "elsewhere/skills/simctlhouse"), name: "something-else")
            try relink(existing, to: root.appending(path: "elsewhere/skills/simctlhouse").path)
        default: try relink(existing, to: "/nonexistent/simctlhouse-fork")
        }
        let before = try? FileManager.default.destinationOfSymbolicLink(atPath: existing.path)

        #expect(throws: SimctlHouseError.skillConflict(paths: [existing.path])) {
            try installer.install(source, into: [claudeSkills, codexSkills])
        }
        #expect(installer.status(in: [claudeSkills, codexSkills]).map(\.status) == [.missing, .foreign])

        #expect(try installer.uninstall(from: [codexSkills]).map(\.status) == [.foreign])
        #expect((try? FileManager.default.attributesOfItem(atPath: existing.path)) != nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: existing.path)) == before)
    }

    @Test func uninstallRemovesLinksLeftBrokenByAnUninstalledPackage() throws {
        let prefix = try brewInstall("1.0.0")
        let source = try #require(SkillInstaller.shippedSkill(executable: prefix.appending(path: "bin/simctlhouse")))
        _ = try installer.install(source, into: [claudeSkills, codexSkills])
        try FileManager.default.removeItem(at: prefix)
        #expect(installer.status(in: [claudeSkills, codexSkills]).map(\.status) == [.broken, .broken])

        #expect(try installer.uninstall(from: [claudeSkills, codexSkills]).map(\.status) == [.missing, .missing])
        #expect(try FileManager.default.contentsOfDirectory(atPath: claudeSkills.path).isEmpty)
    }
}

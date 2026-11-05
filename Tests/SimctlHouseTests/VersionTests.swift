import Testing
@testable import simctlhouse

@Suite struct VersionTests {
    @Test func theSubcommandMatchesTheFlag() throws {
        #expect(try SimctlHouse.parseAsRoot(["version"]) is Version)
        #expect(Runtime.version == SimctlHouse.configuration.version)
        #expect(!Runtime.version.isEmpty)
    }
}

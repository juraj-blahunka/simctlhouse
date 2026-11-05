import Testing
@testable import simctlhouse

/// `delete` takes exactly one way of choosing devices, and the `--unused` options only with `--unused`.
@Suite struct DeleteOptionsTests {
    @Test(arguments: [["--unused"], ["--unused", "--for", "2d", "--dry-run", "--json"], ["--all", "--force"], ["wild-dragon"]])
    func validCombinations(arguments: [String]) throws {
        _ = try Delete.parse(arguments)
    }

    @Test(arguments: [
        [], ["--all", "--unused"], ["wild-dragon", "--unused"], ["--for", "2d"], ["--all", "--dry-run"], ["--unused", "--force"], ["--unused", "--for", "2w"],
    ])
    func invalidCombinations(arguments: [String]) {
        #expect(throws: (any Error).self) { try Delete.parse(arguments) }
    }
}

import Foundation
import Testing
@testable import SimctlHouseCore

@Suite struct PoolConfigTests {
    @Test func defaultsWithoutVariables() throws {
        let config = try PoolConfig.fromEnvironment([:])
        #expect(config.leaseDuration == 30 * 60)
        #expect(config.idleShutdown == 15 * 60)
    }

    @Test func readsSeconds() throws {
        let config = try PoolConfig.fromEnvironment(["SIMCTLHOUSE_LEASE_SECONDS": "3600", "SIMCTLHOUSE_IDLE_SECONDS": " 0 "])
        #expect(config.leaseDuration == 3600)
        #expect(config.idleShutdown == 0)
    }

    @Test func emptyValueMeansDefault() throws {
        #expect(try PoolConfig.fromEnvironment(["SIMCTLHOUSE_LEASE_SECONDS": ""]).leaseDuration == 30 * 60)
    }

    @Test(arguments: [
        ("SIMCTLHOUSE_LEASE_SECONDS", "0", "seconds, more than 0"),
        ("SIMCTLHOUSE_LEASE_SECONDS", "30m", "seconds, more than 0"),
        ("SIMCTLHOUSE_IDLE_SECONDS", "-1", "seconds, 0 or more"),
        ("SIMCTLHOUSE_IDLE_SECONDS", "inf", "seconds, 0 or more"),
    ])
    func rejectsInvalidValues(variable: String, value: String, expected: String) {
        #expect(throws: SimctlHouseError.invalidEnvironment(variable: variable, value: value, expected: expected)) {
            try PoolConfig.fromEnvironment([variable: value])
        }
    }
}

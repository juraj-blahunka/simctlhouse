import Testing
@testable import SimctlHouseCore

@Suite struct ErrorTests {
    /// Exit codes are API (D22): agents branch on them, so a code never moves to another failure class.
    /// Every case is listed; a new case belongs here too.
    @Test(
        arguments: [
            (SimctlHouseError.simctlFailed(command: "simctl boot X", status: 149, stderr: ""), 1),
            (.corruptState("bad"), 1),
            (.io("disk full"), 1),
            (.unknownModel("iPhone 99"), 2),
            (.unsupportedModel("Apple Watch Series 11 (46mm)"), 2),
            (.noRuntime(model: "iPhone 18 Pro", os: "17"), 2),
            (.deviceNotFound("amber-falcon"), 3),
            (.leaseMismatch(device: "amber-falcon"), 4),
            (.notLeased(device: "amber-falcon"), 4),
            (.deviceLeased(device: "amber-falcon", holder: "agent-42"), 5),
            (.deviceBusy(device: "amber-falcon", status: .maintenance), 5),
            (.deviceInUse(device: "amber-falcon"), 5),
            (.takenOver(device: "amber-falcon"), 5),
            (.skillNotShipped(executable: "/usr/local/bin/simctlhouse"), 6),
            (.skillConflict(paths: ["~/.claude/skills/simctlhouse"]), 6),
            (.notASkill("/tmp/skill"), 6),
            (.invalidEnvironment(variable: "SIMCTLHOUSE_DAEMON", value: "yes", expected: "0 or 1"), 64),
        ] as [(SimctlHouseError, Int32)])
    func everyFailureClassKeepsItsExitCode(error: SimctlHouseError, code: Int32) {
        #expect(error.exitCode == code)
        listedAbove(error)
    }

    /// Stops compiling when a case is added, as a reminder to give it a row above.
    private func listedAbove(_ error: SimctlHouseError) {
        switch error {
        case .simctlFailed, .corruptState, .io, .unknownModel, .unsupportedModel, .noRuntime, .deviceNotFound, .leaseMismatch, .notLeased,
            .deviceLeased, .deviceBusy, .deviceInUse, .takenOver, .skillNotShipped, .skillConflict, .notASkill, .invalidEnvironment:
            break
        }
    }
}

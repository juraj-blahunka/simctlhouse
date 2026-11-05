import Foundation
import Testing
@testable import SimctlHouseCore

@Suite struct RunCommandTests {
    let one = [RunDevice(name: "amber-falcon", udid: "6F1C0000-0000-0000-0000-000000000001", leaseId: "l1")]
    let two = [
        RunDevice(name: "amber-falcon", udid: "6F1C0000-0000-0000-0000-000000000001", leaseId: "l1"),
        RunDevice(name: "wild-dragon", udid: "A93E0000-0000-0000-0000-000000000002", leaseId: "l2"),
    ]

    @Test func replacesPlaceholdersInsideArguments() throws {
        let command = try RunCommand(["xcrun", "simctl", "install", "{udid}", "App.app"], devices: one)
        #expect(command.arguments == ["xcrun", "simctl", "install", one[0].udid, "App.app"])
        let shell = try RunCommand(["sh", "-c", "echo {name} && xcrun simctl boot {udid}"], devices: one)
        #expect(shell.arguments == ["sh", "-c", "echo amber-falcon && xcrun simctl boot \(one[0].udid)"])
        #expect(shell.addedDestinations.isEmpty)
    }

    @Test func addsADestinationToXcodebuild() throws {
        let command = try RunCommand(["xcodebuild", "test", "-scheme", "App"], devices: one)
        #expect(command.arguments == ["xcodebuild", "test", "-scheme", "App", "-destination", "id=\(one[0].udid)"])
        #expect(command.addedDestinations == ["id=\(one[0].udid)"])
        let path = try RunCommand(["/usr/bin/xcodebuild", "clean", "test"], devices: one)
        #expect(path.arguments.suffix(2) == ["-destination", "id=\(one[0].udid)"])
    }

    @Test func addsADestinationToXcodebuildThroughXcrun() throws {
        let command = try RunCommand(["xcrun", "-sdk", "iphonesimulator", "xcodebuild", "build", "-scheme", "App"], devices: one)
        #expect(command.arguments.suffix(2) == ["-destination", "id=\(one[0].udid)"])
        #expect(try RunCommand(["xcrun", "simctl", "list"], devices: one).addedDestinations.isEmpty)
    }

    @Test func addsOneDestinationPerDevice() throws {
        let command = try RunCommand(["xcodebuild", "test", "-scheme", "App"], devices: two)
        #expect(command.addedDestinations == two.map { "id=\($0.udid)" })
        #expect(command.arguments.filter { $0 == "-destination" }.count == 2)
    }

    @Test func leavesXcodebuildAloneWhenItNeedsNoDestination() throws {
        for extra in [["-list"], ["-showBuildSettings"], ["archive", "-archivePath", "App.xcarchive"], ["-version"]] {
            let command = try RunCommand(["xcodebuild", "-scheme", "App"] + extra, devices: one)
            #expect(command.addedDestinations.isEmpty)
        }
    }

    @Test func acceptsADestinationThatNamesTheLeasedDevice() throws {
        let command = try RunCommand(["xcodebuild", "test", "-destination", "platform=iOS Simulator,id={udid}"], devices: one)
        #expect(command.arguments.last == "platform=iOS Simulator,id=\(one[0].udid)")
        #expect(command.addedDestinations.isEmpty)
        let lowercased = try RunCommand(["xcodebuild", "test", "-destination", "id=\(one[0].udid.lowercased())"], devices: one)
        #expect(lowercased.addedDestinations.isEmpty)
        let generic = try RunCommand(["xcodebuild", "build", "-destination", "generic/platform=iOS Simulator"], devices: one)
        #expect(generic.addedDestinations.isEmpty)
    }

    @Test func refusesADestinationNamingAnotherSimulator() {
        for destination in ["platform=iOS Simulator,name=iPhone 17 Pro", "id=booted", "id=00000000-0000-0000-0000-000000000000"] {
            #expect(throws: SimctlHouseError.self) { try RunCommand(["xcodebuild", "test", "-destination", destination], devices: one) }
        }
        // Not a destination option.
        #expect(throws: Never.self) { try RunCommand(["xcodebuild", "test", "-destination-timeout", "60"], devices: one) }
    }

    @Test func refusesWhatNoLeaseCouldFixBeforeLeasing() throws {
        #expect(throws: SimctlHouseError.self) { try RunCommand.check(["xcodebuild", "test", "-destination", "name=iPhone 17 Pro"], count: 1) }
        #expect(throws: SimctlHouseError.self) { try RunCommand.check(["xcodebuild", "test", "-destination", "id=booted"], count: 1) }
        #expect(throws: SimctlHouseError.self) { try RunCommand.check(["echo", "{udid}"], count: 2) }
        #expect(throws: SimctlHouseError.self) { try RunCommand.check([], count: 1) }
        // Decided once the device is known.
        try RunCommand.check(["xcodebuild", "test", "-destination", "id=6F1C0000-0000-0000-0000-000000000001"], count: 1)
        try RunCommand.check(["xcodebuild", "test", "-destination", "id={udid}"], count: 1)
        try RunCommand.check(["xcodebuild", "test", "-destination", "generic/platform=iOS Simulator"], count: 3)
        try RunCommand.check(["xcodebuild", "test", "-scheme", "App"], count: 3)
        try RunCommand.check(["echo", "{udid}"], count: 1)
    }

    @Test func placeholdersNeedASingleDevice() {
        #expect(throws: SimctlHouseError.self) { try RunCommand(["xcrun", "simctl", "boot", "{udid}"], devices: two) }
        #expect(throws: SimctlHouseError.self) { try RunCommand(["echo", "{name}"], devices: two) }
    }

    @Test func refusesAnEmptyCommand() {
        #expect(throws: SimctlHouseError.self) { try RunCommand([], devices: one) }
        #expect(throws: SimctlHouseError.self) { try RunCommand([""], devices: one) }
    }

    @Test func setsTheDeviceVariables() {
        let single = RunEnvironment.adding(one, to: ["PATH": "/usr/bin", "SIMCTLHOUSE_UDID": "stale"])
        #expect(single["PATH"] == "/usr/bin")
        #expect(single["SIMCTLHOUSE_UDID"] == one[0].udid)
        #expect(single["SIMCTLHOUSE_DEVICE"] == "amber-falcon")
        #expect(single["SIMCTLHOUSE_LEASE_ID"] == "l1")
        #expect(single["SIMCTLHOUSE_UDIDS"] == one[0].udid)

        // Several devices: only the lists, so a script written for one device fails instead of using the first.
        let several = RunEnvironment.adding(two, to: ["SIMCTLHOUSE_UDID": "stale"])
        #expect(several["SIMCTLHOUSE_UDID"] == nil)
        #expect(several["SIMCTLHOUSE_UDIDS"] == two.map(\.udid).joined(separator: " "))
        #expect(several["SIMCTLHOUSE_DEVICES"] == "amber-falcon wild-dragon")
    }

    @Test func exitCodesKeepClearOfTheCommandsOwnWhereTheyCan() {
        #expect(RunOutcome.exited(0).exitCode == 0)
        #expect(RunOutcome.exited(65).exitCode == 65)
        #expect(RunOutcome.signaled(SIGINT).exitCode == 130)
        #expect(RunOutcome.timedOut.exitCode == 124)
        #expect(RunOutcome.leaseLost.exitCode == 125)
        #expect(RunOutcome.notStarted(errno: EACCES).exitCode == 126)
        #expect(RunOutcome.notStarted(errno: ENOENT).exitCode == 127)
    }
}

@Suite struct DefaultHolderTests {
    @Test func namesTheFirstProcessAboveTheShells() {
        let table: [Int32: ProcessTable.Entry] = [
            100: .init(parent: 90, name: "zsh"),
            90: .init(parent: 80, name: "-bash"),
            80: .init(parent: 70, name: "claude"),
            70: .init(parent: 1, name: "herdr-core"),
        ]
        #expect(DefaultHolder.agentName(startingAt: 100, lookup: { table[$0] }) == "claude")
        #expect(DefaultHolder.agentName(startingAt: 90, lookup: { table[$0] }) == "claude")
    }

    @Test func givesUpAtLaunchdOrAnUnknownProcess() {
        let shells: [Int32: ProcessTable.Entry] = [100: .init(parent: 1, name: "zsh")]
        #expect(DefaultHolder.agentName(startingAt: 100, lookup: { shells[$0] }) == nil)
        #expect(DefaultHolder.agentName(startingAt: 100, lookup: { _ in nil }) == nil)
    }

    @Test func labelsTheAgentAndDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(DefaultHolder.label(agent: "codex", directory: home + "/src/app") == "codex in app")
        #expect(DefaultHolder.label(agent: "codex", directory: home) == "codex in ~")
        #expect(DefaultHolder.label(agent: nil, directory: "/tmp/work") == "work")
    }

    @Test func summarisesTheCommand() {
        #expect(DefaultHolder.summary(of: ["/usr/bin/xcodebuild", "test", "-scheme", "App"]) == "xcodebuild test -scheme App")
        let long = DefaultHolder.summary(of: ["xcodebuild"] + Array(repeating: "-only-testing:AppTests/LoginTests", count: 4))
        #expect(long.count == DefaultHolder.commandLength)
        #expect(long.hasSuffix("..."))
    }

    @Test func findsEveryProcessACommandStarted() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & sleep 30 & wait"]
        try process.run()
        defer { process.terminate() }
        var found: [Int32] = []
        for _ in 0..<50 where found.count < 2 {
            Thread.sleep(forTimeInterval: 0.05)
            found = ProcessTable.descendants(of: process.processIdentifier)
        }
        #expect(found.count == 2)
        #expect(ProcessTable.descendants(of: getpid()).contains(process.processIdentifier))
        for pid in found { kill(pid, SIGKILL) }
    }

    @Test func readsThisProcessesAncestry() {
        let entry = ProcessTable.entry(getpid())
        #expect(entry?.parent == getppid())
        #expect(entry?.name.isEmpty == false)
    }
}

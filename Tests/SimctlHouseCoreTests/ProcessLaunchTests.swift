import Foundation
import Testing
@testable import SimctlHouseCore

/// The real process plumbing behind `simctlhouse run` and the daemon, with small shell commands instead of xcodebuild.
@Suite final class ProcessLaunchTests {
    let launcher = PosixCommandLauncher()
    let scratch = FileManager.default.temporaryDirectory.appending(path: "ProcessLaunchTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: scratch) }

    // MARK: - run's command

    @Test func passesTheEnvironmentAndTheExitStatusThrough() throws {
        let events = RunEvents()
        _ = try launcher.start(["/bin/sh", "-c", #"test "$SIMCTLHOUSE_UDID" = ABC && exit 3"#], environment: ["SIMCTLHOUSE_UDID": "ABC"], events: events)
        #expect(try exitStatus(events) == 3 << 8)
    }

    @Test func reportsTheSignalThatEndedTheCommand() throws {
        let events = RunEvents()
        _ = try launcher.start(["/bin/sh", "-c", "kill -TERM $$"], environment: [:], events: events)
        #expect(try exitStatus(events) & 0x7f == SIGTERM)
    }

    @Test func findsTheCommandOnThePath() throws {
        let events = RunEvents()
        _ = try launcher.start(["true"], environment: ["PATH": "/usr/bin:/bin"], events: events)
        #expect(try exitStatus(events) == 0)
    }

    @Test func aCommandThatCannotStartSaysWhy() throws {
        let missing = scratch.appending(path: "missing")
        #expect(throws: CommandNotStarted(errno: ENOENT)) { try launcher.start([missing.path], environment: [:], events: RunEvents()) }
        let plain = scratch.appending(path: "not-executable")
        try "echo hi".write(to: plain, atomically: true, encoding: .utf8)
        #expect(throws: CommandNotStarted(errno: EACCES)) { try launcher.start([plain.path], environment: [:], events: RunEvents()) }
        #expect(RunOutcome.notStarted(errno: ENOENT).exitCode == 127)
        #expect(RunOutcome.notStarted(errno: EACCES).exitCode == 126)
    }

    /// `run` handles SIGHUP itself; a command that inherited an ignored one would outlive a closed terminal.
    @Test func theCommandGetsDefaultSignalHandlingBack() throws {
        var previous = sigaction()
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigaction(SIGHUP, &ignore, &previous)
        let events = RunEvents()
        let started = Result { try launcher.start(["/bin/sh", "-c", "kill -HUP $$; exit 0"], environment: [:], events: events) }
        sigaction(SIGHUP, &previous, nil)
        _ = try started.get()
        #expect(try exitStatus(events) & 0x7f == SIGHUP)
    }

    @Test func inheritsNoDescriptorButStdio() throws {
        let descriptor = open("/dev/null", O_RDONLY)
        defer { close(descriptor) }
        let events = RunEvents()
        _ = try launcher.start(["/bin/sh", "-c", "test -e /dev/fd/\(descriptor)"], environment: [:], events: events)
        #expect(try exitStatus(events) == 1 << 8)
    }

    @Test func aKillReachesEveryProcessTheCommandStarted() async throws {
        let events = RunEvents()
        let pid = try launcher.start(["/bin/sh", "-c", "sleep 30 & sleep 30 & wait"], environment: [:], events: events)
        var children: [Int32] = []
        #expect(
            try await eventually {
                children = ProcessTable.descendants(of: pid)
                return children.count == 2
            })
        launcher.signal(pid, SIGKILL)
        #expect(try exitStatus(events) & 0x7f == SIGKILL)
        // Re-parented to launchd once their shell died, they would otherwise sleep on.
        #expect(try await eventually { children.allSatisfy { kill($0, 0) != 0 } })
    }

    @Test func aStopSignalGoesToTheCommandAlone() async throws {
        let events = RunEvents()
        let marker = scratch.appending(path: "child-survived")
        // The child outlives a SIGTERM to its shell, so the command can wind its own processes down.
        let pid = try launcher.start(
            ["/bin/sh", "-c", "(trap '' TERM; sleep 0.5; touch '\(marker.path)') & trap 'exit 0' TERM; while :; do sleep 0.05; done"], environment: [:],
            events: events)
        #expect(try await eventually { ProcessTable.descendants(of: pid).count >= 1 })
        launcher.signal(pid, SIGTERM)
        #expect(try exitStatus(events) == 0)
        #expect(try await eventually { FileManager.default.fileExists(atPath: marker.path) })
    }

    // MARK: - the daemon

    @Test func theDaemonRunsDetachedWithNothingOfTheCaller() async throws {
        let descriptor = open("/dev/null", O_RDONLY)
        defer { close(descriptor) }
        let report = scratch.appending(path: "report")
        // The leak check runs before the redirected block: inside it, sh keeps its own stdout on fd 10,
        // which would look like a leak whenever the descriptor above happens to be 10.
        let script = """
            null=$(stat -f %Z /dev/null)
            leak=no-leak; test -e /dev/fd/\(descriptor) && leak=leak
            { test "$(stat -f %Z /dev/fd/0)" = "$null" && echo stdin-null
              test "$(stat -f %Z /dev/fd/2)" = "$null" && echo stderr-null
              echo "$leak"; } > '\(report.path).tmp'
            mv '\(report.path).tmp' '\(report.path)'
            sleep 30
            """
        let pid = try DaemonLauncher.spawnDetached("/bin/sh", ["-c", script])
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        // A session of its own, so closing the caller's terminal does not end it.
        #expect(getsid(pid) == pid)
        #expect(try await eventually { FileManager.default.fileExists(atPath: report.path) })
        #expect(try String(contentsOf: report, encoding: .utf8).split(separator: "\n") == ["stdin-null", "stderr-null", "no-leak"])
    }

    // MARK: - helpers

    private func exitStatus(_ events: RunEvents) throws -> Int32 {
        guard case .exited(let status) = try #require(events.next(until: Date().addingTimeInterval(10))) else {
            Issue.record("expected the command to exit")
            return -1
        }
        return status
    }
}

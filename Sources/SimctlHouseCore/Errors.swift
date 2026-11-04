import Foundation

public enum SimctlHouseError: Error, Equatable, CustomStringConvertible {
    case simctlFailed(command: String, status: Int32, stderr: String)
    /// `xcrun` itself failed before simctl ran: no Xcode selected, typically Command Line Tools only.
    case xcodeRequired(stderr: String)
    case unknownModel(String)
    case unsupportedModel(String)
    case noRuntime(model: String, os: String?)
    case deviceNotFound(String)
    case leaseMismatch(device: String)
    case notLeased(device: String)
    case deviceLeased(device: String, holder: String?)
    case deviceBusy(device: String, status: PoolDevice.Status)
    case deviceInUse(device: String)
    case takenOver(device: String)
    case invalidEnvironment(variable: String, value: String, expected: String)
    case skillNotShipped(executable: String)
    case skillConflict(paths: [String])
    case notASkill(String)
    case corruptState(String)
    case io(String)

    /// Distinct exit codes so agents can branch without parsing messages.
    public var exitCode: Int32 {
        switch self {
        case .simctlFailed, .xcodeRequired: 1
        case .unknownModel, .unsupportedModel, .noRuntime: 2
        case .deviceNotFound: 3
        case .leaseMismatch, .notLeased: 4
        case .deviceLeased, .deviceBusy, .deviceInUse, .takenOver: 5
        case .skillNotShipped, .skillConflict, .notASkill: 6
        case .corruptState, .io: 1
        case .invalidEnvironment: 64
        }
    }

    public var description: String {
        switch self {
        case .simctlFailed(let command, let status, let stderr):
            "`xcrun \(command)` failed with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .xcodeRequired(let stderr):
            "simctlhouse needs Xcode's simctl, but xcrun could not run it: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines)). "
                + "Install Xcode (Command Line Tools alone have no simulators), then select it with "
                + "`sudo xcode-select -s /Applications/Xcode.app` or point DEVELOPER_DIR at it."
        case .unknownModel(let model):
            "Unknown device model '\(model)'. Run `xcrun simctl list devicetypes` to see available models."
        case .unsupportedModel(let model):
            "'\(model)' is not an iPhone or iPad. simctlhouse only manages iPhone and iPad simulators."
        case .noRuntime(let model, let os):
            if let os {
                "No installed iOS runtime matching '\(os)' supports \(model). Run `xcrun simctl list runtimes`."
            } else {
                "No installed iOS runtime supports \(model). Install one with `xcodebuild -downloadPlatform iOS`."
            }
        case .deviceNotFound(let ref):
            "No simctlhouse device named or with UDID '\(ref)'. simctlhouse only manages devices it created; run `simctlhouse list`."
        case .leaseMismatch(let device):
            "The lease on \(device) does not match the given --lease-id. It was probably reclaimed and handed to another agent."
        case .notLeased(let device):
            "\(device) is not leased, so there is nothing to renew. Acquire a device first."
        case .deviceLeased(let device, let holder):
            "\(device) is leased" + (holder.map { " by \($0)" } ?? "") + ". Release it first or pass --force."
        case .deviceBusy(let device, let status):
            "\(device) is busy (\(status.rawValue)). Try again shortly."
        case .deviceInUse(let device):
            "\(device) is free, but another process is using it (its UDID appears in a running command). Pick another device."
        case .takenOver(let device):
            "\(device) was taken over while this command worked on it: it ran so long that another simctlhouse process "
                + "judged it hung and repaired it. Run `simctlhouse list` and try again."
        case .invalidEnvironment(let variable, let value, let expected):
            "\(variable)='\(value)' is invalid; expected \(expected)."
        case .skillNotShipped(let executable):
            "No skill ships with \(executable): <prefix>/share/simctlhouse/skills/simctlhouse is missing. "
                + "Install a release (e.g. with Homebrew), or pass --source with a checkout's skills/simctlhouse."
        case .skillConflict(let paths):
            "Not a simctlhouse skill link, left untouched: \(paths.joined(separator: ", ")). Remove it or pass --skills-dir."
        case .notASkill(let path):
            "\(path) is not the simctlhouse skill: expected a simctlhouse directory with a SKILL.md named simctlhouse."
        case .corruptState(let detail):
            "State file is unreadable: \(detail)"
        case .io(let detail):
            detail
        }
    }
}

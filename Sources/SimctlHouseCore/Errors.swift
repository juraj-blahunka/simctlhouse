import Foundation

public enum SimctlHouseError: Error, Equatable, CustomStringConvertible {
    case simctlFailed(command: String, status: Int32, stderr: String)
    case unknownModel(String)
    case unsupportedModel(String)
    case noRuntime(model: String, os: String?)
    case deviceNotFound(String)
    case leaseMismatch(device: String)
    case notLeased(device: String)
    case deviceLeased(device: String, holder: String?)
    case deviceBusy(device: String, status: PoolDevice.Status)
    case deviceInUse(device: String)
    case corruptState(String)
    case io(String)

    /// Distinct exit codes so agents can branch without parsing messages.
    public var exitCode: Int32 {
        switch self {
        case .simctlFailed: 1
        case .unknownModel, .unsupportedModel, .noRuntime: 2
        case .deviceNotFound: 3
        case .leaseMismatch, .notLeased: 4
        case .deviceLeased, .deviceBusy, .deviceInUse: 5
        case .corruptState, .io: 1
        }
    }

    public var description: String {
        switch self {
        case .simctlFailed(let command, let status, let stderr):
            "`xcrun \(command)` failed with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
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
        case .corruptState(let detail):
            "State file is unreadable: \(detail)"
        case .io(let detail):
            detail
        }
    }
}

import Foundation

/// Best-effort detection of simulator use that simctlhouse did not hand out.
///
/// A process counts as a user of a device when its command line mentions the device UDID,
/// e.g. `xcodebuild -destination id=<UDID>` or `xcrun simctl install <UDID> ...`.
/// The simulator's own processes (`launchd_sim` and friends) reference the device data
/// directory and are ignored. Use from the Xcode IDE or Simulator.app does not show up here.
public protocol ProcessScanner: Sendable {
    func commandLines() throws -> [String]
}

public struct PSProcessScanner: ProcessScanner {
    public init() {}

    public func commandLines() throws -> [String] {
        let result = try Subprocess.run("/bin/ps", ["-axww", "-o", "command="])
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

extension ProcessScanner {
    /// UDIDs (uppercased) that appear in some foreign process command line.
    func udidsInUse(among udids: [String]) -> Set<String> {
        guard !udids.isEmpty, let lines = try? commandLines() else { return [] }
        var inUse: Set<String> = []
        for line in lines {
            let upper = line.uppercased()
            // Our own invocations (e.g. a concurrent `simctlhouse release <UDID>`) are not foreign use.
            if upper.contains("SIMCTLHOUSE") { continue }
            for udid in udids where !inUse.contains(udid.uppercased()) {
                let needle = udid.uppercased()
                guard upper.contains(needle) else { continue }
                if upper.contains("/CORESIMULATOR/DEVICES/\(needle)") { continue }
                inUse.insert(needle)
            }
        }
        return inUse
    }
}

import Foundation
import Testing
@testable import SimctlHouseCore

/// `Simctl` against output recorded from `xcrun simctl` (Xcode 27.2), trimmed to a few entries.
/// The fakes elsewhere build these values directly, so only these tests catch a change in what `simctl` prints.
@Suite struct SimctlTests {
    @Test func decodesDevicesOfEveryRuntime() throws {
        let (simctl, calls) = Simctl.replying(stdout: Self.devices)
        let devices = try simctl.devices().sorted { $0.name < $1.name }
        #expect(
            devices == [
                SimDevice(
                    udid: "11111111-1111-4111-8111-111111111111", name: "amber-falcon", state: "Booted",
                    deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"),
                SimDevice(
                    udid: "22222222-2222-4222-8222-222222222222", name: "civic-zephyr", state: "Shutdown", isAvailable: false,
                    deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"),
            ])
        #expect(devices[0].isBooted)
        #expect(calls.all == [["list", "devices", "-j"]])
    }

    @Test func decodesDeviceTypes() throws {
        let (simctl, calls) = Simctl.replying(stdout: Self.deviceTypes)
        #expect(
            try simctl.deviceTypes() == [
                SimDeviceType(
                    identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", name: "iPhone 18 Pro", productFamily: "iPhone",
                    modelIdentifier: "iPhone19,2"),
                SimDeviceType(
                    identifier: "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", name: "Apple Watch Series 11 (46mm)",
                    productFamily: "Apple Watch", modelIdentifier: "Watch7,18"),
            ])
        #expect(calls.all == [["list", "devicetypes", "-j"]])
    }

    @Test func decodesRuntimes() throws {
        let (simctl, calls) = Simctl.replying(stdout: Self.runtimes)
        #expect(
            try simctl.runtimes() == [
                SimRuntime(
                    identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", name: "iOS 27.2", version: "27.2", platform: "iOS",
                    supportedDeviceTypes: ["com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"]),
                SimRuntime(
                    identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-3", name: "iOS 18.3", version: "18.3.1", platform: "iOS",
                    isAvailable: false, supportedDeviceTypes: []),
            ])
        #expect(calls.all == [["list", "runtimes", "-j"]])
    }

    @Test func createReturnsTheTrimmedUDID() throws {
        let (simctl, calls) = Simctl.replying(stdout: "33333333-3333-4333-8333-333333333333\n")
        let udid = try simctl.create(
            name: "amber-falcon", deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        #expect(udid == "33333333-3333-4333-8333-333333333333")
        #expect(
            calls.all == [
                ["create", "amber-falcon", "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "com.apple.CoreSimulator.SimRuntime.iOS-27-2"]
            ])
    }

    @Test func bootWaitsUntilBootHasCompleted() throws {
        let (simctl, calls) = Simctl.replying(stdout: "")
        try simctl.bootAndWait(udid: "X")
        #expect(calls.all == [["bootstatus", "X", "-b"]])
    }

    @Test func shuttingDownAShutDownDeviceIsNoFailure() throws {
        let (simctl, calls) = Simctl.replying(status: 149, stderr: Self.alreadyShutDown)
        try simctl.shutdown(udid: "X")
        #expect(calls.all == [["shutdown", "X"]])
    }

    @Test func aFailureCarriesTheCommandStatusAndStderr() {
        let (simctl, _) = Simctl.replying(status: 148, stderr: "Invalid device: X\n")
        #expect(throws: SimctlHouseError.simctlFailed(command: "simctl shutdown X", status: 148, stderr: "Invalid device: X\n")) {
            try simctl.shutdown(udid: "X")
        }
        #expect(throws: SimctlHouseError.simctlFailed(command: "simctl delete X", status: 148, stderr: "Invalid device: X\n")) {
            try simctl.delete(udid: "X")
        }
    }

    @Test func withoutXcodeTheErrorSaysToInstallIt() {
        // Recorded with DEVELOPER_DIR=/Library/Developer/CommandLineTools.
        let stderr = "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH\n"
        let (simctl, _) = Simctl.replying(status: 72, stderr: stderr)
        #expect(throws: SimctlHouseError.xcodeRequired(stderr: stderr)) { try simctl.devices() }
        #expect(SimctlHouseError.xcodeRequired(stderr: stderr).description.contains("xcode-select -s /Applications/Xcode.app"))
    }

    // MARK: - recorded output

    static let alreadyShutDown = """
        An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):
        Unable to shutdown device in current state: Shutdown

        """

    static let devices = """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-2" : [
              {
                "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/11111111-1111-4111-8111-111111111111/data",
                "dataPathSize" : 18337792,
                "logPath" : "/Users/me/Library/Logs/CoreSimulator/11111111-1111-4111-8111-111111111111",
                "udid" : "11111111-1111-4111-8111-111111111111",
                "isAvailable" : true,
                "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                "state" : "Booted",
                "name" : "amber-falcon"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-3" : [
              {
                "availabilityError" : "runtime profile not found using \\"System\\" match policy",
                "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/22222222-2222-4222-8222-222222222222/data",
                "logPath" : "/Users/me/Library/Logs/CoreSimulator/22222222-2222-4222-8222-222222222222",
                "udid" : "22222222-2222-4222-8222-222222222222",
                "isAvailable" : false,
                "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
                "state" : "Shutdown",
                "name" : "civic-zephyr"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-0" : []
          }
        }
        """

    static let deviceTypes = """
        {
          "devicetypes" : [
            {
              "productFamily" : "iPhone",
              "bundlePath" : "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 18 Pro.simdevicetype",
              "maxRuntimeVersion" : 4294967295,
              "maxRuntimeVersionString" : "65535.255.255",
              "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
              "modelIdentifier" : "iPhone19,2",
              "minRuntimeVersionString" : "27.0.0",
              "minRuntimeVersion" : 1769472,
              "name" : "iPhone 18 Pro"
            },
            {
              "productFamily" : "Apple Watch",
              "bundlePath" : "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/Apple Watch Series 11 (46mm).simdevicetype",
              "maxRuntimeVersion" : 4294967295,
              "maxRuntimeVersionString" : "65535.255.255",
              "identifier" : "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm",
              "modelIdentifier" : "Watch7,18",
              "minRuntimeVersionString" : "26.0.0",
              "minRuntimeVersion" : 1703936,
              "name" : "Apple Watch Series 11 (46mm)"
            }
          ]
        }
        """

    static let runtimes = """
        {
          "runtimes" : [
            {
              "isAvailable" : true,
              "version" : "27.2",
              "isInternal" : false,
              "buildversion" : "24B8117",
              "supportedArchitectures" : ["arm64"],
              "supportedDeviceTypes" : [
                {
                  "bundlePath" : "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 18 Pro.simdevicetype",
                  "name" : "iPhone 18 Pro",
                  "productFamily" : "iPhone",
                  "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
                }
              ],
              "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
              "platform" : "iOS",
              "bundlePath" : "/Library/Developer/CoreSimulator/Volumes/iOS_24B8117/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.2.simruntime",
              "lastUsage" : { "arm64" : "0001-01-01T00:00:00Z" },
              "name" : "iOS 27.2"
            },
            {
              "isAvailable" : false,
              "availabilityError" : "The runtime's disk image is not mounted.",
              "version" : "18.3.1",
              "isInternal" : false,
              "buildversion" : "22D8075",
              "supportedArchitectures" : ["x86_64", "arm64"],
              "supportedDeviceTypes" : [],
              "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-3",
              "platform" : "iOS",
              "name" : "iOS 18.3"
            }
          ]
        }
        """
}

/// The arguments of every `simctl` call, in order.
final class SimctlCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    var all: [[String]] { lock.withLock { calls } }
    func record(_ arguments: [String]) { lock.withLock { calls.append(arguments) } }
}

extension Simctl {
    /// A `Simctl` whose every call returns this output, recording its arguments in `calls`.
    static func replying(status: Int32 = 0, stdout: String = "", stderr: String = "") -> (Simctl, SimctlCalls) {
        let calls = SimctlCalls()
        let simctl = Simctl { arguments in
            calls.record(arguments)
            return Subprocess.Result(status: status, stdout: Data(stdout.utf8), stderr: stderr)
        }
        return (simctl, calls)
    }
}

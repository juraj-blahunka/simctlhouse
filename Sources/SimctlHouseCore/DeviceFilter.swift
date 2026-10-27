import Foundation

/// The arguments of `list`, modelled on `simctl list devices [booted | <search term>]`.
///
/// A state or status keyword (`booted`, `leased`, ...) restricts the list; every keyword must match.
/// Any other argument is a search term matched case-insensitively against the name, UDID, model, `iOS <version>`
/// and holder; a device matching any term is shown. Device names always contain a hyphen and UDIDs are hex,
/// so a keyword can never be mistaken for a device.
public struct DeviceFilter: Equatable, Sendable {
    /// CoreSimulator states as shown in the STATE column, lowercased.
    public static let stateKeywords = ["booted", "shutdown"]
    public static let statusKeywords = PoolDevice.Status.allCases.map(\.rawValue)

    public var keywords: [String] = []
    public var terms: [String] = []

    public init(_ arguments: [String]) {
        for argument in arguments {
            let lowered = argument.lowercased()
            if Self.stateKeywords.contains(lowered) || Self.statusKeywords.contains(lowered) {
                keywords.append(lowered)
            } else {
                terms.append(argument)
            }
        }
    }

    public func matches(_ device: DeviceInfo) -> Bool {
        let keywordsMatch = keywords.allSatisfy { $0 == device.state.lowercased() || $0 == device.status.rawValue }
        let searchable = [device.name, device.udid ?? "", device.model, "iOS \(device.os)", device.holder ?? ""]
        let termsMatch = terms.isEmpty || terms.contains { term in searchable.contains { $0.localizedCaseInsensitiveContains(term) } }
        return keywordsMatch && termsMatch
    }
}

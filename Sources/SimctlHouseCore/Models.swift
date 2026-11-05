import Foundation

/// Persisted pool state. Lives in `<home>/state.json` and is only mutated under `StateStore.transaction`.
public struct PoolState: Codable, Equatable, Sendable {
    /// Bump with every change to what `state.json` holds. A build refuses a newer file, so it never drops fields it does
    /// not know; new fields must be optional, so an older file still decodes.
    public static let currentVersion = 2
    /// How many deleted, vanished or reclaimed devices `history` can still report on.
    public static let retiredLimit = 50

    public var version: Int
    public var devices: [PoolDevice]
    /// Devices that left the pool, oldest first. Kept only for `history`; never acted on.
    public var retired: [RetiredDevice]

    public init(version: Int = PoolState.currentVersion, devices: [PoolDevice] = [], retired: [RetiredDevice] = []) {
        self.version = version
        self.devices = devices
        self.retired = retired
    }

    public func index(of ref: String) -> Int? {
        let needle = ref.lowercased()
        return devices.firstIndex { $0.name == needle || $0.udid?.lowercased() == needle }
    }

    /// Records a device's identity in `retired`, closing its lease with the same reason.
    mutating func retire(_ device: PoolDevice, reason: EndReason, at now: Date) {
        var device = device
        device.endLease(reason, at: now)
        retired.append(
            RetiredDevice(
                name: device.name,
                udid: device.udid,
                deviceTypeIdentifier: device.deviceTypeIdentifier,
                runtimeIdentifier: device.runtimeIdentifier,
                createdAt: device.createdAt,
                retiredAt: now,
                reason: reason,
                history: device.history
            )
        )
        if retired.count > Self.retiredLimit { retired.removeFirst(retired.count - Self.retiredLimit) }
    }

    /// Removes the record at `index` and retires it.
    mutating func retire(at index: Int, reason: EndReason, at now: Date) {
        retire(devices.remove(at: index), reason: reason, at: now)
    }
}

public struct PoolDevice: Codable, Equatable, Sendable {
    /// How many finished leases a device remembers.
    public static let historyLimit = 5

    public enum Status: String, Codable, CaseIterable, Sendable {
        /// Name reserved, simulator is being created, or re-created after an expired lease. `udid` is nil until it exists.
        /// Carries a `claim`.
        case provisioning
        /// In the pool, free to acquire.
        case available
        /// Held by an agent until `lease.expiresAt`.
        case leased
        /// simctlhouse is shutting down, erasing or deleting the device. Not acquirable. Carries a `claim`.
        case maintenance
    }

    /// Two-word identifier, e.g. `amber-falcon`. Also the simulator's display name.
    public var name: String
    public var udid: String?
    /// While a reclaim re-creates the device: the simulator of the expired lease, not yet deleted.
    /// Kept out of `udid` so nothing can look the record up by it or hand it out.
    public var replacedUDID: String?
    public var deviceTypeIdentifier: String
    public var runtimeIdentifier: String
    public var status: Status
    public var lease: Lease?
    /// The process working on the device while it is `provisioning` or `maintenance`; nil otherwise.
    public var claim: Claim?
    public var createdAt: Date
    /// When status last changed. Used to detect operations stuck in a hung process.
    public var statusChangedAt: Date
    /// Last moment an agent held or released the device. Drives the idle shutdown.
    public var lastActivityAt: Date
    /// The most recent finished leases, oldest first. The current one lives in `lease`.
    public var history: [LeaseRecord]

    public init(
        name: String,
        udid: String?,
        deviceTypeIdentifier: String,
        runtimeIdentifier: String,
        status: Status,
        lease: Lease? = nil,
        claim: Claim? = nil,
        now: Date
    ) {
        self.name = name
        self.udid = udid
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
        self.status = status
        self.lease = lease
        self.claim = claim
        self.createdAt = now
        self.statusChangedAt = now
        self.lastActivityAt = now
        self.history = []
    }

    /// Moves to `provisioning` or `maintenance` on behalf of the process holding `claim`.
    mutating func begin(_ status: Status, claim: Claim, at now: Date) {
        self.status = status
        self.statusChangedAt = now
        self.claim = claim
    }

    /// Moves to `available` or `leased`, ending any claim.
    mutating func transition(to status: Status, at now: Date) {
        self.status = status
        self.statusChangedAt = now
        self.claim = nil
    }

    /// Ends a claim whose work did not happen: back to `leased` while the lease still holds it, otherwise `available`.
    /// An expired lease is then reclaimed by GC as usual.
    mutating func restore(at now: Date) {
        transition(to: lease == nil ? .available : .leased, at: now)
    }

    /// Clears the current lease, if any, and records how it ended.
    mutating func endLease(_ reason: EndReason, at now: Date) {
        guard let lease else { return }
        history.append(LeaseRecord(lease: lease, udid: udid, endedAt: now, outcome: reason))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        self.lease = nil
    }
}

/// Marks a `provisioning` or `maintenance` record as being worked on by one process, outside the lock.
/// GC repairs the record only once that process is gone, or has run longer than `PoolConfig.hungOperation`,
/// and the process finishes its work only if the record still carries the claim, so late work never overwrites a repair.
/// A `simctl` call still running when its process is judged hung does act on the simulator, though (see D28).
public struct Claim: Codable, Equatable, Sendable {
    public var id: String
    public var pid: Int32
    /// When `pid` started, in whole seconds, so a recycled pid is not mistaken for the owner.
    public var processStartedAt: Date?
}

public struct Lease: Codable, Equatable, Sendable {
    public var id: String
    /// Free-form label supplied by the agent (`--holder` / `SIMCTLHOUSE_HOLDER`).
    public var holder: String?
    /// Parent process of the `acquire` invocation, for diagnostics only.
    public var pid: Int32?
    public var cwd: String?
    public var acquiredAt: Date
    public var expiresAt: Date
    /// The process the lease is bound to (`simctlhouse run`), if any. While it runs, the lease does not expire;
    /// once it is gone, GC reclaims the device, since nothing will release it any more (D33).
    public var owner: ProcessRef? = nil
}

/// A running process, identified by its pid and start time, so a recycled pid is not mistaken for it.
public struct ProcessRef: Codable, Equatable, Sendable {
    public var pid: Int32
    /// When `pid` started, in whole seconds; nil if it could not be read.
    public var processStartedAt: Date?

    public init(pid: Int32, processStartedAt: Date?) {
        self.pid = pid
        self.processStartedAt = processStartedAt
    }
}

/// Why a lease ended or a device left the pool.
public enum EndReason: String, Codable, Sendable {
    /// The holder released it.
    case released
    /// Not released or renewed in time; reclaimed.
    case expired
    /// `erase --force` wiped the device under the lease.
    case erased
    /// `delete` removed the device.
    case deleted
    /// The simulator disappeared outside simctlhouse (Xcode, `simctl delete`, CoreSimulator).
    case vanished
    /// Creating or booting the simulator failed.
    case failed
    /// The process creating it died midway, or the `run` process holding the lease exited without releasing it.
    case abandoned
    /// Its runtime was uninstalled, so it could not be rebuilt.
    case runtimeRemoved
}

/// One lease, for the audit trail shown by `history`.
public struct LeaseRecord: Codable, Equatable, Sendable {
    public var leaseId: String
    public var holder: String?
    public var pid: Int32?
    public var cwd: String?
    /// The device's UDID during the lease, so each record stands on its own in the audit trail.
    public var udid: String?
    public var acquiredAt: Date
    /// nil while the lease is active.
    public var endedAt: Date?
    public var outcome: EndReason?

    init(lease: Lease, udid: String?, endedAt: Date?, outcome: EndReason?) {
        self.leaseId = lease.id
        self.holder = lease.holder
        self.pid = lease.pid
        self.cwd = lease.cwd
        self.udid = udid
        self.acquiredAt = lease.acquiredAt
        self.endedAt = endedAt
        self.outcome = outcome
    }
}

/// A device that left the pool, kept so `history` can still say who held it and how it ended.
public struct RetiredDevice: Codable, Equatable, Sendable {
    public var name: String
    public var udid: String?
    public var deviceTypeIdentifier: String
    public var runtimeIdentifier: String
    public var createdAt: Date
    public var retiredAt: Date
    public var reason: EndReason
    public var history: [LeaseRecord]
}

/// What the caller asked for. All fields optional; `Catalog` fills in defaults.
public struct DeviceSpec: Equatable, Sendable {
    public enum Family: String, CaseIterable, Sendable {
        case iphone
        case ipad

        var productFamily: String {
            switch self {
            case .iphone: "iPhone"
            case .ipad: "iPad"
            }
        }
    }

    public var family: Family?
    public var model: String?
    public var os: String?

    public init(family: Family? = nil, model: String? = nil, os: String? = nil) {
        self.family = family
        self.model = model
        self.os = os
    }
}

/// A concrete device type + runtime pair. Pool devices are matched on it.
public struct ResolvedSpec: Equatable, Hashable, Sendable {
    public var deviceType: SimDeviceType
    public var runtime: SimRuntime
}

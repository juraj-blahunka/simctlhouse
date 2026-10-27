import Foundation

public struct PoolConfig: Sendable {
    /// A lease not released or renewed within this window is forcefully reclaimed.
    public var leaseDuration: TimeInterval = 30 * 60
    /// Free booted devices are shut down after this much inactivity. The `gc` command shuts them down regardless.
    public var idleShutdown: TimeInterval = 15 * 60
    /// `provisioning` / `maintenance` records older than this were abandoned by a crashed process.
    public var staleOperation: TimeInterval = 10 * 60

    public init() {}

    /// Timeouts are fixed by design; the overrides exist so end-to-end tests do not have to wait 30 minutes.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PoolConfig {
        var config = PoolConfig()
        if let value = environment["SIMCTLHOUSE_LEASE_SECONDS"].flatMap(TimeInterval.init) { config.leaseDuration = value }
        if let value = environment["SIMCTLHOUSE_IDLE_SECONDS"].flatMap(TimeInterval.init) { config.idleShutdown = value }
        return config
    }
}

public struct AcquireRequest: Sendable {
    public var spec: DeviceSpec
    /// A specific pool device (name or UDID) to lease instead of any device matching `spec`.
    public var device: String?
    public var holder: String?
    public var pid: Int32?
    public var cwd: String?

    public init(spec: DeviceSpec = DeviceSpec(), device: String? = nil, holder: String? = nil, pid: Int32? = nil, cwd: String? = nil) {
        self.spec = spec
        self.device = device
        self.holder = holder
        self.pid = pid
        self.cwd = cwd
    }
}

/// Row shown by `list` and returned (as JSON) by most commands.
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var name: String
    public var udid: String?
    public var status: PoolDevice.Status
    /// CoreSimulator state (`Booted`, `Shutdown`, ...) or `Missing` if the simulator no longer exists.
    public var state: String
    public var model: String
    public var os: String
    public var holder: String?
    public var leaseId: String?
    public var acquiredAt: Date?
    public var expiresAt: Date?
    public var lastActivityAt: Date
}

/// A device's audit trail, returned by `history`. Covers devices in the pool and devices that left it.
public struct DeviceHistory: Codable, Equatable, Sendable {
    public var name: String
    public var udid: String?
    public var model: String
    public var os: String
    public var createdAt: Date
    /// Set once the device left the pool.
    public var retiredAt: Date?
    public var retiredReason: EndReason?
    /// Oldest first. An active lease comes last, without `endedAt`.
    public var leases: [LeaseRecord]

    /// Also matches UDIDs the device had before a `reset`.
    func matches(_ ref: String) -> Bool {
        let needle = ref.lowercased()
        return name == needle || udid?.lowercased() == needle || leases.contains { $0.udid?.lowercased() == needle }
    }
}

public struct GCReport: Codable, Equatable, Sendable {
    public var reclaimed: [String] = []
    public var shutDown: [String] = []
    public var forgotten: [String] = []
    public var recovered: [String] = []

    public var isEmpty: Bool { reclaimed.isEmpty && shutDown.isEmpty && forgotten.isEmpty && recovered.isEmpty }
}

public struct Pool: Sendable {
    public let store: StateStore
    public let backend: SimulatorBackend
    public let scanner: ProcessScanner
    public let config: PoolConfig
    let now: @Sendable () -> Date
    let log: @Sendable (String) -> Void

    public init(
        paths: HousePaths,
        backend: SimulatorBackend = Simctl(),
        scanner: ProcessScanner = PSProcessScanner(),
        config: PoolConfig = PoolConfig(),
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = StateStore(paths: paths)
        self.backend = backend
        self.scanner = scanner
        self.config = config
        self.now = now
        self.log = log
    }

    // MARK: - acquire / release / renew

    /// Leases a specific free device, or a free matching one, creating it if needed, then boots it.
    public func acquire(_ request: AcquireRequest) throws -> DeviceInfo {
        let catalog = try collectGarbageAndLoadCatalog()

        enum Target {
            case device(String)
            case spec(ResolvedSpec)
        }

        enum Plan {
            case reuse(PoolDevice, booted: Bool)
            case provision(name: String, ResolvedSpec)
        }

        let target: Target = try request.device.map(Target.device) ?? .spec(catalog.resolve(request.spec))
        let plan = try store.transaction { state -> Plan in
            let now = now()
            let lease = Lease(
                id: UUID().uuidString.lowercased(),
                holder: request.holder,
                pid: request.pid,
                cwd: request.cwd,
                acquiredAt: now,
                expiresAt: now.addingTimeInterval(config.leaseDuration)
            )
            let live = try liveDevices()

            func take(_ index: Int) -> Plan {
                state.devices[index].transition(to: .leased, at: now)
                state.devices[index].lease = lease
                state.devices[index].lastActivityAt = now
                let device = state.devices[index]
                return .reuse(device, booted: device.udid.flatMap { live[$0] }?.isBooted == true)
            }

            switch target {
            case .device(let ref):
                guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
                let device = state.devices[index]
                try ensureMutable(device, force: false)
                if let udid = device.udid, !scanner.udidsInUse(among: [udid]).isEmpty { throw SimctlHouseError.deviceInUse(device: device.name) }
                return take(index)

            case .spec(let resolved):
                let candidates = state.devices.filter { device in
                    device.status == .available
                        && device.deviceTypeIdentifier == resolved.deviceType.identifier
                        && device.runtimeIdentifier == resolved.runtime.identifier
                        && device.udid.map { live[$0] != nil } == true
                }
                let foreign = scanner.udidsInUse(among: candidates.compactMap(\.udid))
                let usable = candidates.filter { !foreign.contains($0.udid!.uppercased()) }
                // Prefer an already booted device (no boot wait), then the most recently used one (warmest caches).
                let pick = usable.max { lhs, rhs in
                    let lhsBooted = live[lhs.udid!]?.isBooted == true
                    let rhsBooted = live[rhs.udid!]?.isBooted == true
                    if lhsBooted != rhsBooted { return !lhsBooted }
                    return lhs.lastActivityAt < rhs.lastActivityAt
                }
                for device in candidates where foreign.contains(device.udid!.uppercased()) {
                    log("Skipping \(device.name): another process is using it.")
                }
                if let pick, let index = state.index(of: pick.name) { return take(index) }
                let name = freshName(state: state, live: live)
                state.devices.append(
                    PoolDevice(
                        name: name,
                        udid: nil,
                        deviceTypeIdentifier: resolved.deviceType.identifier,
                        runtimeIdentifier: resolved.runtime.identifier,
                        status: .provisioning,
                        lease: lease,
                        now: now
                    )
                )
                return .provision(name: name, resolved)
            }
        }

        let device: PoolDevice
        var isBooted = false
        switch plan {
        case .reuse(let reused, let booted):
            device = reused
            isBooted = booted
        case .provision(let name, let resolved):
            log("No free \(resolved.deviceType.name) (iOS \(resolved.runtime.version)) in the pool; creating \(name). Its first boot takes about 30s.")
            device = try provision(name: name, resolved: resolved, finalStatus: .leased)
        }

        do {
            if !isBooted { log("Booting \(device.name)...") }
            // Also called for booted devices: bootstatus returns immediately once boot has fully completed.
            try backend.bootAndWait(udid: device.udid!)
        } catch {
            // A device that cannot boot is useless to the next agent too; drop it instead of returning it to the pool.
            log("Boot of \(device.name) failed; removing it from the pool.")
            try? destroy(device, reason: .failed)
            throw error
        }
        return try info(for: device.name, catalog: catalog)
    }

    /// Returns a leased device to the pool. The device stays booted (and is not erased) for fast reuse.
    @discardableResult
    public func release(_ ref: String, leaseId: String? = nil) throws -> DeviceInfo {
        try collectGarbage()
        let name = try store.transaction { state -> String in
            guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
            let device = state.devices[index]
            guard device.status == .leased else {
                log("\(device.name) is not leased; nothing to release.")
                return device.name
            }
            if let leaseId, device.lease?.id != leaseId { throw SimctlHouseError.leaseMismatch(device: device.name) }
            let now = now()
            state.devices[index].endLease(.released, at: now)
            state.devices[index].transition(to: .available, at: now)
            state.devices[index].lastActivityAt = now
            return device.name
        }
        return try info(for: name)
    }

    /// Extends a lease by another full lease duration from now.
    @discardableResult
    public func renew(_ ref: String, leaseId: String? = nil) throws -> DeviceInfo {
        try collectGarbage()
        let name = try store.transaction { state -> String in
            guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
            let device = state.devices[index]
            guard device.status == .leased, var lease = device.lease else {
                throw SimctlHouseError.notLeased(device: device.name)
            }
            if let leaseId, lease.id != leaseId { throw SimctlHouseError.leaseMismatch(device: device.name) }
            let now = now()
            lease.expiresAt = now.addingTimeInterval(config.leaseDuration)
            state.devices[index].lease = lease
            state.devices[index].lastActivityAt = now
            return device.name
        }
        return try info(for: name)
    }

    // MARK: - create / delete / reset / list / history

    /// Adds a new, shut down device to the pool without leasing it.
    public func create(_ spec: DeviceSpec) throws -> DeviceInfo {
        let catalog = try collectGarbageAndLoadCatalog()
        let resolved = try catalog.resolve(spec)
        let name = try store.transaction { state -> String in
            let name = freshName(state: state, live: try liveDevices())
            state.devices.append(
                PoolDevice(
                    name: name,
                    udid: nil,
                    deviceTypeIdentifier: resolved.deviceType.identifier,
                    runtimeIdentifier: resolved.runtime.identifier,
                    status: .provisioning,
                    now: now()
                )
            )
            return name
        }
        let device = try provision(name: name, resolved: resolved, finalStatus: .available)
        return try info(for: device.name, catalog: catalog)
    }

    /// Shuts down and deletes pool devices. Leased devices require `force`.
    public func delete(_ refs: [String], force: Bool) throws -> [String] {
        try collectGarbage()
        let targets = try store.transaction { state -> [PoolDevice] in
            let indices = try refs.map { ref -> Int in
                guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
                try ensureMutable(state.devices[index], force: force)
                return index
            }
            for index in indices { state.devices[index].transition(to: .maintenance, at: now()) }
            return indices.map { state.devices[$0] }
        }
        for device in targets {
            try destroy(device, reason: .deleted)
            log("Deleted \(device.name).")
        }
        return targets.map(\.name)
    }

    public func deleteAll(force: Bool) throws -> [String] {
        try delete(try store.snapshot().devices.map(\.name), force: force)
    }

    /// Wipes a device back to a pristine, shut down state by deleting and re-creating it. Keeps the name.
    public func reset(_ ref: String, force: Bool) throws -> DeviceInfo {
        try collectGarbage()
        let device = try store.transaction { state -> PoolDevice in
            guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
            try ensureMutable(state.devices[index], force: force)
            let now = now()
            state.devices[index].endLease(.reset, at: now)
            state.devices[index].transition(to: .maintenance, at: now)
            return state.devices[index]
        }
        try recycle(device, as: device.name)
        return try info(for: device.name)
    }

    /// All devices, or only those named by `refs` (names or UDIDs), in pool order.
    public func list(_ refs: [String] = []) throws -> [DeviceInfo] {
        let (gc, catalog) = try concurrently({ try runGarbageCollection() }, { try Catalog(backend: backend) })
        let live = try gc.untouchedLive ?? liveDevices()
        let state = try store.snapshot()
        let devices =
            try refs.isEmpty
            ? state.devices
            : refs.map { ref in
                guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
                return state.devices[index]
            }
        return devices.map { describe($0, live: live, catalog: catalog) }
    }

    /// Lease history of every device, including ones that left the pool, or of the one device matching `ref`.
    /// `ref` may also be a name or UDID the device no longer has (after `reset`, expiry, `delete`).
    public func history(_ ref: String? = nil) throws -> [DeviceHistory] {
        let catalog = try collectGarbageAndLoadCatalog()
        let state = try store.snapshot()
        let retired = state.retired.map { device in
            DeviceHistory(
                name: device.name,
                udid: device.udid,
                model: modelName(device.deviceTypeIdentifier, catalog: catalog),
                os: osVersion(device.runtimeIdentifier, catalog: catalog),
                createdAt: device.createdAt,
                retiredAt: device.retiredAt,
                retiredReason: device.reason,
                leases: device.history
            )
        }
        let current = state.devices.map { device in
            DeviceHistory(
                name: device.name,
                udid: device.udid,
                model: modelName(device.deviceTypeIdentifier, catalog: catalog),
                os: osVersion(device.runtimeIdentifier, catalog: catalog),
                createdAt: device.createdAt,
                leases: device.history + (device.lease.map { [LeaseRecord(lease: $0, udid: device.udid, endedAt: nil, outcome: nil)] } ?? [])
            )
        }
        guard let ref else { return retired + current }
        // A device in the pool wins over a retired one; among retired ones, the most recent.
        guard let match = current.first(where: { $0.matches(ref) }) ?? retired.last(where: { $0.matches(ref) }) else {
            throw SimctlHouseError.deviceNotFound(ref)
        }
        return [match]
    }

    // MARK: - garbage collection

    /// Enforces lease expiry and idle shutdown and repairs state after crashes. Runs at the start of every command.
    /// `shutDownAllFree` (the `gc` command) shuts down every free booted device without waiting for the idle timeout.
    @discardableResult
    public func collectGarbage(shutDownAllFree: Bool = false) throws -> GCReport {
        try runGarbageCollection(shutDownAllFree: shutDownAllFree).report
    }

    /// GC and the device type/runtime listing are independent `simctl` calls, so they run at the same time.
    private func collectGarbageAndLoadCatalog() throws -> Catalog {
        try concurrently({ try collectGarbage() }, { try Catalog(backend: backend) }).1
    }

    /// `untouchedLive` is the live snapshot GC worked from, returned only when GC changed no simulator,
    /// so a caller can use it instead of listing devices again.
    private func runGarbageCollection(shutDownAllFree: Bool = false) throws -> (report: GCReport, untouchedLive: [String: SimDevice]?) {
        enum Job {
            case reclaim(PoolDevice, newName: String)
            case shutdown(PoolDevice)
            case deleteOrphan(udid: String)
        }

        var report = GCReport()
        let (jobs, live) = try store.transaction { state -> ([Job], [String: SimDevice]) in
            let now = now()
            let live = try liveDevices()
            var jobs: [Job] = []
            var keep: [PoolDevice] = []
            let idleCandidates = state.devices.filter { $0.status == .available && $0.udid.flatMap { live[$0] }?.isBooted == true }
            let foreign = scanner.udidsInUse(among: idleCandidates.compactMap(\.udid))

            for var device in state.devices {
                let isStale = now.timeIntervalSince(device.statusChangedAt) > config.staleOperation
                switch device.status {
                case .provisioning:
                    guard isStale else { break }
                    // The creating process died midway. Remove any half-made simulator carrying our name.
                    for orphan in live.values where orphan.name == device.name { jobs.append(.deleteOrphan(udid: orphan.udid)) }
                    state.retire(device, reason: .abandoned, at: now)
                    report.forgotten.append(device.name)
                    continue
                case .maintenance:
                    guard isStale else { break }
                    if let udid = device.udid, live[udid] != nil {
                        device.transition(to: .available, at: now)
                        report.recovered.append(device.name)
                    } else {
                        state.retire(device, reason: .vanished, at: now)
                        report.forgotten.append(device.name)
                        continue
                    }
                case .available, .leased:
                    guard let udid = device.udid, live[udid] != nil else {
                        // Deleted behind our back (Xcode, `simctl delete`, ...). Nothing left to manage.
                        state.retire(device, reason: .vanished, at: now)
                        report.forgotten.append(device.name)
                        continue
                    }
                }

                if device.status == .leased, let lease = device.lease, lease.expiresAt <= now {
                    // Rename right away so a stale agent can no longer address the device by its old name.
                    // The old identity and its lease history move to `retired`; the erased device starts fresh.
                    let newName = freshName(state: state, live: live, alsoAvoiding: keep.map(\.name))
                    state.retire(device, reason: .expired, at: now)
                    device.lease = nil
                    device.history = []
                    device.createdAt = now
                    device.transition(to: .maintenance, at: now)
                    jobs.append(.reclaim(device, newName: newName))
                    report.reclaimed.append(device.name)
                    device.name = newName
                } else if device.status == .available, let udid = device.udid, live[udid]?.isBooted == true {
                    if foreign.contains(udid.uppercased()) {
                        device.lastActivityAt = now
                    } else if shutDownAllFree || now.timeIntervalSince(device.lastActivityAt) >= config.idleShutdown {
                        device.transition(to: .maintenance, at: now)
                        jobs.append(.shutdown(device))
                        report.shutDown.append(device.name)
                    }
                }
                keep.append(device)
            }
            state.devices = keep
            return (jobs, live)
        }

        // Each job touches a different simulator, so they run in parallel.
        concurrentForEach(jobs) { job in
            switch job {
            case .reclaim(let device, let newName):
                log("Lease on \(device.name) expired; erasing it and returning it to the pool as \(newName).")
                do {
                    try recycle(device, as: newName)
                } catch {
                    log("Reclaiming \(newName) failed: \(error). It will be retried later.")
                }
            case .shutdown(let device):
                log(shutDownAllFree ? "Shutting down \(device.name), which is free." : "\(device.name) has been idle; shutting it down.")
                do {
                    try backend.shutdown(udid: device.udid!)
                    try store.transaction { state in
                        guard let index = state.index(of: device.name), state.devices[index].status == .maintenance else { return }
                        state.devices[index].transition(to: .available, at: now())
                    }
                } catch {
                    log("Shutting down \(device.name) failed: \(error). It will be retried later.")
                }
            case .deleteOrphan(let udid):
                try? backend.delete(udid: udid)
            }
        }
        return (report, jobs.isEmpty ? live : nil)
    }

    // MARK: - internals

    private func ensureMutable(_ device: PoolDevice, force: Bool) throws {
        switch device.status {
        case .available: return
        case .leased where force: return
        case .leased: throw SimctlHouseError.deviceLeased(device: device.name, holder: device.lease?.holder)
        case .provisioning, .maintenance: throw SimctlHouseError.deviceBusy(device: device.name, status: device.status)
        }
    }

    /// Creates the simulator for a `provisioning` record and moves it to `finalStatus`.
    private func provision(name: String, resolved: ResolvedSpec, finalStatus: PoolDevice.Status) throws -> PoolDevice {
        let udid: String
        do {
            udid = try backend.create(name: name, deviceType: resolved.deviceType.identifier, runtime: resolved.runtime.identifier)
        } catch {
            try? store.transaction { state in state.retire(named: name, reason: .failed, at: now()) }
            throw error
        }
        return try store.transaction { state -> PoolDevice in
            guard let index = state.index(of: name) else {
                try? backend.delete(udid: udid)
                throw SimctlHouseError.io("Provisioning record for \(name) disappeared; was the state file edited?")
            }
            let now = now()
            state.devices[index].udid = udid
            state.devices[index].transition(to: finalStatus, at: now)
            state.devices[index].lastActivityAt = now
            return state.devices[index]
        }
    }

    /// Replaces a `maintenance` device with a newly created one and returns it to the pool shut down.
    /// Delete and create, rather than `simctl erase`, so the UDID changes and a stale agent cannot reach the new device.
    private func recycle(_ device: PoolDevice, as newName: String) throws {
        let catalog = try Catalog(backend: backend)
        guard let type = catalog.deviceType(identifier: device.deviceTypeIdentifier),
            let runtime = catalog.runtime(identifier: device.runtimeIdentifier), runtime.isAvailable
        else {
            // The runtime was uninstalled; the device cannot be rebuilt, so retire it.
            try destroy(device, currentName: newName, reason: .runtimeRemoved)
            return
        }
        if let udid = device.udid {
            try? backend.shutdown(udid: udid)
            try deleteIfPresent(udid: udid)
        }
        let udid = try backend.create(name: newName, deviceType: type.identifier, runtime: runtime.identifier)
        try store.transaction { state in
            guard let index = state.index(of: newName) else { return }
            let now = now()
            state.devices[index].udid = udid
            state.devices[index].lease = nil
            state.devices[index].transition(to: .available, at: now)
            state.devices[index].lastActivityAt = now
        }
    }

    /// Shuts down and deletes the simulator and retires its record.
    private func destroy(_ device: PoolDevice, currentName: String? = nil, reason: EndReason) throws {
        if let udid = device.udid {
            try? backend.shutdown(udid: udid)
            try deleteIfPresent(udid: udid)
        }
        try store.transaction { state in state.retire(named: currentName ?? device.name, reason: reason, at: now()) }
    }

    private func deleteIfPresent(udid: String) throws {
        guard try liveDevices()[udid] != nil else { return }
        try backend.delete(udid: udid)
    }

    private func liveDevices() throws -> [String: SimDevice] {
        Dictionary(try backend.devices().map { ($0.udid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Also avoids retired names, so `history <name>` stays unambiguous.
    private func freshName(state: PoolState, live: [String: SimDevice], alsoAvoiding extra: [String] = []) -> String {
        let taken = Set(state.devices.map(\.name) + state.retired.map(\.name) + extra).union(live.values.map { $0.name.lowercased() })
        return NameGenerator.generate(avoiding: taken)
    }

    private func info(for name: String, catalog: Catalog? = nil) throws -> DeviceInfo {
        let (catalog, live) = try concurrently({ try catalog ?? Catalog(backend: backend) }, { try liveDevices() })
        let state = try store.snapshot()
        guard let index = state.index(of: name) else { throw SimctlHouseError.deviceNotFound(name) }
        return describe(state.devices[index], live: live, catalog: catalog)
    }

    private func describe(_ device: PoolDevice, live: [String: SimDevice], catalog: Catalog) -> DeviceInfo {
        DeviceInfo(
            name: device.name,
            udid: device.udid,
            status: device.status,
            state: device.udid.flatMap { live[$0]?.state } ?? "Missing",
            model: modelName(device.deviceTypeIdentifier, catalog: catalog),
            os: osVersion(device.runtimeIdentifier, catalog: catalog),
            holder: device.lease?.holder,
            leaseId: device.lease?.id,
            acquiredAt: device.lease?.acquiredAt,
            expiresAt: device.lease?.expiresAt,
            lastActivityAt: device.lastActivityAt
        )
    }

    private func modelName(_ identifier: String, catalog: Catalog) -> String {
        catalog.deviceType(identifier: identifier)?.name ?? identifier
    }

    private func osVersion(_ identifier: String, catalog: Catalog) -> String {
        catalog.runtime(identifier: identifier)?.version ?? identifier
    }
}

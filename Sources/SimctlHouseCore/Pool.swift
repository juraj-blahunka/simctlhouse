import Foundation

public struct PoolConfig: Sendable {
    public static let leaseVariable = "SIMCTLHOUSE_LEASE_SECONDS"
    public static let idleVariable = "SIMCTLHOUSE_IDLE_SECONDS"

    /// A lease not released or renewed within this window is forcefully reclaimed.
    public var leaseDuration: TimeInterval = 30 * 60
    /// Free booted devices are shut down after this much inactivity; 0 shuts them down on the next command.
    /// The `gc` command shuts them down regardless.
    public var idleShutdown: TimeInterval = 15 * 60
    /// A `provisioning` / `maintenance` step is repaired as soon as the process running it is gone.
    /// One still running after this long is presumed hung and repaired too; its claim keeps it from acting afterwards.
    public var hungOperation: TimeInterval = 60 * 60
    /// `delete` and `erase` wait this long for a device that is `provisioning` or `maintenance`, such as one the daemon is shutting down.
    public var busyWait: TimeInterval = 30

    public init() {}

    /// Reads the timeouts from the environment. A malformed value is an error rather than silently ignored,
    /// so a typo cannot quietly leave an agent with a lease of the wrong length.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> PoolConfig {
        var config = PoolConfig()
        if let value = try seconds(environment, leaseVariable, allowZero: false) { config.leaseDuration = value }
        if let value = try seconds(environment, idleVariable, allowZero: true) { config.idleShutdown = value }
        return config
    }

    private static func seconds(_ environment: [String: String], _ variable: String, allowZero: Bool) throws -> TimeInterval? {
        guard let raw = environment[variable], !raw.isEmpty else { return nil }
        guard let value = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, allowZero ? value >= 0 : value > 0 else {
            throw SimctlHouseError.invalidEnvironment(variable: variable, value: raw, expected: allowZero ? "seconds, 0 or more" : "seconds, more than 0")
        }
        return value
    }
}

public struct AcquireRequest: Sendable {
    public var spec: DeviceSpec
    /// A specific pool device (name or UDID) to lease instead of any device matching `spec`.
    public var device: String?
    public var holder: String?
    public var pid: Int32?
    public var cwd: String?
    /// Binds the lease to this running process (`simctlhouse run`): it does not expire while the process runs,
    /// and the device is reclaimed once the process is gone.
    public var owner: Int32?

    public init(
        spec: DeviceSpec = DeviceSpec(), device: String? = nil, holder: String? = nil, pid: Int32? = nil, cwd: String? = nil, owner: Int32? = nil
    ) {
        self.spec = spec
        self.device = device
        self.holder = holder
        self.pid = pid
        self.cwd = cwd
        self.owner = owner
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
    /// When idle shutdown is due for a free, booted device; nil otherwise.
    /// An estimate that only moves later: use outside the pool, such as a run from Xcode, postpones it.
    public var shutdownAt: Date? = nil
    /// The process the lease is bound to (`simctlhouse run`); the lease lasts until it exits, whatever `expiresAt` says.
    public var ownerPid: Int32? = nil
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

    func matches(_ ref: String) -> Bool {
        let needle = ref.lowercased()
        return name == needle || udid?.lowercased() == needle
    }
}

/// A free device that `delete --unused` deleted, or would delete.
public struct UnusedDevice: Codable, Equatable, Sendable {
    public var name: String
    public var udid: String?
    public var lastUsedAt: Date
    /// Disk space its simulator took, measured right before deleting it; nil if it could not be measured.
    public var bytes: Int64?
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
    /// The process that holds the claims this pool takes.
    let processID: Int32
    let now: @Sendable () -> Date
    let log: @Sendable (String) -> Void
    let sleep: @Sendable (TimeInterval) -> Void

    public init(
        paths: HousePaths,
        backend: SimulatorBackend = Simctl(),
        scanner: ProcessScanner = PSProcessScanner(),
        config: PoolConfig = PoolConfig(),
        processID: Int32 = getpid(),
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { _ in },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.store = StateStore(paths: paths, log: log)
        self.backend = backend
        self.scanner = scanner
        self.config = config
        self.processID = processID
        self.now = now
        self.log = log
        self.sleep = sleep
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
            case provision(name: String, ResolvedSpec, Claim)
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
                expiresAt: now.addingTimeInterval(config.leaseDuration),
                owner: request.owner.map { ProcessRef(pid: $0, processStartedAt: scanner.startTime(of: $0)) }
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
                // Unlisted but on disk (D23): a boot would likely fail and delete it.
                if let udid = device.udid, live[udid] == nil { throw SimctlHouseError.deviceMissing(device: device.name) }
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
                let claim = newClaim()
                state.devices.append(
                    PoolDevice(
                        name: name,
                        udid: nil,
                        deviceTypeIdentifier: resolved.deviceType.identifier,
                        runtimeIdentifier: resolved.runtime.identifier,
                        status: .provisioning,
                        lease: lease,
                        claim: claim,
                        now: now
                    )
                )
                return .provision(name: name, resolved, claim)
            }
        }

        let device: PoolDevice
        var isBooted = false
        switch plan {
        case .reuse(let reused, let booted):
            device = reused
            isBooted = booted
        case .provision(let name, let resolved, let claim):
            log("No free \(resolved.deviceType.name) (iOS \(resolved.runtime.version)) in the pool; creating \(name). Its first boot takes about 30s.")
            device = try provision(name: name, resolved: resolved, claim: claim, finalStatus: .leased)
        }

        do {
            if !isBooted { log("Booting \(device.name)...") }
            // Also called for booted devices: bootstatus returns immediately once boot has fully completed.
            try backend.bootAndWait(udid: device.udid!)
        } catch {
            // A device that cannot boot is useless to the next agent too; drop it instead of returning it to the pool.
            log("Boot of \(device.name) failed; removing it from the pool.")
            try? dropAfterFailedBoot(leaseId: device.lease!.id)
            throw error
        }
        return try info(for: startLease(device), catalog: catalog)
    }

    /// Restarts the lease's clock now that the device is ready, so create and boot time do not count against it.
    /// A boot that outlasted the whole lease finds the device reclaimed, and fails the way a stale agent does.
    private func startLease(_ device: PoolDevice) throws -> String {
        try store.transaction { state in
            guard let index = state.devices.firstIndex(where: { $0.lease?.id == device.lease!.id }), state.devices[index].status == .leased else {
                throw SimctlHouseError.deviceNotFound(device.name)
            }
            let now = now()
            state.devices[index].lease!.expiresAt = now.addingTimeInterval(config.leaseDuration)
            state.devices[index].lastActivityAt = now
            return state.devices[index].name
        }
    }

    /// Deletes a device whose boot failed, provided our lease still holds it: during a long boot the lease may have
    /// expired and the device moved on, or been deleted with `--force`.
    private func dropAfterFailedBoot(leaseId: String) throws {
        let claim = newClaim()
        let device = try store.transaction { state -> PoolDevice? in
            guard let index = state.devices.firstIndex(where: { $0.lease?.id == leaseId }), state.devices[index].status == .leased else { return nil }
            let now = now()
            state.devices[index].endLease(.failed, at: now)
            state.devices[index].begin(.maintenance, claim: claim, at: now)
            return state.devices[index]
        }
        if let device { try destroy(device, claim: claim, reason: .failed) }
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

    /// Ends the lease `leaseId` the way `release` does, for `simctlhouse run` once its command has exited.
    /// One short transaction without GC or `simctl` calls, so it finishes before an impatient caller follows its
    /// SIGTERM with a SIGKILL; the daemon collects garbage anyway. Returns the device's name, or nil if no device
    /// carries the lease any more (released or deleted by someone else).
    @discardableResult
    public func releaseLease(_ leaseId: String) throws -> String? {
        try store.transaction { state -> String? in
            guard let index = state.devices.firstIndex(where: { $0.lease?.id == leaseId }) else { return nil }
            // A forced erase or delete in progress ends the lease itself once its work is done.
            guard state.devices[index].status == .leased else { return state.devices[index].name }
            let now = now()
            state.devices[index].endLease(.released, at: now)
            state.devices[index].transition(to: .available, at: now)
            state.devices[index].lastActivityAt = now
            return state.devices[index].name
        }
    }

    /// The leases among `leaseIds` that some device still carries. Reads the state without collecting garbage,
    /// so `run` can watch its leases cheaply on every state change.
    public func heldLeases(_ leaseIds: [String]) throws -> Set<String> {
        let carried = Set(try store.snapshot().devices.compactMap(\.lease?.id))
        return Set(leaseIds.filter(carried.contains))
    }

    // MARK: - create / delete / erase / list / history

    /// Adds a new, shut down device to the pool without leasing it.
    public func create(_ spec: DeviceSpec) throws -> DeviceInfo {
        let catalog = try collectGarbageAndLoadCatalog()
        let resolved = try catalog.resolve(spec)
        let claim = newClaim()
        let name = try store.transaction { state -> String in
            let name = freshName(state: state, live: try liveDevices())
            state.devices.append(
                PoolDevice(
                    name: name,
                    udid: nil,
                    deviceTypeIdentifier: resolved.deviceType.identifier,
                    runtimeIdentifier: resolved.runtime.identifier,
                    status: .provisioning,
                    claim: claim,
                    now: now()
                )
            )
            return name
        }
        let device = try provision(name: name, resolved: resolved, claim: claim, finalStatus: .available)
        return try info(for: device.name, catalog: catalog)
    }

    /// Shuts down and deletes pool devices. Leased devices require `force`.
    public func delete(_ refs: [String], force: Bool) throws -> [String] {
        try collectGarbage()
        return try delete(force: force) { state in
            try refs.map { ref in
                guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
                return index
            }
        }
    }

    public func deleteAll(force: Bool) throws -> [String] {
        try collectGarbage()
        return try delete(force: force) { state in Array(state.devices.indices) }
    }

    /// Deletes free devices that nobody acquired, released or renewed for `age`, to get their disk space back (D32).
    /// Leased and busy devices, and free ones another process uses, are skipped. `deleted` hears of each device as it goes;
    /// with `dryRun` it hears of each one that would go, and nothing is touched.
    @discardableResult
    public func deleteUnused(age: TimeInterval, dryRun: Bool = false, deleted: (UnusedDevice) -> Void = { _ in }) throws -> [UnusedDevice] {
        try collectGarbage()
        let describe = { (device: PoolDevice) in
            UnusedDevice(name: device.name, udid: device.udid, lastUsedAt: device.lastActivityAt, bytes: device.udid.flatMap(backend.diskUsage))
        }
        if dryRun {
            let state = try store.snapshot()
            let devices = unusedIndices(in: state, age: age).map { describe(state.devices[$0]) }
            devices.forEach(deleted)
            return devices
        }
        var measured: UnusedDevice?
        var devices: [UnusedDevice] = []
        _ = try delete(
            force: false, select: { state in unusedIndices(in: state, age: age) },
            // Measured once claimed, so outside the state lock, and before the simulator is gone.
            prepare: { device in measured = describe(device) },
            done: { _ in
                guard let device = measured else { return }
                devices.append(device)
                deleted(device)
            }, logs: false)
        return devices
    }

    private func unusedIndices(in state: PoolState, age: TimeInterval) -> [Int] {
        let now = now()
        let old = state.devices.indices.filter { index in
            let device = state.devices[index]
            return device.status == .available && now.timeIntervalSince(device.lastActivityAt) >= age
        }
        let foreign = scanner.udidsInUse(among: old.compactMap { state.devices[$0].udid })
        return old.filter { state.devices[$0].udid.map { !foreign.contains($0.uppercased()) } ?? true }
    }

    /// `select` picks the devices inside the transaction that claims them, so what is deleted is what was selected.
    /// Every device is attempted; a failure hands that device back as it was, lease included, and is rethrown at the end.
    /// `prepare` runs for each claimed device right before it is deleted, and `done` once it is gone;
    /// a caller that reports deletions itself passes `logs: false`.
    private func delete(
        force: Bool, select: (PoolState) throws -> [Int], prepare: (PoolDevice) -> Void = { _ in }, done: (PoolDevice) -> Void = { _ in },
        logs: Bool = true
    ) throws -> [String] {
        let targets = try claimForDeletion(force: force, select: select)
        var firstError: Error?
        for (device, claim) in targets {
            do {
                prepare(device)
                try destroy(device, claim: claim, reason: .deleted)
                if logs { log("Deleted \(device.name).") }
                done(device)
            } catch {
                // If the simulator is gone after all, the next GC retires it as vanished.
                log("Deleting \(device.name) failed; handing it back.")
                _ = try? finish(claim) { state, index in state.devices[index].restore(at: now()) }
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return targets.map(\.device.name)
    }

    /// Claims the selected devices for deletion, waiting for any that is busy (D36).
    private func claimForDeletion(force: Bool, select: (PoolState) throws -> [Int]) throws -> [(device: PoolDevice, claim: Claim)] {
        try waitingWhileBusy {
            try store.transaction { state -> [(device: PoolDevice, claim: Claim)] in
                var seen: Set<Int> = []
                let indices = try select(state).filter { seen.insert($0).inserted }
                for index in indices { try ensureMutable(state.devices[index], force: force) }
                let now = now()
                return indices.map { index in
                    // The lease ends only once the device is gone, when `destroy` retires it.
                    let claim = newClaim()
                    state.devices[index].begin(.maintenance, claim: claim, at: now)
                    return (state.devices[index], claim)
                }
            }
        }
    }

    /// Runs `claim` again while it fails because a device is `provisioning` or `maintenance`, for up to `config.busyWait`.
    /// Such a device is mid-operation, most often the daemon shutting down one that was just released, so `delete` or
    /// `erase` right after a release waits for it instead of failing (D36). `claim` must take the state lock itself,
    /// so the lock is never held while waiting; garbage collection between attempts repairs a claim whose process died.
    private func waitingWhileBusy<T>(_ claim: () throws -> T) throws -> T {
        let deadline = now().addingTimeInterval(config.busyWait)
        var warned = false
        while true {
            do {
                return try claim()
            } catch SimctlHouseError.deviceBusy(let device, let status) where now() < deadline {
                if !warned {
                    log("\(device) is busy (\(status.rawValue)); waiting up to \(Int(config.busyWait))s for it to finish.")
                    warned = true
                }
                sleep(0.25)
                try collectGarbage()
            }
        }
    }

    /// Wipes a device back to a pristine, shut down state with `simctl erase`. Keeps the name and the UDID.
    public func erase(_ ref: String, force: Bool) throws -> DeviceInfo {
        try collectGarbage()
        let claim = newClaim()
        let device = try waitingWhileBusy {
            try store.transaction { state -> PoolDevice in
                guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
                try ensureMutable(state.devices[index], force: force)
                // A forced erase ends the lease only once the wipe is done.
                state.devices[index].begin(.maintenance, claim: claim, at: now())
                return state.devices[index]
            }
        }
        do {
            try backend.shutdown(udid: device.udid!)
            try backend.erase(udid: device.udid!)
        } catch {
            // Handed back as it was; if the simulator is gone, the next GC retires it as vanished.
            _ = try? finish(claim) { state, index in state.devices[index].restore(at: now()) }
            throw error
        }
        let finished: Void? = try finish(claim) { state, index in
            let now = now()
            state.devices[index].endLease(.erased, at: now)
            state.devices[index].transition(to: .available, at: now)
            state.devices[index].lastActivityAt = now
        }
        guard finished != nil else { throw SimctlHouseError.takenOver(device: device.name) }
        return try info(for: device.name)
    }

    /// The current UDID of a pool device. Needs no device type or runtime listing, so it is cheaper than `list`.
    public func udid(of ref: String) throws -> String {
        try collectGarbage()
        let state = try store.snapshot()
        guard let index = state.index(of: ref) else { throw SimctlHouseError.deviceNotFound(ref) }
        let device = state.devices[index]
        // A device being created has no UDID yet.
        guard let udid = device.udid else { throw SimctlHouseError.deviceBusy(device: device.name, status: device.status) }
        return udid
    }

    /// Devices matching `filter`, in pool order. Like `simctl list`, no match is an empty list, not an error.
    public func list(_ filter: DeviceFilter = DeviceFilter([])) throws -> [DeviceInfo] {
        let (gc, catalog) = try concurrently({ try runGarbageCollection() }, { try Catalog(backend: backend) })
        let live = try gc.untouchedLive ?? liveDevices()
        return try store.snapshot().devices.map { describe($0, live: live, catalog: catalog) }.filter(filter.matches)
    }

    /// Lease history of every device, including ones that left the pool, or of the one device matching `ref`.
    /// `ref` may also be a name or UDID the device no longer has (after expiry or `delete`).
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
            case reclaim(PoolDevice, newName: String, Claim, EndReason)
            case shutdown(PoolDevice, Claim)
            case discard(PoolDevice, udids: [String], Claim)
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
                switch device.status {
                case .provisioning:
                    guard isAbandoned(device, now: now) else { break }
                    // The creating process died midway. Delete what it left: the expired simulator a reclaim had yet
                    // to delete, and any half-made simulator carrying our name. The record stays until they are gone,
                    // so a failed delete is retried rather than leaving a simulator nothing tracks.
                    report.forgotten.append(device.name)
                    var leftovers = live.values.filter { $0.udid == device.replacedUDID || $0.name == device.name }.map(\.udid)
                    if let replaced = device.replacedUDID, !leftovers.contains(replaced), backend.existsOnDisk(udid: replaced) {
                        leftovers.append(replaced)
                    }
                    guard leftovers.isEmpty else {
                        let claim = newClaim()
                        device.begin(.provisioning, claim: claim, at: now)
                        jobs.append(.discard(device, udids: leftovers, claim))
                        keep.append(device)
                        continue
                    }
                    state.retire(device, reason: .abandoned, at: now)
                    continue
                case .maintenance:
                    guard isAbandoned(device, now: now) else { break }
                    if let udid = device.udid, !isGone(udid, live: live) {
                        device.restore(at: now)
                        report.recovered.append(device.name)
                    } else {
                        state.retire(device, reason: .vanished, at: now)
                        report.forgotten.append(device.name)
                        continue
                    }
                case .available, .leased:
                    guard let udid = device.udid, !isGone(udid, live: live) else {
                        // Deleted behind our back (Xcode, `simctl delete`, ...). Nothing left to manage.
                        state.retire(device, reason: .vanished, at: now)
                        report.forgotten.append(device.name)
                        continue
                    }
                    guard live[udid] != nil else {
                        // Left out of an incomplete listing; act on it once simctl lists it again.
                        log("\(device.name) is missing from simctl's device list but still on disk; keeping it.")
                        keep.append(device)
                        continue
                    }
                }

                if device.status == .leased, let lease = device.lease, let owner = lease.owner, isAlive(owner) {
                    // Bound to a running `simctlhouse run`: the lease lasts as long as that process. Keep its expiry
                    // ahead, so readers that only know `expiresAt` (older JSON consumers, `nextWake`) see a live lease.
                    if lease.expiresAt <= now { device.lease?.expiresAt = now.addingTimeInterval(config.leaseDuration) }
                } else if device.status == .leased, let lease = device.lease, lease.owner != nil || lease.expiresAt <= now {
                    // Expired, or its `run` process is gone without releasing it: then its command may still be running
                    // as an orphan, so the device is reclaimed like an expired one rather than released.
                    // Rename right away so a stale agent can no longer address the device by its old name.
                    // The old identity and its lease history move to `retired`; the re-created device starts fresh.
                    // Until then the record is `provisioning` and the old UDID sits in `replacedUDID`,
                    // so neither the old name nor the old UDID reaches it, and it is never handed out.
                    let reason: EndReason = lease.owner == nil ? .expired : .abandoned
                    let newName = freshName(state: state, live: live, alsoAvoiding: keep.map(\.name))
                    state.retire(device, reason: reason, at: now)
                    device.lease = nil
                    device.history = []
                    device.createdAt = now
                    device.replacedUDID = device.udid
                    device.udid = nil
                    let claim = newClaim()
                    device.begin(.provisioning, claim: claim, at: now)
                    jobs.append(.reclaim(device, newName: newName, claim, reason))
                    report.reclaimed.append(device.name)
                    device.name = newName
                } else if device.status == .available, let udid = device.udid, live[udid]?.isBooted == true {
                    if foreign.contains(udid.uppercased()) {
                        device.lastActivityAt = now
                    } else if shutDownAllFree || now.timeIntervalSince(device.lastActivityAt) >= config.idleShutdown {
                        let claim = newClaim()
                        device.begin(.maintenance, claim: claim, at: now)
                        jobs.append(.shutdown(device, claim))
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
            case .reclaim(let device, let newName, let claim, let reason):
                if reason == .abandoned {
                    log("The process holding \(device.name) exited without releasing it; re-creating it and returning it to the pool as \(newName).")
                } else {
                    log("Lease on \(device.name) expired; re-creating it and returning it to the pool as \(newName).")
                }
                do {
                    try recycle(device, as: newName, claim: claim)
                } catch {
                    log("Reclaiming \(newName) failed: \(error).")
                }
            case .shutdown(let device, let claim):
                log(shutDownAllFree ? "Shutting down \(device.name), which is free." : "\(device.name) has been idle; shutting it down.")
                do {
                    try backend.shutdown(udid: device.udid!)
                } catch {
                    log("Shutting down \(device.name) failed: \(error). It will be retried later.")
                }
                // Free again either way; a failed shutdown leaves it booted and idle, so the next GC retries.
                _ = try? finish(claim) { state, index in state.devices[index].transition(to: .available, at: now()) }
            case .discard(let device, let udids, let claim):
                do {
                    for udid in udids { try backend.delete(udid: udid) }
                    _ = try finish(claim) { state, index in state.retire(at: index, reason: .abandoned, at: now()) }
                } catch {
                    log("Deleting what was left of \(device.name) failed: \(error). It will be retried later.")
                }
            }
        }
        return (report, jobs.isEmpty ? live : nil)
    }

    /// Whether a daemon would have anything to watch, decided as the daemon does on its first wake:
    /// collect garbage, then look for a deadline. `daemon start --keep-alive 0` asks first, so it never starts a daemon that would exit at once.
    public func hasWorkForDaemon() throws -> Bool {
        let started = now()
        try collectGarbage()
        return nextWake(in: try store.snapshot(), collectedAt: started) != nil
    }

    /// When GC next has something to do on its own, or nil if nothing can come due until another command adds work.
    /// Reads only `state`, so the daemon can decide to exit under the same lock that a command adding work takes.
    /// A free device may be booted, so it counts until a collection that started at `collectedAt` or later
    /// has run after its idle time was up: that collection shut it down, with the same stored `lastActivityAt`.
    func nextWake(in state: PoolState, collectedAt: Date) -> Date? {
        state.devices.compactMap { device -> Date? in
            switch device.status {
            case .leased:
                return device.lease?.expiresAt
            case .provisioning, .maintenance:
                // The daemon's poll interval notices a claim whose process exited well before this backstop.
                return device.statusChangedAt.addingTimeInterval(config.hungOperation)
            case .available:
                // `state.json` keeps whole seconds, so a device released just after a collection started can carry
                // a `lastActivityAt` up to a second before it; the slack keeps such a device counted.
                let idleEnds = device.lastActivityAt.addingTimeInterval(config.idleShutdown)
                return idleEnds > collectedAt.addingTimeInterval(-1) ? idleEnds : nil
            }
        }.min()
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

    /// A claim held by this process, for a record about to enter `provisioning` or `maintenance`.
    private func newClaim() -> Claim {
        Claim(id: UUID().uuidString.lowercased(), pid: processID, processStartedAt: scanner.startTime(of: processID))
    }

    /// Runs `body` under the lock on the record `claim` was taken on. Returns nil without running it when no record
    /// carries the claim any more: GC judged the work abandoned and repaired the record, so it is no longer ours to change.
    private func finish<T>(_ claim: Claim, _ body: (inout PoolState, Int) throws -> T) throws -> T? {
        try store.transaction { state in
            guard let index = state.devices.firstIndex(where: { $0.claim?.id == claim.id }) else { return nil }
            return try body(&state, index)
        }
    }

    /// A `provisioning` or `maintenance` record is abandoned once the process holding its claim is gone,
    /// or, for a hung process, once the work has run longer than `config.hungOperation`.
    /// A record without a claim was written by an older simctlhouse that may still be at work, so only the timeout applies.
    private func isAbandoned(_ device: PoolDevice, now: Date) -> Bool {
        if now.timeIntervalSince(device.statusChangedAt) > config.hungOperation { return true }
        guard let claim = device.claim else { return false }
        return !isAlive(ProcessRef(pid: claim.pid, processStartedAt: claim.processStartedAt))
    }

    /// Whether `process` still runs: its pid exists and, when its start time is known, started then (not a recycled pid).
    private func isAlive(_ process: ProcessRef) -> Bool {
        guard let started = scanner.startTime(of: process.pid) else { return false }
        return process.processStartedAt.map { $0 == started } ?? true
    }

    /// Creates the simulator for a `provisioning` record and moves it to `finalStatus`.
    private func provision(name: String, resolved: ResolvedSpec, claim: Claim, finalStatus: PoolDevice.Status) throws -> PoolDevice {
        let udid: String
        do {
            udid = try backend.create(name: name, deviceType: resolved.deviceType.identifier, runtime: resolved.runtime.identifier)
        } catch {
            _ = try? finish(claim) { state, index in state.retire(at: index, reason: .failed, at: now()) }
            throw error
        }
        return try adopt(udid: udid, claim: claim, name: name) { device in
            let now = now()
            device.transition(to: finalStatus, at: now)
            device.lastActivityAt = now
        }
    }

    /// Replaces a reclaimed device with a newly created one and returns it to the pool shut down.
    /// Delete and create, rather than `simctl erase`, so the UDID changes and a stale agent cannot reach the device.
    /// If deleting the old simulator fails, the record stays `provisioning`, and GC deletes it once this process is gone.
    private func recycle(_ device: PoolDevice, as newName: String, claim: Claim) throws {
        if let udid = device.replacedUDID {
            try? backend.shutdown(udid: udid)
            try deleteIfPresent(udid: udid)
        }
        let udid: String
        do {
            let catalog = try Catalog(backend: backend)
            guard let type = catalog.deviceType(identifier: device.deviceTypeIdentifier),
                let runtime = catalog.runtime(identifier: device.runtimeIdentifier), runtime.isAvailable
            else {
                // The runtime was uninstalled; the device cannot be rebuilt, so retire it.
                _ = try finish(claim) { state, index in state.retire(at: index, reason: .runtimeRemoved, at: now()) }
                return
            }
            udid = try backend.create(name: newName, deviceType: type.identifier, runtime: runtime.identifier)
        } catch {
            _ = try? finish(claim) { state, index in state.retire(at: index, reason: .failed, at: now()) }
            throw error
        }
        _ = try adopt(udid: udid, claim: claim, name: newName) { device in
            let now = now()
            device.transition(to: .available, at: now)
            device.lastActivityAt = now
        }
    }

    /// Records a simulator just created for the record `claim` is on, then applies `body` to the record.
    /// If the record is no longer ours, or recording fails, nothing in the pool refers to the simulator,
    /// and nothing would ever delete it, so it is deleted here.
    private func adopt(udid: String, claim: Claim, name: String, _ body: (inout PoolDevice) -> Void) throws -> PoolDevice {
        let adopted: PoolDevice?
        do {
            adopted = try finish(claim) { state, index in
                state.devices[index].udid = udid
                state.devices[index].replacedUDID = nil
                body(&state.devices[index])
                return state.devices[index]
            }
        } catch {
            try? backend.delete(udid: udid)
            throw error
        }
        guard let adopted else {
            try? backend.delete(udid: udid)
            throw SimctlHouseError.takenOver(device: name)
        }
        return adopted
    }

    /// Shuts down and deletes the simulator of a device this process claimed, then retires its record.
    private func destroy(_ device: PoolDevice, claim: Claim, reason: EndReason) throws {
        if let udid = device.udid {
            try? backend.shutdown(udid: udid)
            try deleteIfPresent(udid: udid)
        }
        _ = try finish(claim) { state, index in state.retire(at: index, reason: reason, at: now()) }
    }

    /// Also deletes a simulator that an incomplete listing left out, so that none is left behind untracked.
    private func deleteIfPresent(udid: String) throws {
        guard try liveDevices()[udid] != nil || backend.existsOnDisk(udid: udid) else { return }
        try backend.delete(udid: udid)
    }

    /// Whether a simulator is really gone: missing from the listing and from disk.
    /// A single `simctl list` can leave out devices that exist, so the listing alone never retires a device (D23).
    private func isGone(_ udid: String, live: [String: SimDevice]) -> Bool {
        live[udid] == nil && !backend.existsOnDisk(udid: udid)
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
        let simulator = device.udid.flatMap { live[$0] }
        let idle = device.status == .available && simulator?.isBooted == true
        return DeviceInfo(
            name: device.name,
            udid: device.udid,
            status: device.status,
            state: simulator?.state ?? "Missing",
            model: modelName(device.deviceTypeIdentifier, catalog: catalog),
            os: osVersion(device.runtimeIdentifier, catalog: catalog),
            holder: device.lease?.holder,
            leaseId: device.lease?.id,
            acquiredAt: device.lease?.acquiredAt,
            expiresAt: device.lease?.expiresAt,
            lastActivityAt: device.lastActivityAt,
            shutdownAt: idle ? device.lastActivityAt.addingTimeInterval(config.idleShutdown) : nil,
            ownerPid: device.status == .leased ? device.lease?.owner?.pid : nil
        )
    }

    private func modelName(_ identifier: String, catalog: Catalog) -> String {
        catalog.deviceType(identifier: identifier)?.name ?? identifier
    }

    private func osVersion(_ identifier: String, catalog: Catalog) -> String {
        catalog.runtime(identifier: identifier)?.version ?? identifier
    }
}

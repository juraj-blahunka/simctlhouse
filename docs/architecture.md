# Architecture

simctlhouse is a single Swift executable that wraps `xcrun simctl`.
There is no daemon: every invocation reads the shared state under a file lock, does its work, and exits.

## Layout

```
Sources/
  simctlhouse/            CLI (swift-argument-parser): parsing, output formatting, exit codes
  SimctlHouseCore/
    Pool.swift            acquire / release / renew / create / delete / reset / list / history / gc
    StateStore.swift      ~/.simctlhouse paths, flock, atomic JSON persistence
    Models.swift          PoolState, PoolDevice, Lease, LeaseRecord, RetiredDevice, DeviceSpec
    Catalog.swift         DeviceSpec -> concrete device type + runtime (defaults live here)
    Simctl.swift          SimulatorBackend protocol and the real `xcrun simctl` implementation
    ProcessScanner.swift  best-effort detection of foreign processes using a device
    Names.swift           adjective-noun name generator
    Errors.swift          SimctlHouseError and exit codes
Tests/SimctlHouseCoreTests  unit tests against an in-memory FakeBackend and a controllable clock
```

## On-disk state

```
~/.simctlhouse/             (override with SIMCTLHOUSE_HOME)
  state.json                the registry: every device simctlhouse owns
  state.lock                flock target guarding state.json
```

`state.json` example:

```json
{
  "version": 1,
  "devices": [
    {
      "name": "amber-falcon",
      "udid": "E1B5E4F7-1356-4DBA-9D3C-CC2F5807D95B",
      "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
      "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      "status": "leased",
      "lease": {
        "id": "4f0c...",
        "holder": "agent-42",
        "pid": 81234,
        "cwd": "/Users/me/src/app",
        "acquiredAt": "2026-10-26T18:00:00Z",
        "expiresAt": "2026-10-26T18:30:00Z"
      },
      "createdAt": "2026-10-26T17:00:00Z",
      "statusChangedAt": "2026-10-26T18:00:00Z",
      "lastActivityAt": "2026-10-26T18:00:00Z",
      "history": [
        {
          "leaseId": "9a1e...",
          "holder": "agent-41",
          "pid": 80011,
          "cwd": "/Users/me/src/app",
          "udid": "E1B5E4F7-1356-4DBA-9D3C-CC2F5807D95B",
          "acquiredAt": "2026-10-26T17:10:00Z",
          "endedAt": "2026-10-26T17:42:00Z",
          "outcome": "released"
        }
      ]
    }
  ],
  "retired": [
    {
      "name": "civic-zephyr",
      "udid": "A4156E1B-...",
      "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max",
      "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      "createdAt": "2026-10-26T16:53:00Z",
      "retiredAt": "2026-10-26T16:55:26Z",
      "reason": "vanished",
      "history": [{ "holder": "agent-40", "outcome": "vanished", "...": "..." }]
    }
  ]
}
```

## Device lifecycle

```
             acquire (no free match)
   (none) ───────────────────────────► provisioning ─create done──► leased
                                                                     │  ▲
                                                        release      │  │ acquire (free match)
                                                                     ▼  │
             create ─► provisioning ─create done──────────────────► available
                                                                     │  ▲
                              idle 15 min (booted) / lease expired   │  │ shutdown or re-create done
                              / reset / delete                       ▼  │
                                                                  maintenance ──delete──► (gone)
```

| Status | Meaning | Acquirable |
| --- | --- | --- |
| `provisioning` | Name reserved, simulator being created | no |
| `available` | Free; may be booted (recently used) or shut down | yes |
| `leased` | Held by an agent until `lease.expiresAt` | no |
| `maintenance` | simctlhouse is shutting down, re-creating or deleting it | no |

The CoreSimulator state (`Booted` / `Shutdown`) is never stored; it is read live from `simctl list`.

## Concurrency model

All decisions happen inside `StateStore.transaction`, which holds an exclusive `flock` on `state.lock` for the read-modify-write.
The live `simctl list` snapshot is taken inside the transaction too, so a device being created by another process can never be mistaken for one that was deleted.
Slow operations run outside the lock.
Before releasing the lock, the transaction moves the device into `provisioning` or `maintenance`, so no other process will pick it.
After the slow work, a second short transaction moves it to its final status.

If a process crashes mid-operation, the record stays in `provisioning` or `maintenance`.
GC treats such records as abandoned after 10 minutes:

- `provisioning`: the record is dropped and any simulator carrying its name is deleted.
- `maintenance`: if the simulator still exists it becomes `available` again, otherwise the record is dropped.


## Garbage collection

`collectGarbage()` runs at the start of every command:

1. Retires records whose simulator was deleted outside simctlhouse.
2. Repairs abandoned `provisioning` / `maintenance` records (see above).
3. Expired leases: retires the old name with its lease history, marks the record `maintenance` under a new name, then deletes and re-creates the simulator and returns it as `available`, shut down.
4. Free devices that have been booted and inactive for 15 minutes: shuts them down unless a foreign process references them.
   The explicit `gc` command shuts down every free booted device, without waiting.

GC's jobs touch different simulators, so they run in parallel after the transaction.

## Performance

Nearly all of a command's time is spent in `xcrun simctl`, 0.1-0.3s per call on an idle machine.
Independent calls run in parallel (`concurrently` in `Concurrently.swift`): GC's device listing overlaps the device type and runtime listings (`Catalog`).
`list` reuses the device snapshot GC took when GC changed nothing, so on an idle machine it costs about one `simctl` call.

## Audit trail

Leases and devices are never silently dropped.
`PoolDevice.endLease` moves the current lease into the device's `history` (last 5) with an end time and outcome.
`PoolState.retire` moves a device that leaves the pool into `retired` (last 50), with its history.
Every removal path goes through it: `delete`, a failed create or boot, a simulator that vanished, abandoned provisioning, and the old name of an expired lease.
`history` merges both lists and matches a reference against current names and UDIDs, past UDIDs in lease records, and retired devices.

## acquire, step by step

1. GC.
2. Resolve `--device` / `--model` / `--os` to a device type and runtime (`Catalog`).
3. With `acquire <name|udid>`, lease that device if it is free and no foreign process references it, otherwise fail with exit code 3 or 5.
   Otherwise, under the lock, filter `available` devices of that exact type and runtime whose simulator exists.
   Drop those a foreign process references.
   Prefer a booted one, then the most recently used.
   Mark it `leased`.
4. If none matched, reserve a fresh name as `provisioning` (with the lease attached), then outside the lock `simctl create` it in the default set.
5. `simctl bootstatus <udid> -b` boots the device and waits until boot has fully completed.
   If boot fails the device is deleted and not returned to the pool.
6. Print the UDID (or JSON with `--json`).

## Testing seams

`Pool` takes a `SimulatorBackend`, a `ProcessScanner`, a clock and a logger.
Unit tests use `FakeBackend` (an in-memory CoreSimulator) and `TestClock` to cover expiry, idle shutdown, crash recovery and concurrent acquires without real simulators.
`SIMCTLHOUSE_HOME`, `SIMCTLHOUSE_LEASE_SECONDS` and `SIMCTLHOUSE_IDLE_SECONDS` let end-to-end runs use real simulators in an isolated home with short timeouts.

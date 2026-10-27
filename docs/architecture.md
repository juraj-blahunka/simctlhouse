# Architecture

simctlhouse is a single Swift executable that wraps `xcrun simctl`.
There is no daemon: every invocation reads the shared state under a file lock, does its work, and exits.
`Pool` holds all behaviour; the CLI only parses arguments and formats output.

## State

All state lives in `~/.simctlhouse` (override with `SIMCTLHOUSE_HOME`).
`state.json` is the registry of every device simctlhouse owns, and `state.lock` is the `flock` target that guards it.

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
      "history": [
        { "holder": "agent-41", "acquiredAt": "2026-10-26T17:10:00Z", "endedAt": "2026-10-26T17:42:00Z", "outcome": "released", "...": "..." }
      ],
      "createdAt": "2026-10-26T17:00:00Z",
      "statusChangedAt": "2026-10-26T18:00:00Z",
      "lastActivityAt": "2026-10-26T18:00:00Z"
    }
  ],
  "retired": [
    { "name": "civic-zephyr", "retiredAt": "2026-10-26T16:55:26Z", "reason": "vanished", "history": [], "...": "..." }
  ]
}
```

The CoreSimulator state (`Booted` / `Shutdown`) is never stored; it is read live from `simctl list`.

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
| `available` | Free; booted (recently used) or shut down | yes |
| `leased` | Held by an agent until `lease.expiresAt` | no |
| `maintenance` | simctlhouse is shutting down, re-creating or deleting it | no |

## Concurrency

Every decision happens inside `StateStore.transaction`, which holds an exclusive `flock` for the read-modify-write and writes the file atomically.
The live `simctl list` snapshot is taken inside the same transaction, so a device another process is creating is never mistaken for one that was deleted.
Slow work (create, boot, shutdown, delete) runs outside the lock.
Before releasing the lock, the transaction moves the device to `provisioning` or `maintenance`, so no other process picks it, and a second short transaction sets its final status afterwards.

If a process crashes midway, the record stays in `provisioning` or `maintenance`.
GC treats such a record as abandoned after 10 minutes:

- `provisioning`: the record is retired and any simulator carrying its name is deleted.
- `maintenance`: the device becomes `available` again if its simulator still exists, otherwise it is retired.

## Garbage collection

GC runs at the start of every command:

1. Retires records whose simulator was deleted outside simctlhouse.
2. Repairs abandoned `provisioning` and `maintenance` records.
3. Reclaims expired leases: retires the old name with its history, renames the record, deletes and re-creates the simulator, and returns it `available` and shut down.
4. Shuts down free devices that have been booted and inactive for 15 minutes, unless a foreign process references them.
   The explicit `gc` command shuts down every free booted device without waiting.

The shutdowns and reclaims touch different simulators, so they run in parallel after the transaction.

## acquire

1. Run GC.
2. With `acquire <name|udid>`, lease that device if it is free and no foreign process references it; otherwise fail with exit code 3 or 5.
3. Otherwise resolve `--device` / `--model` / `--os` to a device type and runtime (`Catalog`), and under the lock pick an `available` device of exactly that type and runtime whose simulator exists and no foreign process references.
   Prefer a booted one, then the most recently used.
4. If none matched, reserve a fresh name as `provisioning` with the lease attached, then `simctl create` it outside the lock.
5. `simctl bootstatus <udid> -b` boots the device and waits until boot has fully completed.
   If boot fails, the device is deleted rather than returned to the pool.
6. Print the UDID, or JSON with `--json`.

## Audit trail

Leases and devices never disappear without a record.
`PoolDevice.endLease` moves the current lease into the device's `history` (last 5) with an end time and outcome.
`PoolState.retire` moves a device that leaves the pool into `retired` (last 50), with its history.
Every removal goes through it: `delete`, a failed create or boot, a vanished simulator, abandoned provisioning, and the old name of an expired lease.
`history` matches a reference against current names and UDIDs, earlier UDIDs in lease records, and retired devices.

## Performance

Nearly all of a command's time is spent in `xcrun simctl`, 0.1-0.3s per call on an idle machine.
Independent calls run in parallel (`concurrently`): GC's device listing overlaps the device type and runtime listings.
`list` reuses GC's device snapshot when GC changed nothing, so on an idle machine it costs about one `simctl` call.

## Testing seams

`Pool` takes a `SimulatorBackend`, a `ProcessScanner`, a clock and a logger.
Unit tests use `FakeBackend` (an in-memory CoreSimulator) and `TestClock` to cover expiry, idle shutdown, crash recovery and concurrent acquires without real simulators.
`SIMCTLHOUSE_HOME`, `SIMCTLHOUSE_LEASE_SECONDS` and `SIMCTLHOUSE_IDLE_SECONDS` (see D21) let end-to-end runs use real simulators in an isolated home with short timeouts.

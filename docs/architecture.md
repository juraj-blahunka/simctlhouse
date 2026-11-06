# Architecture

simctlhouse is a single Swift executable that wraps `xcrun simctl`.
There is no server: every invocation reads the shared state under a file lock, does its work, and exits.
An on-demand daemon (see Daemon) runs the same housekeeping on time between commands; it shares the state and the lock like any command and talks to no one.
`Pool` holds all behaviour; the CLI only parses arguments and formats output.

## Files

Everything lives in `~/.simctlhouse` (override with `SIMCTLHOUSE_HOME`).

| File | Purpose |
| --- | --- |
| `state.json` | The registry of every device simctlhouse owns (see State) |
| `state.lock` | The `flock` target that guards `state.json` |
| `state.json.tmp` | Where `state.json` is written before it is renamed into place |
| `state.json.corrupt-<time>` | A `state.json` that could not be decoded, moved aside (D30) |
| `daemon.lock` | Held by the running daemon for its whole life; holds its pid, version and binary (see Daemon) |
| `daemon.next.lock` | Held by a daemon of a new build while it waits for the old one to exit |
| `daemon.log`, `daemon.log.1` | The daemon's log, and the previous run's |

## State

`state.json` lists the pool's devices with their leases and lease history, and the devices that left the pool (`retired`).

```json
{
  "version": 2,
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

A device being worked on also carries a `claim` (see Concurrency), and one being re-created after an expired lease a `replacedUDID` (see Garbage collection).
A lease taken by `simctlhouse run` also carries an `owner`: the pid and start time of the `run` process (see run).
The CoreSimulator state (`Booted` / `Shutdown`) is never stored; it is read live from `simctl list`.
Dates are stored in whole seconds.

`state.json` is written to `state.json.tmp`, flushed to the drive with `F_FULLFSYNC`, and renamed into place, so it is never seen half-written or empty, even after a power loss (D5).
A missing `state.json` is an empty pool.
How the others are read:

- **An older or the current `version`** decodes as is and is written back as the current version; fields added since are optional.
- **A newer `version`** fails the command without writing, so an older build never rewrites a newer file and drops what it does not know (D31).
  `PoolState.currentVersion` is bumped with every change to what the file holds.
- **One that cannot be decoded** is moved to `state.json.corrupt-<time>` and replaced by an empty pool with a warning (D30).
- **One that cannot be read** (permissions, I/O) fails the command.

## Device lifecycle

```
             acquire (no free match)
   (none) ───────────────────────────► provisioning ─create done──► leased ──lease expired──► provisioning
                                                                     │  ▲                      (re-create)
                                                        release      │  │ acquire (free match)      │
                                                                     ▼  │                           │
             create ─► provisioning ─create done──────────────────► available ◄──re-create done─────┘
                                                                     │  ▲
                              idle 15 min (booted)                   │  │ shutdown or erase done
                              / erase / delete                       ▼  │
                                                                  maintenance ──delete──► (gone)
```

| Status | Meaning | Acquirable |
| --- | --- | --- |
| `provisioning` | Name reserved, simulator being created, or re-created after an expired lease; carries a claim | no |
| `available` | Free; booted (recently used) or shut down | yes |
| `leased` | Held by an agent until `lease.expiresAt` | no |
| `maintenance` | simctlhouse is shutting down, erasing or deleting it; carries a claim | no |

## acquire

1. Run garbage collection.
2. With `acquire <name|udid>`, lease that device if it is free and no foreign process references it; otherwise fail with exit code 3 or 5.
3. Otherwise resolve `--family` / `--model` / `--os` to a device type and runtime (`Catalog`), and under the lock pick an `available` device of exactly that type and runtime whose simulator exists and no foreign process references.
   Prefer a booted one, then the most recently used.
4. If none matched, reserve a fresh name as `provisioning` with the lease attached, then `simctl create` it outside the lock.
5. `simctl bootstatus <udid> -b` boots the device and waits until boot has fully completed.
   If boot fails, the device is deleted rather than returned to the pool.
6. Restart the lease's clock, found by lease id, so create and boot time do not count against it (D9).
   If the lease is gone (a boot that outlasted it, or a forced `delete`), fail with exit code 3.
7. Print the UDID, or JSON with `--json`.
8. Make sure the daemon runs (see Daemon).

## run

`simctlhouse run` (`Runner`) leases devices, runs one command on them, and releases them when it exits (D33, D34).

1. Check the command: a placeholder for a device the run will not lease (`{udid}` with `--count`, `{udid2}` with `--count 2`), and an xcodebuild `-destination` that no lease could match, are refused before anything is leased (`RunCommand.check`).
2. Acquire `--count` devices at the same time, each as `acquire` does (booting it unless `--skip-boot`), with the lease's `owner` set to this process.
   If one fails, release the others.
3. Make sure the daemon runs.
4. Fill in the devices (`RunCommand`): replace `{udid}`, `{name}`, `{udid<i>}` and `{name<i>}`, add `-destination id=<UDID>` per device to a direct xcodebuild, and refuse a `-destination` naming another simulator.
5. Install the signal handlers, then start the command with `posix_spawnp`: in simctlhouse's process group, with its stdin, stdout and stderr, no other descriptor, and default signal handling.
6. Wait in a loop on one inbox (`RunEvents`) fed by a thread blocked in `waitpid`, the signal handlers (through a pipe, the only thing a handler can safely do), and a watcher on the state directory:
   - A signal is forwarded to the command, unless the terminal sent it to the whole foreground process group (Ctrl-C), which the command then received itself.
     macOS does not report a reliable sender in `siginfo`, so a SIGINT, SIGQUIT or SIGHUP counts as the terminal's while simctlhouse is in the foreground of its controlling terminal.
   - `--timeout`, or a state change after which a device no longer carries its lease, stops the command with SIGTERM.
   - A command still running 15 seconds after it was stopped, or a second signal, gets SIGKILL, together with every process below it, read from the process table before the command dies and its children are re-parented.
7. Release each lease by its id in one transaction, without GC or `simctl` calls (`Pool.releaseLease`), so it finishes before a caller follows its SIGTERM with a SIGKILL; still under the signal handlers, so a signal cannot cut it short.
8. Make sure the daemon runs, restore the default signal handlers, and exit with the command's code, or die of the command's signal unless it is a crash signal.

If `run` is killed before it can release, the lease's `owner` is gone and GC reclaims the device (see Garbage collection).

## Concurrency

Every decision happens inside `StateStore.transaction`, which holds an exclusive `flock` for the read-modify-write and writes the file atomically.
The live `simctl list` snapshot is taken inside the same transaction, so a device another process is creating is never mistaken for one that was deleted.
Slow work (create, boot, shutdown, delete) runs outside the lock.
Before releasing the lock, the transaction moves the device to `provisioning` or `maintenance`, so no other process picks it, and a second short transaction sets its final status afterwards.

The first transaction stamps the record with a claim: a random id plus the pid and start time of the process doing the work (D28).
The second transaction finds the record by that claim id (`Pool.finish`), never by name, and does nothing if no record carries it any more.
So work that outlives its claim can never overwrite what happened to the record in the meantime.
A simulator created for a record that is no longer ours is deleted on the spot, since nothing else would ever touch it.
A forced `erase` or `delete` of a leased device keeps the lease until the work succeeds; if it fails or is repaired, the device goes back to `leased`.

If a process crashes midway, the record stays in `provisioning` or `maintenance`.
GC treats such a record as abandoned as soon as the process named in its claim is gone (or its pid now belongs to a process started at another time), and after an hour even if it is still running, as a backstop for a hung process:

- `provisioning`: any simulator carrying its name, and the expired simulator a reclaim had yet to delete (`replacedUDID`), are deleted, then the record is retired.
  The record stays until those deletes succeed, so a failed one is retried by a later GC instead of leaving a simulator nothing tracks.
- `maintenance`: the device goes back to `leased` (if it still has a lease) or `available` if its simulator still exists, otherwise it is retired.

A slow but live process is never taken over before that hour, so a loaded machine cannot make two processes act on one device.
After the hour, only the record is protected: a hung `simctl erase`, `shutdown` or `delete` that completes after the takeover still acts on the simulator, which may have a new holder by then.
Within one process, GC's parallel jobs each open their own descriptor on `state.lock`; `flock` locks belong to the open file, so the jobs exclude each other like separate processes do.
Transactions never nest, which would deadlock on that same property.

## Garbage collection

GC runs at the start of every command, and in the daemon whenever something comes due:

1. Retires records whose simulator was deleted outside simctlhouse: missing from the listing and from disk (D23).
2. Repairs abandoned `provisioning` and `maintenance` records (see Concurrency).
3. Reclaims expired leases: retires the old name with its history, renames the record and moves it to `provisioning` with the old UDID set aside in `replacedUDID`, deletes and re-creates the simulator, and returns it `available` and shut down.
   Neither the old name nor the old UDID reaches the record from the moment of expiry, and the old simulator is never handed out, even if deleting it fails.
   A lease with an `owner` never expires while that process runs (same pid and start time): GC moves its `expiresAt` forward instead, so readers that only know `expiresAt` still see a live lease.
   Once the owner is gone, the lease is reclaimed the same way with the outcome `abandoned`, rather than released, because the command it ran may still be using the device.
4. Shuts down free devices that have been booted and inactive for 15 minutes, unless a foreign process references them.
   The explicit `gc` command shuts down every free booted device without waiting.

The shutdowns and reclaims touch different simulators, so they run in parallel after the transaction.

## Daemon

### What it does

`simctlhouse daemon serve` (`Daemon.serve`) runs GC whenever something comes due, so an expired lease is reclaimed and an idle device shut down on time even if no other command runs (D29).
In a loop, it:

1. Runs GC if it is due.
2. Reads the next deadline from the state (`Pool.nextWake`): the earliest lease expiry, end of a free device's idle time, or hung backstop of work in progress.
3. Sleeps until then.
   A state change wakes it at once, to re-read the deadlines: it watches the home directory, and every state write renames `state.json` into place.

It collects at least every 60 seconds (`Daemon.pollInterval`), which bounds how late it notices that a crashed process left a claim behind, or that a killed `run` left its lease, and at most once a second.
A free device may be booted, so it counts as a deadline until a collection has run after its idle time was up; that collection shut it down if it was booted.
The comparison allows a second of slack, as `state.json` keeps whole seconds.
The daemon exits once `nextWake` finds nothing, so it runs only while something is leased, booted or in progress.

### Starting and replacing it

There is no port and no socket: commands never talk to the daemon.
The daemon holds an exclusive `flock` on `daemon.lock` for its whole life and writes its `DaemonRecord` (pid, start time, version, binary) into that file.
Whether a daemon runs is whether that lock is held; the kernel drops it when the daemon dies, so there is no stale pid file to second-guess.
Checking the lock (`DaemonLock.isHeld`) takes it for a moment, so a daemon that finds a lock taken keeps trying for half a second (`DaemonLock.checkPatience`) before it concludes another daemon holds it; otherwise a daemon starting inside a command's check would exit although none runs.

`acquire`, `release`, `renew` and `run` call `DaemonLauncher.ensureRunning` after their change has committed, unless `SIMCTLHOUSE_DAEMON=0`:

1. If `daemon.lock` is free, spawn `simctlhouse daemon serve --log-file --keep-alive 0` with `posix_spawn`: a new session (`POSIX_SPAWN_SETSID`), stdio on `/dev/null`, and no other descriptor inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so `UDID=$(simctlhouse acquire)` never waits for it.
   Two commands racing both spawn; the second daemon finds the lock held and exits.
2. If it is held by another build (another resolved path, inode or modification time of the binary), send that daemon `SIGTERM` and spawn this build with `--take-over`, then return without waiting.
   The old daemon finishes its current collection and exits; the new one waits up to 10 minutes for the lock, holding `daemon.next.lock` meanwhile so that further commands start no second replacement.
   The old daemon is signalled only while its pid still has the recorded start time.
   Until it has exited, the state's `version` keeps it from damaging what the new build wrote (D31).

`daemon start` passes its `--keep-alive` (30 minutes by default, as for `daemon serve` run by hand) to `daemon serve`, which records the end as `keepAliveUntil` in `daemon.lock`.
While that time has not passed, a daemon with nothing to watch keeps the lock and sleeps until it ends or a command changes the state, instead of exiting.
If a daemon of this build runs whose keep-alive ends sooner, `daemon start` signals it and spawns a replacement with `--take-over`, as for another build.
With `--keep-alive 0` it first collects garbage and asks `Pool.hasWorkForDaemon` whether anything is left to watch, as the daemon would on its first wake; if nothing is, it starts none, since that daemon would exit at once.
Either way it then waits until the daemon it started has taken the lock.
The daemon takes its timeouts from the environment of the command that started it.

### Stopping

No work is ever left unwatched: the daemon decides to exit and releases `daemon.lock` inside a state transaction.
A command that adds work commits under the same lock, so either the daemon sees the work and stays, or the command finds the lock free afterwards and starts a new daemon.

It handles `SIGTERM` and `SIGINT` (`daemon stop`, Ctrl-C) by finishing the current collection and exiting, ignores `SIGHUP`, and exits if its home directory is deleted.
It switches its output to `daemon.log` only once it holds the lock, keeping the previous run's log as `daemon.log.1`, so a losing duplicate never touches the log.

## Audit trail

Leases and devices never disappear without a record.
`PoolDevice.endLease` moves the current lease into the device's `history` (last 5) with an end time and outcome.
`PoolState.retire` moves a device that leaves the pool into `retired` (last 50), with its history.
Every removal goes through it: `delete`, a failed create or boot, a vanished simulator, abandoned provisioning, and the old name of an expired or abandoned lease.
`history` matches a reference against current names and UDIDs, earlier UDIDs in lease records, and retired devices.

## Performance

Nearly all of a command's time is spent in `xcrun simctl`, 0.1-0.3s per call on an idle machine.
Independent calls run in parallel (`concurrently`): GC's device listing overlaps the device type and runtime listings.
`list` reuses GC's device snapshot when GC changed nothing, so on an idle machine it costs about one `simctl` call.
Between deadlines the daemon costs nothing: it sleeps, and a state change only makes it re-read `state.json`.

## Testing seams

`Pool` takes a `SimulatorBackend`, a `ProcessScanner`, a clock and a logger.
Unit tests use `FakeBackend` (an in-memory CoreSimulator) and `TestClock` to cover expiry, idle shutdown, crash recovery and concurrent acquires without real simulators.
`Daemon` takes its sleep as a function, so `DaemonTests` drive it through `TestClock`; `DaemonLauncher` takes its spawn and signal functions.
`Runner` takes a `CommandLauncher` and `RunSignals`, so `RunnerTests` script the command's exit and the signals it gets through `FakeLauncher`, against a real state file and watcher.
`SIMCTLHOUSE_HOME`, `SIMCTLHOUSE_LEASE_SECONDS` and `SIMCTLHOUSE_IDLE_SECONDS` (see D21) let end-to-end runs use real simulators in an isolated home with short timeouts, and `SIMCTLHOUSE_DAEMON=0` leaves the housekeeping to the commands.

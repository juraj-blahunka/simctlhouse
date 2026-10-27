# Decision log

Each entry records what was decided, why, and the trade-off we accepted.
Newest decisions go at the bottom.

## D1. Command names: `acquire` / `release`

Agents take a device with `acquire` and give it back with `release`.
These are standard concurrency terms, so agents use them correctly without extra explanation.
Alternatives considered: `lease`/`return`, `checkout`/`checkin` (reads backwards with the "house" theme), `borrow`/`return`.
`renew` extends a lease.

## D2. Pool devices live in the default CoreSimulator device set

`simctl --set <path>` would hide our devices from the user entirely, which was the first idea.
We verified that `xcodebuild -showdestinations` and `-destination id=<UDID>` cannot see devices in a custom set, so pool devices must live in the default set and are visible in Xcode's destination picker.

## D3. Ownership is the registry, names are bare words

simctlhouse only ever touches UDIDs recorded in its own `state.json`.
Device names are bare two-word identifiers (`amber-falcon`) with no prefix.
Trade-off: in Xcode you cannot tell our devices from yours by name, and if `state.json` is lost we cannot re-adopt devices by name (they become ordinary simulators that you delete by hand).

## D4. Names: two curated words

Names are `adjective-noun` drawn from 200 x 200 curated words embedded in the binary (40,000 combinations).
A pool holds tens of devices, so two words are plenty and a third would only make names harder to type.
`/usr/share/dict/words` was rejected: it is Webster's 2nd from 1934 and yields names like `zincky-moudie`, plus words you do not want in a device name.
Words that read like pool states (`busy`, `free`, `idle`) are excluded to avoid confusing `list` output.

## D5. State: one JSON file guarded by `flock(2)`

State lives in `~/.simctlhouse/state.json`.
Every mutation takes an exclusive `flock` on `state.lock`, reads, modifies, and writes through a temp file plus atomic rename.
The kernel releases `flock` when a process dies, so a crashed agent never wedges the pool.
The lock is held for milliseconds; slow work (create, boot, shutdown) happens outside it, protected by the `provisioning` and `maintenance` statuses.
SQLite was rejected as more machinery than ~50 rows need, and harder to inspect or repair by hand.
Per-device lock files were rejected because the CLI exits after `acquire`, so a process-held lock cannot represent a lease.

## D6. New devices come from `simctl create`

Every pool device is a plain `simctl create` in the default set; simctlhouse keeps no hidden devices or templates.
Measured on Xcode 27.1 / iOS 27.0 on an idle machine:

| Operation | Time |
| --- | --- |
| `simctl create` | 0.4s |
| First boot of a created device | 24s |
| `simctl clone` of a booted-once device | 2.9s |
| First boot of that clone | 2.2s |

Cloning a pre-booted template would skip the slow first-boot data migration.
We chose not to: templates are extra hidden state to build, lock, repair and clean up, and cloning across device sets is a less trodden CoreSimulator path.
Trade-off: an `acquire` that finds no free device, and the first boot after a reclaim or `reset`, take about 25s on an idle machine and much longer under load.
Reusing a free device, the common case, is unaffected.

## D7. Erasing means delete and create

"Erase" (on lease expiry and `reset`) deletes the simulator and creates a new one, rather than calling `simctl erase`.
Both lead to the same slow first boot, but only delete and create changes the UDID, which D10 relies on.

## D8. Release keeps the device booted and does not erase it

A normal `release` returns the device to the pool still booted, so the next `acquire` of the same model is instant.
Trade-off: state (installed apps, keychain, permissions, defaults) carries over to the next agent.
Agents that need a clean device should `reset` it or uninstall their app explicitly.

## D9. Leases: hard 30 minutes, extended only by `renew`

A lease expires 30 minutes after `acquire` or the last `renew`.
There is no automatic extension based on detected activity, and no per-acquire TTL.
Trade-off: an agent running a long suite must call `renew`, or its device is reclaimed mid-run.

## D10. Reclaimed devices get a new name

When a lease expires, the device is reclaimed: shut down, deleted and created again (erased), and returned to the pool as available under a new name.
Both the old name and the old UDID disappear, so a stale agent that comes back fails loudly with exit code 3.
It never silently releases or drives a device that has since been handed to someone else.

## D11. Idle shutdown after 15 minutes, no erase; `gc` shuts down right away

A free, booted device with no activity for 15 minutes is shut down by the GC that runs before every command.
It is not erased; it is only cleaned on lease expiry or an explicit `reset`.
The 15 minutes keep a released device warm for the next agent: reusing a booted device is instant, while booting a shut down one took 4.6s in our measurement, and an `acquire` that first had to shut it down took 8.5s.
The explicit `gc` command skips the wait and shuts down every free booted device, for when you want the CPU and memory back now.
Both spare devices a foreign process references (D14).

## D12. Lazy garbage collection, no daemon

Lease expiry and idle shutdown are enforced at the start of every command (`gc` runs them explicitly).
There is no daemon or launchd agent.
Trade-off: if nothing runs simctlhouse, expired leases and idle devices are only handled on the next invocation.

## D13. No capacity cap

Every `acquire` gets its own device; there is no limit on concurrently booted devices.
This fixes the shared-device conflicts, but not CPU and RAM contention when many agents run at once.
During end-to-end testing, nine booted simulators on one machine each burned close to a full core right after boot.
Revisit with a cap plus wait if contention shows up again.

## D14. Detecting the user's own use is best effort

A free device is skipped by `acquire`, and spared by idle shutdown, when another process's command line mentions its UDID (for example `xcodebuild -destination id=<UDID>` or `xcrun simctl install <UDID>`).
The simulator's own processes and simctlhouse invocations are ignored.
Use from inside the Xcode IDE or Simulator.app does not show up in process arguments and cannot be detected.
The real protection is D3: simctlhouse never touches simulators it did not create.

## D15. Default device resolution

- Default family is iPhone.
- Default iPhone is the newest `iPhone N Pro`, ordered by hardware model identifier (`iPhone19,2` > `iPhone18,1`).
- Default iPad is the newest base-memory `iPad Pro 11-inch`; memory variants like `(16GB)` are skipped.
- Only device types that some installed runtime supports are considered.
- The runtime is the newest installed iOS runtime that supports the chosen model; `--os 26` matches `26.x`, never `2.6`.

## D16. Leases leave an audit trail

Each device keeps its last 5 leases: holder label, PID and working directory of `acquire`, lease ID, UDID, acquire time, end time and outcome (`released`, `expired`, `reset`, `deleted`, `vanished`, `failed`).
A device that leaves the pool keeps its record in `retired` (the 50 most recent), so `history` still answers for a deleted, vanished or expired-and-renamed device.
New names never reuse a retired name, so `history <name>` stays unambiguous.
This exists because a leased device once vanished mid-test, and the only way to find out who held it was digging through agent transcripts.
Trade-off: `state.json` grows to a bounded few hundred records.

## D17. Every command accepts a name or a UDID

Agents mostly hold UDIDs, people mostly read names, so every command that takes a device accepts both.
`acquire <name|udid>` leases that specific free device, for an agent that wants its earlier device back with the app still installed.
It fails with exit code 5 instead of falling back to another device, because the caller asked for that one.
`history` also resolves names and UDIDs a device no longer has (after `reset`, expiry or deletion).

## D18. Independent `simctl` calls run in parallel

Every `simctl` invocation costs 0.1-0.3s on an idle machine, almost all of it waiting on CoreSimulator, and seconds under load.
A command needs the live device list (for GC and for display) and the device type and runtime lists (for model names and resolution).
These are independent, so they run at the same time, and `list` reuses GC's device snapshot when GC changed nothing.
GC's shutdowns and reclaims each touch a different simulator, so they run in parallel too.
`list` on an idle machine went from about 0.8s (four sequential calls) to about 0.25s.

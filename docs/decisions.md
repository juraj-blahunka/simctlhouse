# Decision log

Each entry records what was decided, why, and the trade-off we accepted.
Newest decisions go at the bottom.

## D1. Command names: `acquire` / `release`

Agents take a device with `acquire` and give it back with `release`.
These are standard concurrency terms, so agents use them correctly without extra explanation.
Alternatives considered: `lease`/`return`, `checkout`/`checkin`, `borrow`/`return`.
`renew` extends a lease.

## D2. Pool devices live in the default CoreSimulator device set

`simctl --set <path>` would hide our devices from the user entirely.
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
The lock is held for milliseconds; slow work (create, boot, shutdown, delete) happens outside it, protected by the `provisioning` and `maintenance` statuses.
SQLite was rejected as more machinery than a few hundred records need (devices plus their lease history, D16), and harder to inspect or repair by hand.
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
We chose not to: templates are extra hidden state to build, lock, repair and clean up.
Trade-off: an `acquire` that finds no free device, and the first boot after a reclaim or `erase`, take about 25s on an idle machine and much longer under load.
Reusing a free device, the common case, is unaffected.

## D7. `erase` wipes in place; expiry deletes and re-creates

`erase` shuts the device down and runs `simctl erase`, so it keeps its name and UDID; the command is named after the `simctl` one it wraps.
Scripts, Xcode destinations and agents that saved the UDID keep working after an erase.
Lease expiry instead deletes the simulator and creates a new one, because only that changes the UDID, which D10 relies on.
Both lead to the same slow first boot (about 25s), so neither is cheaper.
(`simctl reset` is unrelated: it only rebuilds the launch services database.)

## D8. Release keeps the device booted and does not erase it

A normal `release` returns the device to the pool still booted, so the next `acquire` of the same model skips the boot.
Trade-off: state (installed apps, keychain, permissions, defaults) carries over to the next agent.
Agents that need a clean device should `erase` it or uninstall their app explicitly.

## D9. Leases: hard 30 minutes, extended only by `renew`

A lease expires 30 minutes (the default, see D21) after `acquire` or the last `renew`.
There is no automatic extension based on detected activity, and no per-acquire TTL.
Trade-off: an agent running a long suite must call `renew`, or its device is reclaimed mid-run.

## D10. Reclaimed devices get a new name

When a lease expires, the device is reclaimed: shut down, deleted and created again (erased), and returned to the pool as available under a new name.
Both the old name and the old UDID disappear, so a stale agent that comes back fails loudly with exit code 3.
It never silently releases or drives a device that has since been handed to someone else.
This is the only case where a device gets a new name; shutting a device down keeps its name and UDID.

## D11. Idle shutdown after 15 minutes; `gc` shuts down right away

A free, booted device with no activity for 15 minutes (the default, see D21) is shut down by the GC that runs before every command.
It is not erased; it is only cleaned on lease expiry or an explicit `erase`.
The 15 minutes keep a released device warm for the next agent.
Measured: re-acquiring a booted device took 2.0s with no boot, booting a shut down one took 4.6s, and shutting a device down and booting it again took 8.5s.
The explicit `gc` command skips the wait and shuts down every free booted device, for when you want the CPU and memory back now.
Both spare devices a foreign process references (D14).

## D12. Lazy garbage collection, no daemon

Lease expiry and idle shutdown are enforced at the start of every command.
The `gc` command runs the same collection on demand, and also shuts down free devices before their idle timeout (D11).
There is no daemon or launchd agent.
Trade-off: if nothing runs simctlhouse, expired leases and idle devices are only handled on the next invocation.

## D13. No capacity cap

Every `acquire` gets its own device; there is no limit on concurrently booted devices.
This fixes the shared-device conflicts, but not CPU and RAM contention when many agents run at once.
A freshly booted simulator uses close to a full core, and during end-to-end testing on a machine shared with other agents' builds the load average passed 500.
Revisit with a cap plus wait if contention shows up again.

## D14. Detecting the user's own use is best effort

A free device counts as in use when another process's command line mentions its UDID (for example `xcodebuild -destination id=<UDID>` or `xcrun simctl install <UDID>`).
Such a device is skipped by `acquire`, refused by `acquire <name|udid>` with exit code 5, and spared by idle shutdown and `gc`.
The simulator's own processes and simctlhouse's own invocations are ignored; the latter are recognised by the executable name, so other tools with "simctlhouse" in a path still count.
An executable path containing a space is not recognised as simctlhouse, which only makes it more cautious.
Use from inside the Xcode IDE or Simulator.app does not show up in process arguments and cannot be detected.
The real protection is D3: simctlhouse never touches simulators it did not create.

## D15. Default device resolution

- Default family is iPhone, chosen with `--family iphone|ipad`.
  The option is not called `--device` because in `simctl` a device is one specific simulator, which is what `<name|udid>` arguments name.
- Default iPhone is the newest `iPhone N Pro`, ordered by hardware model identifier (`iPhone19,2` > `iPhone18,1`).
- Default iPad is the newest base-memory `iPad Pro 11-inch`; memory variants like `(16GB)` are skipped.
- Only device types that some installed runtime supports are considered.
- The runtime is the newest installed iOS runtime that supports the chosen model; `--os 26` matches `26.x`, never `2.6`.

## D16. Leases leave an audit trail

Each device keeps its last 5 leases: holder label, the PID and working directory of the process that ran `acquire` (usually the agent's shell), lease ID, UDID, acquire time, end time and outcome.
Outcomes are `released`, `expired`, `erased`, `deleted`, `vanished`, `failed` (create or boot failed), `abandoned` (the creating process crashed) and `runtimeRemoved` (the iOS runtime was uninstalled).
A device that leaves the pool keeps its record in `retired` (the 50 most recent), so `history` still answers for a deleted, vanished or expired-and-renamed device.
New names never reuse a retired name, so `history <name>` stays unambiguous.
This exists because a leased device once vanished mid-test, and the only way to find out who held it was digging through agent transcripts.
The underlying cause is not fixed (D23).
Trade-off: `state.json` grows to a bounded few hundred records.

## D17. Every command accepts a name or a UDID

Agents mostly hold UDIDs, people mostly read names, so every command that takes a device accepts both.
`acquire <name|udid>` leases that specific free device, for an agent that wants its earlier device back with the app still installed.
It fails with exit code 5 instead of falling back to another device, because the caller asked for that one.
`history` also resolves names and UDIDs a device no longer has (after expiry or deletion).
`list` is the exception: it filters like `simctl list devices` (D25), so a name or UDID there is a search term.

## D18. Independent `simctl` calls run in parallel

Every `simctl` invocation costs 0.1-0.3s on an idle machine, almost all of it waiting on CoreSimulator, and seconds under load.
A command needs the live device list (for GC and for display) and the device type and runtime lists (for model names and resolution).
These are independent, so they run at the same time, and `list` reuses GC's device snapshot when GC changed nothing.
GC's shutdowns and reclaims each touch a different simulator, so they run in parallel too.
`list` on an idle machine went from about 0.8s (four sequential calls) to about 0.25s.

## D19. iPhone and iPad only

simctlhouse manages iPhone and iPad simulators only.
`--model` with a watchOS, tvOS or visionOS device type fails with exit code 2.
The agents this serves build and test iOS apps; other platforms bring their own runtimes, pairing rules and defaults, which nobody has asked for.

## D20. Release and renew trust the caller

Any process can `release` or `renew` a device by name or UDID; the lease ID is optional.
Agents run as the same user and cooperate, so requiring the lease ID would mostly add a way for well-behaved agents to fail.
Scripts that want protection against releasing someone else's device pass `--lease-id`, which fails with exit code 4 on a mismatch.
Trade-off: a confused agent can release a device another agent holds; `history` shows who held it.

## D21. Timeouts are configured with environment variables

`SIMCTLHOUSE_LEASE_SECONDS` (default 30 minutes) and `SIMCTLHOUSE_IDLE_SECONDS` (default 15 minutes) set the lease length and the idle shutdown.
An idle time of 0 shuts free devices down on the next command, for machines where CPU and memory matter more than a warm device.
Environment variables need no new files and fit how agents are launched; a config file in the state directory would be the alternative.
A malformed value fails every command with exit code 64 rather than falling back to the default, so a typo cannot silently change lease lengths.
Trade-off: each invocation reads its own environment.
The lease length is stored in each lease, so it stays consistent, but the idle timeout is enforced by whichever invocation runs GC, so agents should share the same values.
The skill tells agents to renew relative to the printed expiry instead of a fixed number of minutes.

## D22. Exit codes are API

Each failure class has its own exit code (1 simctl or I/O, 2 model or runtime, 3 not found, 4 lease mismatch, 5 leased or busy, 64 usage), documented in the how-to and the skill.
Agents branch on them instead of parsing messages, so codes are never renumbered or reused; new failure classes get new codes.

## D23. Known risk: GC trusts a single device listing

GC retires a device as `vanished` the first time one `simctl list devices` call does not include it.
If CoreSimulator briefly returns an incomplete list, for example while its service restarts, a live device would be dropped from the registry and never managed again.
This is the likely cause of the vanished device in D16, which disappeared during a window where every `simctl` call reported no runtimes.
Not fixed yet: a fix (skip the run when `simctl` reports no runtimes, and require the device directory to be gone too) should first be reproduced end to end.

## D24. Agent agnostic

simctlhouse is a plain CLI with no agent integration, so any agent that runs shell commands can use it.
The workflow lives in `skills/simctlhouse/SKILL.md`, in the Agent Skills format several agents share, rather than under one agent's directory.
`install.sh` links it into every agent it detects (Claude Code, Codex, pi) and into any `--skills-dir`; agents without skills get a short `AGENTS.md` snippet from the how-to.
Repository instructions live in `AGENTS.md`, which most agents read; `CLAUDE.md` is a symlink to it so there is one source.
Agents that read both, such as pi, take `AGENTS.md` first, so the instructions are not loaded twice.
Trade-off: the skill cannot use features only one agent has, and detection only covers agents whose skills directory we know.

## D25. `list` filters like `simctl list devices`

`list` takes state keywords (`booted`, `shutdown`), status keywords (`available`, `leased`, `provisioning`, `maintenance`) and search terms, the way `simctl list devices booted` and `simctl list devices <search term>` do.
Every keyword must match; a device matching any search term is shown, and a term matches a substring of the name, UDID, model, `iOS <version>` or holder, case-insensitively.
Device names always contain a hyphen and UDIDs are hex, so keywords never collide with a device.
As in `simctl`, no match is an empty list with exit code 0; `udid` remains the exact lookup that fails with exit code 3.

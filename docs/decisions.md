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
The temp file is flushed with `F_FULLFSYNC` before the rename, because a power loss could otherwise leave an empty `state.json`, and an empty or unreadable registry orphans every device.
That costs a few milliseconds per write, small next to the `simctl` calls every command makes.
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

A lease expires 30 minutes (the default, see D21) after `acquire` returns the booted device, or after the last `renew`.
The clock restarts once the boot completes, so a slow create or boot on a loaded machine does not eat into the agent's time.
A boot that outlasts the whole lease finds the device reclaimed, and `acquire` fails with exit code 3.
There is no automatic extension based on detected activity, and no per-acquire TTL.
Trade-off: an agent running a long suite must call `renew`, or its device is reclaimed mid-run.
`simctlhouse run` leases are the exception: they last as long as the `run` process (D33).

## D10. Reclaimed devices get a new name

When a lease expires, the device is reclaimed: shut down, deleted and created again (erased), and returned to the pool as available under a new name.
Both the old name and the old UDID disappear, so a stale agent that comes back fails loudly with exit code 3.
It never silently releases or drives a device that has since been handed to someone else.
This is the only case where a device gets a new name; shutting a device down keeps its name and UDID.

## D11. Idle shutdown after 15 minutes; `gc` shuts down right away

A free, booted device with no activity for 15 minutes (the default, see D21) is shut down by garbage collection, which the daemon runs on time (D29) and every command runs first.
It is not erased; it is only cleaned on lease expiry or an explicit `erase`.
The 15 minutes keep a released device warm for the next agent.
Measured: re-acquiring a booted device took 2.0s with no boot, booting a shut down one took 4.6s, and shutting a device down and booting it again took 8.5s.
The explicit `gc` command skips the wait and shuts down every free booted device, for when you want the CPU and memory back now.
Both spare devices a foreign process references (D14).

## D12. Every command collects garbage first

Lease expiry and idle shutdown are enforced at the start of every command, so the pool is consistent whenever a command reads it, with or without a daemon.
The `gc` command runs the same collection on demand, and also shuts down free devices before their idle timeout (D11).
On their own, commands left expired leases and idle devices waiting for the next invocation; since D29 an on-demand daemon also collects on time.

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
The likely cause, a single incomplete device listing, is fixed since D23.
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
The lease length is stored in each lease, so it stays consistent, but the idle timeout is enforced by whichever invocation runs GC, and by the daemon with the value of the command that started it (D29), so agents should share the same values.
The skill tells agents to renew relative to the printed expiry instead of a fixed number of minutes.

## D22. Exit codes are API

Each failure class has its own exit code (1 simctl or I/O, 2 model or runtime, 3 not found, 4 lease mismatch, 5 leased or busy, 6 skill install, 64 usage), documented in the how-to and the skill.
Agents branch on them instead of parsing messages, so codes are never renumbered or reused; new failure classes get new codes.

## D23. A device is gone only when it is gone from disk too

GC used to retire a device as `vanished` the first time one `simctl list devices` call did not include it.
CoreSimulator can briefly return an incomplete list, for example while its service restarts, and a live device was then dropped from the registry and never managed again.
This is the likely cause of the vanished device in D16, which disappeared during a window where every `simctl` call reported no runtimes.

Now a device missing from the listing is retired only if its `device.plist` in `~/Library/Developer/CoreSimulator/Devices/<UDID>/` is gone too; pool devices always live in that default set (D6).
`simctl delete`, Xcode and simctlhouse itself all remove that directory, while an incomplete listing does not.
A device that is unlisted but on disk stays in the pool untouched: `acquire` does not hand it out (`acquire <name>` refuses it with exit code 5, since its boot would likely fail and delete it), idle shutdown and lease reclaim wait, and `list` shows it as `Missing`, until a listing includes it again.
Deleting such a device, as `delete` or a lease reclaim does, still runs `simctl delete` on it, so no simulator is left behind untracked.
The glitch itself cannot be reproduced on demand without killing CoreSimulatorService, which would shut down every running simulator on the machine, so a `FakeBackend` that leaves devices out of its listing covers it in `PoolTests`.
Skipping GC whenever `simctl` reports no runtimes was considered as well; the disk check alone covers that case and every other incomplete listing.
Trade-off: a simulator that CoreSimulator never lists again while its directory remains stays in the pool as `Missing` until someone deletes it.

## D24. Agent agnostic

simctlhouse is a plain CLI with no agent integration, so any agent that runs shell commands can use it.
The workflow lives in `skills/simctlhouse/SKILL.md`, in the Agent Skills format several agents share, rather than under one agent's directory.
`scripts/install.sh` links it into every agent it detects (Claude Code, Codex, pi) and into any `--skills-dir`; agents without skills get a short `AGENTS.md` snippet from the how-to.
Repository instructions live in `AGENTS.md`, which most agents read; `CLAUDE.md` is a symlink to it so there is one source.
Agents that read both, such as pi, take `AGENTS.md` first, so the instructions are not loaded twice.
Trade-off: the skill cannot use features only one agent has, and detection only covers agents whose skills directory we know.

## D25. `list` filters like `simctl list devices`

`list` takes state keywords (`booted`, `shutdown`), status keywords (`available`, `leased`, `provisioning`, `maintenance`) and search terms, the way `simctl list devices booted` and `simctl list devices <search term>` do.
Every keyword must match; a device matching any search term is shown, and a term matches a substring of the name, UDID, model, `iOS <version>` or holder, case-insensitively.
Device names always contain a hyphen and UDIDs are hex, so keywords never collide with a device.
As in `simctl`, no match is an empty list with exit code 0; `udid` remains the exact lookup that fails with exit code 3.

## D26. Releases ship the skill; `skill install` links it

A release (a notarized binary, distributed through a Homebrew tap) installs the skill as data in `<prefix>/share/simctlhouse/skills/simctlhouse`.
`simctlhouse skill install` symlinks it into each agent's skills directory, pointing at the prefix path rather than the versioned keg, so `brew upgrade` updates the skill without another install.
The binary finds the prefix from the path it was started as (`_NSGetExecutablePath`), following symlinks one hop at a time and normalising `..` textually, because `standardizedFileURL` resolves symlinks and would land in the versioned keg.
Homebrew cannot create the links itself: formulae must not write to `$HOME`, so the formula's caveats ask for the one-time `skill install`.
A link counts as ours when its target is a `simctlhouse` directory whose `SKILL.md` is named `simctlhouse`, or such a path that no longer exists (Agent Skills name the directory after the skill).
`scripts/install.sh` stays the local build path and calls `skill install --source <checkout>/skills/simctlhouse`, so skill edits take effect immediately and agent detection and link ownership live only in the binary.
Switching between a checkout and a release just replaces the link.
We chose `--source` over having `scripts/install.sh` mimic the release layout (`<prefix>/share` linking into the checkout): it is explicit and adds nothing to the prefix, at the cost of local installs not exercising the shipped-skill lookup.
Trade-off: one manual step after `brew install`, and `brew uninstall` leaves broken links unless `skill uninstall` ran first; `skill status` shows them.

## D27. Releases: notarized arm64 binary in a prefix-shaped tarball

We ship a prebuilt binary through our own tap rather than building from source in the formula, so users need neither Swift nor a build, and the binary they run is the one we signed and notarized.
It is a formula, not a cask: only formulae get the stable `opt` and `share` links that the skill links rely on (D26).
The tarball mirrors an install prefix, so the formula only moves `bin/` and `share/` into place, and the same archive works when unpacked by hand.
The binary is arm64 only: Xcode has deprecated x86_64, and the formula says `depends_on arch: :arm64` so Intel Macs get a clear error.
`scripts/build.sh` is the only way the binary is built, for `scripts/install.sh` and `scripts/release.sh` alike, so a local install runs the bytes a release ships (only the signing timestamp differs).
It strips the debug symbol table, which holds absolute build paths and would publish the builder's home directory, signs with the hardened runtime, and checks the minimum macOS against `Package.swift`, from which the formula's `depends_on macos:` is derived.
After notarization the script asks Apple's ticket service whether a ticket is published for the binary's code hash, the lookup users' Macs make; `spctl` cannot be used, because asked before the ticket is published it caches "Unnotarized" for that hash.
Before publishing, `scripts/smoke-test.sh` runs the tarball against real simulators.
The version stays hardcoded in `SimctlHouse.swift`; `scripts/release.sh` refuses to build when it differs from the release version, which avoids generated sources and keeps `swift build` from any checkout meaningful.
The script verifies its own output by installing the tarball into a temporary directory and running `skill install` from it.
Trade-off: a bare binary cannot be stapled, so Gatekeeper checks notarization online on first run; Homebrew does not quarantine formula downloads, so this only matters for manual downloads.

## D28. In-flight work is claimed by a process

Work done outside the lock (create, shutdown, erase, re-create, delete) puts the device in `provisioning` or `maintenance` with a claim: a random id, the pid, and the process start time.
The transaction that finishes the work looks the record up by claim id and changes nothing if the claim is gone.
GC repairs a claimed record once the claiming process has exited, and after an hour even if it has not.
Previously GC repaired every such record after 10 minutes and the finishing transaction looked the device up by name, so a slow `erase` on a loaded machine could set a device someone had leased in the meantime back to `available`, and the next `acquire` leased it twice.
The start time guards against pid reuse; process liveness comes from `sysctl(KERN_PROC_PID)`, which is cheap enough to ask inside the lock.
The hour stays as a backstop because a hung `simctl` would otherwise hold a device forever.
The claim keeps the late process from changing the record, and the command that lost its claim fails with exit code 5.
It cannot stop the late `simctl` call itself: a hung `erase`, `shutdown` or `delete` that completes after the takeover still acts on the simulator, which may have a new holder by then.
Accepted, since it takes a `simctl` call stuck for over an hour.
Records written by an older version carry no claim and are repaired only after the hour.
Trade-off: a device whose simctlhouse process hangs stays unusable for up to an hour instead of 10 minutes.

## D29. An on-demand daemon enforces timeouts on time

Without one, an expired lease kept its device booted, and a released device stayed booted past its idle time, until some command happened to run (D12).
`acquire`, `release` and `renew` (and since D33 `run`) now start `simctlhouse daemon serve` when none runs; it collects garbage as deadlines come due and exits once nothing is leased, booted or in progress.
A launchd agent was rejected: it runs whether or not the pool is in use, and needs installing and uninstalling.

The daemon needs no port or socket, because all coordination already goes through `state.json` and its lock.
A daemon that commands talk to would need a port or socket, a protocol, versioning and authentication, all for no behaviour the state does not already carry.
An exclusive `flock` on `daemon.lock`, held for the daemon's life, says whether one runs; unlike a pid file it cannot go stale.
The daemon releases it inside a state transaction when it decides to exit, so a command that adds work concurrently always either keeps it alive or starts a new one.

A command run by another build of simctlhouse replaces the daemon, so after an upgrade the new build's daemon runs.
A build is its binary's resolved path, inode and modification time, recorded in `daemon.lock`, rather than the version string, which a rebuild or a copy over the old binary leaves unchanged.
The command does not wait for the old daemon, which may be in the middle of re-creating devices: it signals it and starts a successor that waits for the lock.
Replacing the daemon keeps the right build running; keeping an old build from damaging `state.json` is the job of the file's `version` (D31).
Two builds in use side by side, such as a Homebrew install and a checkout's `scripts/install.sh`, replace each other's daemon whenever the other one runs a command; that costs a restart, never a missed deadline.
The daemon inherits the environment of the command that started it, including `SIMCTLHOUSE_IDLE_SECONDS`; a command with another value does not restart it.
`SIMCTLHOUSE_DAEMON=0` keeps commands from starting it, for CI and throwaway homes; `daemon start` starts it explicitly, taking the timeouts from its own environment, which the smoke test uses with a 1s idle time.
`daemon start` keeps it running for `--keep-alive` seconds (30 minutes by default) even with nothing to watch, so it can be tested and watched without leasing a device first.
The keep-alive is a flag rather than an environment variable: the variables are pool policy every agent should share, while the keep-alive is a choice for one manual start.
Nothing can tell a running daemon to stay longer, so a longer keep-alive restarts it the way another build is replaced; daemons that commands start never get one, so a single `release` never leaves a process idling for 30 minutes.
Trade-off: a background process outlives the command that started it, by up to the idle time (15 minutes) after the last device is released.

## D30. A corrupt state file is reset

A `state.json` that cannot be decoded is moved to `state.json.corrupt-<time>`, and the command goes on with an empty pool and a warning.
Failing every command until someone repairs the file by hand wedged the whole pool, including the daemon, over one bad write.
The cost is that the simulators the corrupt file listed are no longer managed: simctlhouse never touches a simulator it has no record of (D3), so they stay until deleted by hand, and the moved file keeps their UDIDs for that.
A file that cannot be read at all (permissions, I/O) still fails the command, since it may be fine on the next try.
So does a file of a newer `version` (D31): a newer simctlhouse wrote it, and resetting it would wipe that pool.

## D31. `state.json` is versioned; a build refuses a newer file

`PoolState.currentVersion` is bumped with every change to what `state.json` holds, and new fields are optional.
A build reads files up to its own version and writes its own version; a newer file fails every command with exit code 1 and an upgrade hint, without being written.
Without this, an older build decodes a newer file, ignores the fields it does not know, and drops them on its next write: claims, for example, which would let two processes act on one device again (D28).
Replacing the daemon after an upgrade (D29) is not enough on its own: any old binary can write the file, such as a second install, a script pinned to an old path, or an old daemon finishing its last collection.
Trade-off: after an upgrade that bumps the version, an older binary on the same machine stops working instead of limping on.

## D32. Unused devices are deleted on request, never automatically

A simulator that has booted takes about 2.4 GB, and the pool only grows: a day with eight parallel agents leaves eight devices behind, and after an Xcode update the devices of the old iOS version never match a default `acquire` again.
`delete --unused` deletes free devices whose `lastActivityAt` (the last acquire, release or renew) is older than `--for`, 7 days by default, and reports the space each one took.
Deleting them automatically was rejected: a device would disappear without anyone asking, and an agent that kept a device's name to reuse it would find it gone.
The selection happens in the transaction that claims the devices, so a device acquired meanwhile is never deleted; leased and busy devices, and free ones another process uses (D14), are skipped without needing `--force`.
Sizes are measured only for the devices being deleted, once claimed and outside the state lock, so `list` stays fast and shows no sizes.
The history reason is `deleted`, as for any other `delete`, so `state.json` does not change.
Trade-off: the disk space only comes back when someone runs the command; `list` does not hint at it.

## D33. `run` binds a lease to its process instead of renewing it

`simctlhouse run` wraps one command in a lease, because agents forget to release and renew: `history` showed leases without a holder, and a device reclaimed mid-test after a forgotten `renew`.
Its lease carries an `owner`, the pid and start time of the `run` process; while that process runs, GC never expires the lease, and once it is gone, GC reclaims the device.
This narrows D9: a lease held by `run` lasts as long as its command, however long that is.

A wrapper that calls `renew` on a timer was rejected.
A renew that fails under load needs retries; after the Mac sleeps, the daemon and the wrapper's timer race, and the lease can be lost; every renew runs a full GC.
Above all, a wrapper killed with SIGKILL, as agent harnesses do on a timeout, would leave the device leased until the lease ran out, and handling that needs the owner in the lease anyway.
With the owner recorded, the timer adds nothing.

A dead owner gets its device reclaimed (re-created under a new name, outcome `abandoned`) rather than released, since the command it started may still be running as an orphan; deleting the simulator cuts it off.
The daemon notices within its 60-second poll; with `SIMCTLHOUSE_DAEMON=0`, the next command does.
GC keeps the owned lease's `expiresAt` moving forward, so `nextWake`, `--json` readers and older tooling still see a live lease.
The release at the end runs one transaction without GC or `simctl` calls, so it finishes in milliseconds, before a harness follows its SIGTERM with a SIGKILL.
`run` watches the state while the command runs; if a device no longer carries its lease (someone released or deleted it, D20), it stops the command, which could otherwise act on a device another agent now holds.

Signals: the command runs in `run`'s process group, so Ctrl-C and a harness that kills the group reach it directly.
`run` forwards SIGTERM, and SIGINT, SIGQUIT or SIGHUP unless the terminal sent them to the whole group; macOS leaves `si_pid` and `si_code` unreliable, so a signal counts as the terminal's while `run` is the terminal's foreground process group.
A command that has not exited 15 seconds after it was stopped, or that gets a second signal, is killed with every process it started.
`--timeout` stops it the same way.

Trade-off: a command that hangs holds its device for as long as `run` lives, where a forgotten `acquire` frees it after 30 minutes; `--timeout` and the agent's own timeouts bound that.
A pool whose agents' harnesses routinely SIGKILL `run` re-creates devices more often, each costing a first boot.
`state.json` went to version 2 for the owner (D31).

## D34. `run` fills in the device, and keeps its own exit codes out of the command's way

`run` exits with its command's code, so agents and scripts read it like the command's own.
Its own failures cannot use the codes of D22, which commands use too (xcodebuild exits 65 and others, plenty of tools exit 1 or 2), so it uses the convention of `env`, `nice` and `timeout`: 124 timed out, 125 simctlhouse failed, 126 cannot execute, 127 not found, and 128+N or the same signal when signal N ended the command.
125 covers every failure of simctlhouse itself, with the cause on stderr; usage errors under `run` are mapped from 64 to 125 as well.
Re-raising the signal tells a calling shell that the command was interrupted, so a script stops on Ctrl-C; crash signals are reported as 128+N instead, since raising them again would file a crash report against simctlhouse.

A direct `xcodebuild` (or `xcrun xcodebuild`) gets `-destination id=<UDID>` added, one per device with `--count`, unless it lists or archives.
Agents then cannot get the destination wrong, which `-destination 'name=iPhone ...'` and `booted` do all the time, and which is the collision simctlhouse exists to prevent.
A `-destination` that is not generic and does not name the leased UDID is refused with 125 rather than warned about: an agent ignores a warning, and the fix is to delete the option.
It is refused before leasing when no lease could make it valid, so no boot is wasted.
Other tools take the device in arguments whose place depends on the subcommand, so they get `{udid}` and `{name}` placeholders and `SIMCTLHOUSE_UDID`, `SIMCTLHOUSE_DEVICE_NAME` and `SIMCTLHOUSE_LEASE_ID` instead of guessing (D38 extends this).
With `--count`, the singular variables are not set and `{udid}` and `{name}` are refused, so a script written for one device fails loudly instead of using the first.

`run` is for one self-contained command, typically an end-to-end test run, and the docs and skill present it only that way.
Steps that must share a device, such as build, install, launch and screenshot, hold it across commands with `acquire` and `release`, like a lock: two `run`s may get two devices, and chaining the steps into one `run` with `sh -c` hides that they depend on one device.

Without `--holder` or `SIMCTLHOUSE_HOLDER`, `acquire` and `run` label the lease with the agent and directory, such as `claude in app`, and `run` adds the command.
The agent is the first process above the shells and wrappers in between, named by its `argv[0]`, since the kernel's process name of a binary installed under a version number (`~/.local/share/claude/versions/2.1.3`) is that number.
The directory is the last component of `$PWD` (when it names the working directory) or of the working directory; `history` keeps the full path.
Trade-off: the default says who and where, not what; the skill still asks for a `--holder`.

## D35. `uninstall` removes everything but the binary, after asking

`brew uninstall` removes only the binary and the shipped skill: the pool's simulators (about 2.4 GB each once booted), the daemon, the skill links and `~/.simctlhouse` stayed behind, and the formula only mentioned the links.
`simctlhouse uninstall` stops the daemon, deletes every pool device including leased ones, removes the skill links, stops the daemon again in case a command started it meanwhile, and removes the state directory.
The binary is left to the package manager; the command ends by printing `brew uninstall simctlhouse` or the `rm` for a binary installed otherwise.
It shows what it will remove and asks, since it ends other agents' leases; without a terminal it refuses unless `--yes` is passed, so an agent cannot run it by accident, and the skill forbids it.
If a device cannot be deleted, the state and the links stay, so running it again picks up where it stopped instead of leaving simulators nothing tracks.
The state directory is removed under the state lock, and only once it lists no device, so a device that an agent acquired meanwhile is deleted too rather than left untracked.
Trade-off: lease history and the daemon log go with the state directory.

## D36. `delete` and `erase` wait for a device that is mid-operation

The daemon shuts down a free device once its idle time is up, and the device is `maintenance` while it does.
`delete --all --force` right after a release raced with that and failed with `busy (maintenance)`, which broke the smoke test and would break a script that cleans up after a run; `erase` right after a release raced the same way.
`delete` and `erase` now retry for up to 30 seconds (`PoolConfig.busyWait`) when a selected device is `provisioning` or `maintenance`, collecting garbage between attempts so a claim whose process died is repaired meanwhile, and fails with exit code 5 only if the device is still busy after that.
`acquire <name>` still fails at once, since the agent can take any other device instead, and `delete --unused` still skips busy devices, since it only cleans up what is idle.
The bound is not strict, since each garbage collection between attempts can itself take long when it has to re-create a device.
Trade-off: a device that is hung in a long operation makes `delete` or `erase` wait the full 30 seconds before it fails.

## D37. `acquire --skip-boot` leases a device as it is

Booting takes about 30 seconds for a new device, and some work needs no running simulator: `xcodebuild build` only needs a destination, and the smoke test checks leasing and the daemon, not booting.
`acquire --skip-boot` leases a device without booting it; a new one stays shut down, and a free one that is already booted stays booted, since shutting it down would only cost the next agent a boot.
It still prefers a booted device, like a plain `acquire`, so it never leaves a booted device idle while another one is shut down.
The lease starts once the device exists, as after a boot.
`run` always boots, since it hands the device to a command that usually needs it running.
Trade-off: a command that does need a running simulator fails or boots it itself; the device stays in the pool either way, and the daemon shuts it down once it is free and idle.

## D38. `run` hands the device to any tool, not only xcodebuild

Tools other than xcodebuild take their simulator as a flag, such as AXe's `--udid`, and `run` fills those in with the placeholders of D34.
`run` sets only its own `SIMCTLHOUSE_` variables, not ones named after other tools.
Setting `IDB_UDID` for idb and ios-simulator-mcp was considered and dropped: ios-simulator-mcp is an MCP server the agent starts, so `run` never reaches it, and idb run under `run` takes `--udid {udid}` like any other tool.
A second name for the UDID would add nothing but one more variable to keep in sync.

With `--count N`, each device also gets indexed variables, `SIMCTLHOUSE_UDID_<i>`, `SIMCTLHOUSE_DEVICE_NAME_<i>` and `SIMCTLHOUSE_LEASE_ID_<i>` for `i` from 0, set for a single device too so a script reads the same name either way.
The placeholders follow suit: `{udid<i>}` and `{name<i>}` name device `i`, while `{udid}` and `{name}` stay refused with several devices.
Naming a device explicitly by index is the opposite of using the first by accident, so it does not weaken D34.
A placeholder for a device the run does not lease, such as `{udid2}` with `--count 2`, is refused before anything is leased, so no boot is wasted.
Only a `-destination` the command passes itself stops xcodebuild from getting one added; a placeholder elsewhere does not, since `-resultBundlePath out/{name}.xcresult` still needs the destination.
Every variable `run` owns is cleared before it sets its own, so a `run` inside another `run` never sees the outer one's devices.

0.3 renamed `SIMCTLHOUSE_DEVICE` to `SIMCTLHOUSE_DEVICE_NAME` and `SIMCTLHOUSE_DEVICES` to `SIMCTLHOUSE_DEVICE_NAMES`, and the lists became comma-separated instead of space-separated.
`DEVICE` alone read like the device's identifier, and a comma-separated list splits the same way in every language, where a space-separated one relies on shell word splitting.
Trade-off: scripts written for 0.2 that read the old names or split on spaces break; the old names were not kept as aliases, since two names for one value stay forever.

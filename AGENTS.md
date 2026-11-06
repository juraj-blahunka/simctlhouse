# simctlhouse

Device Hub for Agents: a Swift CLI that leases iOS simulators to parallel agents from a shared pool.
Read `docs/architecture.md` before changing `Pool.swift`, and `docs/decisions.md` before changing behaviour.

## Commands

```sh
swift build                         # debug build
swift build -c release              # .build/release/simctlhouse
swift test                          # unit tests (FakeBackend, no simulators)
scripts/lint.sh                     # swift format lint --strict; must be clean, `scripts/lint.sh --fix` fixes most
scripts/install.sh                  # build release + install binary + link skill into detected agents (see --help)
scripts/build.sh OUTPUT             # the release binary: arm64, stripped, signed (install.sh and release.sh use it)
scripts/release.sh <version>        # signed, notarized release tarball + Homebrew formula in dist/ (see --help)
scripts/smoke-test.sh TARBALL [TEST...]  # run a release tarball through scripts/smoke/*.sh against real simulators in a throwaway home
```

## Layout

- `Sources/simctlhouse/SimctlHouse.swift`: CLI only (argument parsing, output, exit codes).
  Keep logic out of it.
- `Sources/SimctlHouseCore/`: all behaviour.
  `Pool` is the entry point; `SimulatorBackend` and `ProcessScanner` are the seams for tests.
  `Daemon` runs the background daemon and `DaemonLauncher` starts, replaces and stops it (`Daemon.swift`).
- `Tests/SimctlHouseCoreTests/Fakes.swift`: `FakeBackend`, `FakeScanner`, `TestClock`, `Harness`.
- `skills/simctlhouse/SKILL.md`: the agent skill.
  Update it whenever CLI behaviour or flags change, and keep it free of agent-specific instructions.
- `.agents/skills/release/SKILL.md`: the maintainer skill that publishes a release (tag, GitHub release, Homebrew tap).
- `docs/`: decisions, architecture, how-tos.
  `docs/assets/icon-source.png` is the full-bleed 1024px icon artwork; `docs/assets/icon.png` is the rounded README icon made from it.

## Invariants

- Never touch a simulator whose UDID is not in `state.json`.
  The user's own simulators are off limits.
- Every state mutation goes through `StateStore.transaction` (flock + durable atomic write).
  Never hold the lock across create, boot or shutdown; mark the device `provisioning` or `maintenance` with a claim (`PoolDevice.begin`) instead.
  Finish that work through `Pool.finish(claim)`, never by looking the device up by name (see D28).
- Take the live `simctl list` snapshot inside the transaction that acts on it.
- Commands talk to the daemon only through `state.json`; start it after the command's change has committed (`DaemonLauncher.ensureRunning`, see D29).
- Bump `PoolState.currentVersion` with every change to what `state.json` holds, and keep new fields optional; older builds then refuse the file instead of dropping what they do not know.
- Pool devices live in the default device set, because xcodebuild cannot see custom sets.
  Devices come from `simctl create` (see D6).
- `erase` wipes in place and keeps the UDID; lease expiry deletes and creates again, so the UDID changes (see D7).
- An expired lease gets a new device name, so stale agents fail with exit code 3 instead of touching someone else's device.
- Records never just disappear: removing a device goes through `PoolState.retire`, and ending a lease through `PoolDevice.endLease`, so `history` stays complete.
- Every command that takes a device accepts its name or UDID (`DeviceRef.valueName` in the CLI).
- stdout carries machine output only (UDID, name, JSON); everything human goes to stderr.
- Exit codes are API (see `SimctlHouseError.exitCode` and `docs/how-to.md`).
  Do not renumber them.

## Testing

- Add a unit test in `PoolTests` for any pool behaviour change, and in `DaemonTests` for the daemon; drive time with `TestClock`.
- Verify end to end with real simulators in an isolated home (`SIMCTLHOUSE_HOME=$(mktemp -d)`), with `SIMCTLHOUSE_LEASE_SECONDS` / `SIMCTLHOUSE_IDLE_SECONDS` to shorten timeouts.
  The daemon starts there too; set `SIMCTLHOUSE_DAEMON=0` to see what the commands alone do.
  Finish with `delete --all --force` and `daemon stop`, and check that the user's simulator count in `xcrun simctl list devices` is unchanged.
- The machine may be heavily loaded by other agents; create and boot timings are noisy, so do not assert on them.

## Verify

How agents verify a change end to end; the `verify` skill runs it rung by rung and stops at the first failure.

- Build: `swift build --build-tests` and `swift build -c release`
- Lint: `scripts/lint.sh`
- Test: `swift test`
- End to end: build a dev tarball the way a release lays it out:
  `d=$(mktemp -d); v=$(.build/release/simctlhouse --version); s=$d/simctlhouse-$v; scripts/build.sh $s/bin/simctlhouse && ditto skills/simctlhouse $s/share/simctlhouse/skills/simctlhouse && cp LICENSE $s/ && COPYFILE_DISABLE=1 tar -C $d --no-xattrs -czf $d/simctlhouse-$v-macos.tar.gz simctlhouse-$v`.
  Run the smoke scripts that cover the change (`scripts/smoke-test.sh <tarball> 04-acquire-starts-daemon ...`, all of them when unsure), and exercise the changed commands with `.build/release/simctlhouse` in `SIMCTLHOUSE_HOME=$(mktemp -d)`, using `--skip-boot` where booting is not what changed.
- Look: none (CLI); check the changed commands' output text instead.
- Isolation: only throwaway `SIMCTLHOUSE_HOME`s; never the user's own home or a simulator by name.
- Cleanup: in each throwaway home, `release` what was acquired, `delete --all --force` and `daemon stop`; `xcrun simctl list devices | grep -c "("` must be the same before and after.

## Style

- Match the surrounding code: small types, doc comments that explain why, no comment noise.
- Swift 6 language mode; keep everything `Sendable`.
- Docs: one sentence per line in Markdown.

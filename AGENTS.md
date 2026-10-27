# simctlhouse

Device Hub for Agents: a Swift CLI that leases iOS simulators to parallel agents from a shared pool.
Read `docs/architecture.md` before changing `Pool.swift`, and `docs/decisions.md` before changing behaviour.
This file is the instructions for every coding agent; `CLAUDE.md` is a symlink to it, so edit this one.

## Commands

```sh
swift build                         # debug build
swift build -c release              # .build/release/simctlhouse
swift test                          # unit tests (FakeBackend, no simulators)
swift format lint -r Sources Tests  # must be clean; `swift format format -i -r Sources Tests` fixes most
scripts/install.sh                  # build release + install binary + link skill into detected agents (see --help)
scripts/build.sh OUTPUT             # the release binary: arm64, stripped, signed (install.sh and release.sh use it)
scripts/release.sh <version>        # signed, notarized release tarball + Homebrew formula in dist/ (see --help)
scripts/smoke-test.sh TARBALL       # run a release tarball against real simulators in a throwaway home
```

## Layout

- `Sources/simctlhouse/SimctlHouse.swift`: CLI only (argument parsing, output, exit codes).
  Keep logic out of it.
- `Sources/SimctlHouseCore/`: all behaviour.
  `Pool` is the entry point; `SimulatorBackend` and `ProcessScanner` are the seams for tests.
- `Tests/SimctlHouseCoreTests/Fakes.swift`: `FakeBackend`, `FakeScanner`, `TestClock`, `Harness`.
- `skills/simctlhouse/SKILL.md`: the agent skill, in the Agent Skills (SKILL.md) format that Claude Code, Codex, pi and other agents load.
  Update it whenever CLI behaviour or flags change, and keep it free of agent-specific instructions.
- `.agents/skills/release/SKILL.md`: the maintainer skill that publishes a release (tag, GitHub release, Homebrew tap).
  `.claude/skills/release` is a symlink to it, like `CLAUDE.md` is to this file.
- `docs/`: decisions, architecture, how-tos.

## Invariants

- Never touch a simulator whose UDID is not in `state.json`.
  The user's own simulators are off limits.
- Every state mutation goes through `StateStore.transaction` (flock + atomic write).
  Never hold the lock across create, boot or shutdown; mark the device `provisioning` or `maintenance` instead.
- Take the live `simctl list` snapshot inside the transaction that acts on it.
- Pool devices live in the default device set, because xcodebuild cannot see custom sets.
  Devices come from `simctl create` (see D6).
- "Erase" means delete and create again, so the UDID changes.
- An expired lease gets a new device name, so stale agents fail with exit code 3 instead of touching someone else's device.
- Records never just disappear: removing a device goes through `PoolState.retire`, and ending a lease through `PoolDevice.endLease`, so `history` stays complete.
- Every command that takes a device accepts its name or UDID (`DeviceRef.valueName` in the CLI).
- stdout carries machine output only (UDID, name, JSON); everything human goes to stderr.
- Exit codes are API (see `SimctlHouseError.exitCode` and `docs/how-to.md`).
  Do not renumber them.

## Testing

- Add a unit test in `PoolTests` for any pool behaviour change; drive time with `TestClock`.
- Verify end to end with real simulators in an isolated home (`SIMCTLHOUSE_HOME=$(mktemp -d)`), with `SIMCTLHOUSE_LEASE_SECONDS` / `SIMCTLHOUSE_IDLE_SECONDS` to shorten timeouts.
  Finish with `delete --all --force` and check that the user's simulator count in `xcrun simctl list devices` is unchanged.
- The machine may be heavily loaded by other agents; create and boot timings are noisy, so do not assert on them.

## Style

- Match the surrounding code: small types, doc comments that explain why, no comment noise.
- Swift 6 language mode; keep everything `Sendable`.
- Docs: one sentence per line in Markdown.

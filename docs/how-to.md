# How-to

## Install

```sh
scripts/install.sh                                   # binary + skill for every agent found
scripts/install.sh --skills-dir ~/.my-agent/skills   # link the skill into a specific skills directory instead
scripts/install.sh --bin-dir ~/bin --no-skill        # custom location, binary only
scripts/install.sh --uninstall                       # remove binary and skill links
```

Requires an Apple silicon Mac and Xcode with at least one iOS simulator runtime (`xcodebuild -downloadPlatform iOS`).

The script builds the binary exactly as a release does, through `scripts/build.sh`: arm64, stripped of build paths, signed with the hardened runtime (your Developer ID if the keychain has one, otherwise ad-hoc).
So what you run locally behaves like what users get.
It installs the binary to `--bin-dir`.
The default is `/usr/local/bin` when writable, otherwise `~/.local/bin`, and it warns if that directory is not on your `PATH`.
It then runs `simctlhouse skill install --source <checkout>/skills/simctlhouse`, which symlinks the skill into the skills directory of every agent set up on the machine: `~/.claude/skills` for Claude Code, `~/.codex/skills` for Codex, and `~/.pi/agent/skills` for pi (or `$PI_CODING_AGENT_DIR/skills`).
`--skills-dir` (repeatable) replaces that detection with the directories you name.
Because these are links, every project picks up the skill and edits in this repo take effect immediately.
If something other than a simctlhouse skill link already sits at a link location, nothing is linked and the script stops rather than delete it.
Re-running it is safe and is how you upgrade after pulling; the next `acquire`, `release` or `renew` replaces a running daemon with the new build.
`--uninstall` removes the links with `simctlhouse skill uninstall` and stops the daemon before it removes the binary, and leaves the simulator pool alone; run `simctlhouse delete --all --force` first to remove it.

### From a release

A release puts the binary in `<prefix>/bin` and the skill in `<prefix>/share/simctlhouse/skills/simctlhouse`.
Link the skill into your agents once:

```sh
simctlhouse skill install                               # every agent found (Claude Code, Codex, pi)
simctlhouse skill install --skills-dir ~/.my-agent/skills
simctlhouse skill status                                # where each link points: linked, missing, broken or foreign
simctlhouse skill uninstall                             # before uninstalling the package
```

The binary finds the skill by following its own symlinks from the path it was started as, and links the first `../share/simctlhouse/skills/simctlhouse` it finds.
For Homebrew that is `$(brew --prefix)/share/simctlhouse/...`, which `brew upgrade` re-points at the new version, so the skill updates with the binary.
Running the binary from inside `Cellar/` links a versioned path that the next upgrade removes; the command warns about it.
`skill install` replaces earlier simctlhouse links, including ones `scripts/install.sh` made, and changes nothing if any link location holds something else.
`--source DIR` links another skill directory instead of the shipped one; `scripts/install.sh` uses it to link the checkout.
`skill uninstall` also removes links left broken by an uninstalled package.

## Use it from any agent

simctlhouse itself is a plain CLI; any agent that can run shell commands can use it.
The skill only teaches agents the workflow, and it comes in the [Agent Skills](https://agentskills.io/specification) (SKILL.md) format that Claude Code, Codex, pi and several other agents load.

- Claude Code, Codex and pi: `simctlhouse skill install` (Homebrew) or `scripts/install.sh` (source) links the skill into each one it finds.
- Another agent that loads SKILL.md skills: pass `--skills-dir <that agent's skills directory>` to either.
- An agent without skills: add this to the project's `AGENTS.md` (or the agent's own instructions file):

  ```markdown
  ## iOS simulators

  Other agents share this machine's simulators, so never pick one yourself (`booted`, a device name, or one from `xcrun simctl list`).
  Run `UDID=$(simctlhouse acquire --holder "<task>")` before building or testing, and use `-destination "id=$UDID"` and the UDID everywhere.
  Run `simctlhouse renew "$UDID"` during long work and `simctlhouse release "$UDID"` when done, also after failures.
  `simctlhouse --help` has the details.
  ```

Set `SIMCTLHOUSE_HOLDER` in the agent's environment to label its leases without passing `--holder` every time.

## Use a device from a script or agent

```sh
UDID=$(simctlhouse acquire --holder "$TASK_ID")
xcodebuild test -scheme App -destination "id=$UDID"
simctlhouse release "$UDID"
```

Use `--json` to also get the lease ID, and pass it to `release` / `renew` for retry-safe scripts:

```sh
LEASE=$(simctlhouse acquire --family ipad --os 26 --json)
UDID=$(echo "$LEASE" | jq -r .udid)
LEASE_ID=$(echo "$LEASE" | jq -r .leaseId)
simctlhouse renew "$UDID" --lease-id "$LEASE_ID"    # before the lease runs out (30 minutes by default)
simctlhouse release "$UDID" --lease-id "$LEASE_ID"
```

To get the same device back later (for example to keep an installed app), lease it by name or UDID:

```sh
simctlhouse acquire amber-falcon --holder "$TASK_ID"   # exit 5 if someone else holds it
```

## Pick a specific model or OS

```sh
simctlhouse acquire --family ipad                        # latest iPad Pro 11-inch, latest OS
simctlhouse acquire --model "iPhone 17 Pro" --os 26.5
simctlhouse acquire --model com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
```

Model names are matched exactly (case-insensitive) against `xcrun simctl list devicetypes`.

## Change the timeouts

```sh
export SIMCTLHOUSE_LEASE_SECONDS=3600   # 1 hour leases, for long UI suites
export SIMCTLHOUSE_IDLE_SECONDS=0       # shut free devices down right away
```

Values are whole or fractional seconds.
The lease must be more than 0; the idle time may be 0.
A malformed value makes every command fail with exit code 64 instead of falling back to the default.

Each invocation reads its own environment.
The lease length is fixed into each lease when it is acquired or renewed, so agents with different values never disagree about an existing lease.
The idle timeout is applied by whichever invocation runs garbage collection, and by the daemon with the value of the command that started it, so give every agent the same value, for example in your shell profile.

## The background daemon

Expired leases and idle devices are cleaned up on time by a small background daemon, so they never wait for the next command.
You do not need to manage it:

- `acquire`, `release` and `renew` start it when it is not running.
- It sleeps until the next lease expires or a free device's idle time ends, cleans up then, and wakes at once when a command changes the pool.
- It exits on its own once nothing is leased, booted or in progress; with the defaults, about 15 minutes after the last device is released.
- After an upgrade, the next `acquire`, `release` or `renew` replaces it with the new build.

To look at it or control it:

```sh
simctlhouse daemon status     # running or not, since when, pid, version, binary
simctlhouse daemon stop       # stops it until the next acquire, release or renew
simctlhouse daemon start      # starts it now, if anything is leased, booted or in progress; with this command's timeouts
tail ~/.simctlhouse/daemon.log
```

`SIMCTLHOUSE_DAEMON=0` keeps commands from starting it, for CI or a throwaway home; the commands then do the cleanup when they run, as before.
The architecture doc describes how it works.

## Find out who used a device

```sh
simctlhouse history                  # every recorded lease, oldest first
simctlhouse history amber-falcon     # one device; old names and UDIDs work too
simctlhouse history amber-falcon --json
```

Each lease shows when it was acquired and when it ended, the `--holder` label, the PID of the process that ran `acquire` (usually the agent's shell), its working directory, and the outcome:

| Outcome | Meaning |
| --- | --- |
| `active` | Still held |
| `released` | The holder released it |
| `expired` | Not released or renewed within the lease length; the device was re-created under a new name |
| `erased` | `erase --force` wiped it under the lease |
| `deleted` | `delete --force` removed it |
| `vanished` | The simulator disappeared outside simctlhouse |
| `failed` | Creating or booting it failed |
| `abandoned` | The process creating it crashed |
| `runtimeRemoved` | Its iOS runtime was uninstalled, so it could not be re-created |

A device keeps its last 5 leases.
A device that leaves the pool (deleted, vanished, or renamed after an expired lease) is kept for `history`, up to the 50 most recent.

## Inspect and repair

- `simctlhouse list` shows every owned device with status, boot state, holder and time left.
  Filter it like `simctl list devices`: `list booted`, `list leased`, `list shutdown available`, or search terms such as `list "iPhone 17"` or `list <holder>`.
- `simctlhouse history <name|udid>` shows who held a device and how each lease ended.
- `simctlhouse daemon status` and `~/.simctlhouse/daemon.log` show what the daemon did.
- `cat ~/.simctlhouse/state.json` shows the raw registry.
- `simctlhouse gc --json` reclaims expired leases and shuts down every free booted device now, without waiting for the 15-minute idle timeout, and reports what it did.
- A device stuck in `maintenance` or `provisioning` is repaired automatically once the process that left it there has exited, or after an hour if that process hangs.
- A corrupt `state.json` is moved to `state.json.corrupt-<time>` and the pool starts empty, with a warning.
  The simulators it listed are no longer managed; delete them with `xcrun simctl delete <udid>`, taking the UDIDs from that file.
- A `state.json` written by a newer simctlhouse makes every command fail with exit code 1; upgrade this one.
- Start from scratch: `simctlhouse delete --all --force`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | simctl failure, I/O error, or a state file written by a newer simctlhouse |
| 2 | Unknown or unsupported model, or no runtime matches |
| 3 | Device not found (never created by simctlhouse, deleted, or reclaimed after lease expiry) |
| 4 | Lease ID mismatch, or `renew` of a device that is not leased |
| 5 | Device is leased, busy, or used by another process (`acquire <name>`, `delete` / `erase` without `--force`), or was taken over because the command ran for over an hour |
| 6 | `skill install` found no skill next to the binary, or something other than a simctlhouse link is in the way |
| 64 | Invalid command-line usage, or an invalid `SIMCTLHOUSE_*_SECONDS` or `SIMCTLHOUSE_DAEMON` value |

## Run the tests

```sh
swift test                          # unit tests, no simulators needed
swift format lint -r Sources Tests  # lint
```

End-to-end, against real simulators but in an isolated home and with short timeouts.
`SIMCTLHOUSE_DAEMON=0` leaves the cleanup to the commands, so each step shows its effect:

```sh
export SIMCTLHOUSE_HOME=$(mktemp -d) SIMCTLHOUSE_DAEMON=0
B=.build/release/simctlhouse
U=$($B acquire --holder e2e)                       # creates and boots a device (~30s)
SIMCTLHOUSE_LEASE_SECONDS=5 $B acquire --holder short
sleep 6 && $B gc --json                            # reclaims the short lease
$B release "$U" && sleep 2 && SIMCTLHOUSE_IDLE_SECONDS=1 $B list   # idle shutdown, as part of any command
$B acquire "$U" >/dev/null && $B release "$U" && $B gc --json   # gc shuts down free devices right away
$B history                                         # e2e released, short expired
$B delete --all --force
```

With the daemon, the same cleanup happens without any command:

```sh
unset SIMCTLHOUSE_DAEMON
SIMCTLHOUSE_LEASE_SECONDS=60 $B acquire --holder daemon >/dev/null
sleep 90 && cat "$SIMCTLHOUSE_HOME/daemon.log"     # shows the reclaim, with no command run since acquire
$B delete --all --force && $B daemon stop
```

`scripts/smoke-test.sh` checks the daemon end to end on a release tarball.

## Make a release

Releases are an arm64 binary, signed with a Developer ID and notarized, plus the skill, distributed through the `juraj-blahunka/tap` Homebrew tap.

One-time setup on the machine that releases:

- A "Developer ID Application" certificate in the keychain (`security find-identity -v -p codesigning` lists it).
- notarytool credentials: `xcrun notarytool store-credentials notarytool-profile`, with an app-specific password or an App Store Connect API key.
  The profile belongs to the Apple ID, not this project, so other projects on the machine can share it.
  The password prompt hides what you paste; a trailing space (the Passwords app adds one when copying) fails with HTTP 401.
  In CI, set `NOTARY_KEY` (path to the `.p8`), `NOTARY_KEY_ID` and `NOTARY_ISSUER` instead.

For each release, ask your agent to release a version: the `release` skill (`.agents/skills/release/SKILL.md`) runs every step below, checks preconditions first, drafts release notes for you to accept or revise, and asks before publishing anything.
By hand:

1. Bump `version:` in `Sources/simctlhouse/SimctlHouse.swift` and commit.
2. Run `scripts/release.sh 1.4.0`.
   It refuses to run if the version does not match, if the sources have uncommitted changes, or if tag `v1.4.0` exists elsewhere.
   It runs the tests and lint, builds and signs through `scripts/build.sh`, notarizes, checks that Apple published the notarization ticket, packs `dist/simctlhouse-1.4.0-macos.tar.gz`, installs that tarball into a temporary directory to check it, and writes `dist/simctlhouse.rb`.
3. Run `scripts/smoke-test.sh dist/simctlhouse-1.4.0-macos.tar.gz`: in a throwaway home, the shipped binary acquires a real simulator, starts, stops and restarts the daemon, releases the device, waits for the daemon to shut it down and exit on its own, and deletes it; the script checks that no other simulator was touched.
4. Tag the commit `v1.4.0`, push it, and attach the tarball to a GitHub release of that tag.
5. Copy `dist/simctlhouse.rb` to `Formula/simctlhouse.rb` in the tap and push.

`--skip-notarize` and `--allow-dirty` let you try the script without credentials or a commit; never publish such a build.
The tarball is laid out like an install prefix (`bin/`, `share/simctlhouse/skills/simctlhouse`, `LICENSE`), so it also works unpacked into any prefix by hand.

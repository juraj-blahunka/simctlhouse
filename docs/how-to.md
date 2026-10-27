# How-to

## Install

```sh
./install.sh                                   # binary + skill for every agent found
./install.sh --skills-dir ~/.my-agent/skills   # link the skill into a specific skills directory instead
./install.sh --bin-dir ~/bin --no-skill        # custom location, binary only
./install.sh --uninstall                       # remove binary and skill links
```

Requires Xcode with at least one iOS simulator runtime (`xcodebuild -downloadPlatform iOS`).

The script builds a release binary and installs it to `--bin-dir`.
The default is `/usr/local/bin` when writable, otherwise `~/.local/bin`, and it warns if that directory is not on your `PATH`.
It symlinks `skills/simctlhouse` into the skills directory of every agent set up on the machine: `~/.claude/skills` for Claude Code, `~/.codex/skills` for Codex, and `~/.pi/agent/skills` for pi (or `$PI_CODING_AGENT_DIR/skills`).
`--skills-dir` (repeatable) replaces that detection with the directories you name.
Because these are links, every project picks up the skill and edits in this repo take effect immediately.
If something other than a link into this checkout already sits at the link location, the script stops rather than delete it.
Re-running it is safe and is how you upgrade after pulling.
`--uninstall` leaves the simulator pool alone; run `simctlhouse delete --all --force` first to remove it.

## Use it from any agent

simctlhouse itself is a plain CLI; any agent that can run shell commands can use it.
The skill only teaches agents the workflow, and it comes in the [Agent Skills](https://agentskills.io/specification) (SKILL.md) format that Claude Code, Codex, pi and several other agents load.

- Claude Code, Codex and pi: `./install.sh` links the skill automatically.
- Another agent that loads SKILL.md skills: `./install.sh --skills-dir <that agent's skills directory>`.
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
| `expired` | Not released or renewed within the lease length; the device was erased and renamed |
| `erased` | `erase --force` wiped it under the lease |
| `deleted` | `delete --force` removed it |
| `vanished` | The simulator disappeared outside simctlhouse |
| `failed` | Creating or booting it failed |

A device keeps its last 5 leases.
A device that leaves the pool (deleted, vanished, or renamed after an expired lease) is kept for `history`, up to the 50 most recent.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | simctl failure or I/O error |
| 2 | Unknown or unsupported model, or no runtime matches |
| 3 | Device not found (never created by simctlhouse, deleted, or reclaimed after lease expiry) |
| 4 | Lease ID mismatch, or `renew` of a device that is not leased |
| 5 | Device is leased, busy, or used by another process (`acquire <name>`, `delete` / `erase` without `--force`) |
| 64 | Invalid command-line usage, or an invalid `SIMCTLHOUSE_*_SECONDS` value |

## Inspect and repair

- `simctlhouse list` shows every owned device with status, boot state, holder and time left.
  Filter it like `simctl list devices`: `list booted`, `list leased`, `list shutdown available`, or search terms such as `list "iPhone 17"` or `list <holder>`.
- `simctlhouse history <name|udid>` shows who held a device and how each lease ended.
- `cat ~/.simctlhouse/state.json` shows the raw registry.
- `simctlhouse gc --json` reclaims expired leases and shuts down every free booted device now, without waiting for the 15-minute idle timeout, and reports what it did.
- A device stuck in `maintenance` or `provisioning` is repaired automatically 10 minutes after the crash that left it there.
- Start from scratch: `simctlhouse delete --all --force`.

## Run the tests

```sh
swift test                          # unit tests, no simulators needed
swift format lint -r Sources Tests  # lint
```

End-to-end, against real simulators but in an isolated home and with short timeouts:

```sh
export SIMCTLHOUSE_HOME=$(mktemp -d)
B=.build/release/simctlhouse
U=$($B acquire --holder e2e)                       # creates and boots a device (~30s)
SIMCTLHOUSE_LEASE_SECONDS=5 $B acquire --holder short
sleep 6 && $B gc --json                            # reclaims the short lease
$B release "$U" && SIMCTLHOUSE_IDLE_SECONDS=1 $B list   # idle shutdown, as part of any command
$B acquire "$U" >/dev/null && $B release "$U" && $B gc --json   # gc shuts down free devices right away
$B history                                         # e2e released, short expired
$B delete --all --force
```

## Change the timeouts

```sh
export SIMCTLHOUSE_LEASE_SECONDS=3600   # 1 hour leases, for long UI suites
export SIMCTLHOUSE_IDLE_SECONDS=0       # shut free devices down on the next command
```

Values are whole or fractional seconds.
The lease must be more than 0; the idle time may be 0.
A malformed value makes every command fail with exit code 64 instead of falling back to the default.

Each invocation reads its own environment.
The lease length is fixed into each lease when it is acquired or renewed, so agents with different values never disagree about an existing lease.
The idle timeout is applied by whichever invocation runs garbage collection, so give every agent the same value.

## Pick a specific model or OS

```sh
simctlhouse acquire --family ipad                        # latest iPad Pro 11-inch, latest OS
simctlhouse acquire --model "iPhone 17 Pro" --os 26.5
simctlhouse acquire --model com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
```

Model names are matched exactly (case-insensitive) against `xcrun simctl list devicetypes`.

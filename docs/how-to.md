# How-to

## Install

```sh
./install.sh                                   # binary + agent skill
./install.sh --bin-dir ~/bin --no-skill        # custom location, binary only
./install.sh --uninstall                       # remove binary and skill link
```

Requires Xcode with at least one iOS simulator runtime (`xcodebuild -downloadPlatform iOS`).

The script builds a release binary and installs it to `--bin-dir`.
The default is `/usr/local/bin` when writable, otherwise `~/.local/bin`, and it warns if that directory is not on your `PATH`.
It symlinks `.claude/skills/simctlhouse` into `~/.claude/skills` (`--skills-dir` to override), so every Claude Code project picks up the skill and edits in this repo take effect immediately.
If a real directory already sits at the link location, the script stops rather than delete it.
Re-running it is safe and is how you upgrade after pulling.
`--uninstall` leaves the simulator pool alone; run `simctlhouse delete --all --force` first to remove it.

## Use a device from a script or agent

```sh
UDID=$(simctlhouse acquire --holder "$TASK_ID")
xcodebuild test -scheme App -destination "id=$UDID"
simctlhouse release "$UDID"
```

Use `--json` to also get the lease ID, and pass it to `release` / `renew` for retry-safe scripts:

```sh
LEASE=$(simctlhouse acquire --device ipad --os 26 --json)
UDID=$(echo "$LEASE" | jq -r .udid)
LEASE_ID=$(echo "$LEASE" | jq -r .leaseId)
simctlhouse renew "$UDID" --lease-id "$LEASE_ID"    # before 30 minutes pass
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
| `expired` | Not released or renewed within 30 minutes; the device was erased and renamed |
| `reset` | `reset --force` wiped it under the lease |
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
| 5 | Device is leased, busy, or used by another process (`acquire <name>`, `delete` / `reset` without `--force`) |
| 64 | Invalid command-line usage |

## Inspect and repair

- `simctlhouse list` shows every owned device with status, boot state, holder and time left.
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

## Pick a specific model or OS

```sh
simctlhouse acquire --device ipad                        # latest iPad Pro 11-inch, latest OS
simctlhouse acquire --model "iPhone 17 Pro" --os 26.5
simctlhouse acquire --model com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
```

Model names are matched exactly (case-insensitive) against `xcrun simctl list devicetypes`.

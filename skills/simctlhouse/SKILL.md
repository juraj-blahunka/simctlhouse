---
name: simctlhouse
description: Get an exclusive iOS simulator (iPhone or iPad) for building, testing or running an app, and give it back when done. Use whenever you are about to run `xcodebuild test`/`build` or `xcrun simctl` against a simulator, need a simulator destination or UDID, or choose a simulator, so parallel agents never share or fight over one. Use it instead of picking a simulator from `xcrun simctl list`, using "booted", or using `-destination 'name=iPhone ...'`.
---

# simctlhouse: exclusive simulators for agents

Other agents run on this machine at the same time.
If you pick a simulator yourself (by name, `booted`, or from `simctl list`), you will collide with them and get random failures.
Always get your device from simctlhouse: wrap a single test or build command in `simctlhouse run`, or, for several steps on one device, lease it with `acquire`, use it only through its UDID, and release it when done.

## One command does the whole job: `simctlhouse run`

When a single command does everything it needs the device for, such as an end-to-end `xcodebuild test`, wrap it in `simctlhouse run`:

```sh
simctlhouse run --holder "<short task label>" -- xcodebuild test -scheme App
```

It leases a device, boots it, runs the command, and releases the device when the command exits, also when it fails, is interrupted or is killed.
The lease lasts as long as the command, so there is nothing to renew and nothing to forget.

- xcodebuild gets `-destination id=<UDID>` added.
  Do not pass a simulator `-destination` yourself: one naming another simulator (`name=...`, `booted`) is refused with exit code 125.
  `generic/platform=iOS Simulator` is fine.
- A test command other than xcodebuild gets the device through `{udid}` and `{name}` in its arguments, or `$SIMCTLHOUSE_UDID` and `$SIMCTLHOUSE_DEVICE`:

  ```sh
  simctlhouse run -- ./scripts/ui-tests.sh {udid}
  ```

- Device options are those of `acquire` (below): `--family`, `--model`, `--os`, or a device name or UDID.
- `--count N` leases N devices; xcodebuild then tests on all of them at once (add `-parallelize-tests-among-destinations` to split the tests instead).
  Other commands read the space-separated `$SIMCTLHOUSE_UDIDS`.
- `--timeout SECONDS` stops the command after that long, with exit code 124.
- stdout is the command's own; simctlhouse's messages go to stderr, prefixed with `simctlhouse:`.
- If your shell tool times out sooner than the command may take, run it in the background rather than under that timeout.

`run` holds the device only while its one command runs, and hands it back the moment the command exits.
Two `run`s may get two different devices, so never split steps that need the same device (build then install, install then launch, launch then screenshot) across `run`s, and do not chain them into one `run` with `sh -c` either.
Use `acquire` and `release` for those.

## Several steps on one device: acquire and release

When steps must happen on the same device, such as install, launch, screenshot, look, change and repeat, hold the device across them like a lock: acquire it, use it, release it.

1. Acquire a device. stdout is just the UDID; progress messages go to stderr.

   ```sh
   UDID=$(simctlhouse acquire --holder "<short task label>")
   ```

   Options: `--family ipad` (default `iphone`), `--model "iPhone 17 Pro"` (exact name from `xcrun simctl list devicetypes`), `--os 26` or `--os 26.5`.
   Defaults are the latest iPhone Pro or iPad Pro 11-inch on the newest installed iOS.
   The device is booted and ready when the command returns.
   Reusing a free device is quick; when the pool has none, creating and first-booting a new one takes about 30s.
   To get a specific device back (say, one where your app is already installed), pass its name or UDID: `simctlhouse acquire <name|udid> --holder "..."`.

2. Use the UDID everywhere, and never `booted` or a device name:

   ```sh
   xcodebuild test -scheme App -destination "id=$UDID"
   xcrun simctl install "$UDID" path/to/App.app
   xcrun simctl launch "$UDID" com.example.app
   ```

3. Release it as soon as you are done, including after failures:

   ```sh
   simctlhouse release "$UDID"
   ```

## Rules

- Always pass `--holder` with a label that says who you are and what you are doing; `simctlhouse list` and `history` show it to whoever investigates later.
  Without it, the label names your agent process and directory, which says little about the task.
- One lease per task.
  Reuse your UDID for every build and test in the task; do not acquire again for each command.
- A lease from `acquire` expires a fixed time after `acquire` returns or the last renew (`run` needs no renew): 30 minutes by default, or `$SIMCTLHOUSE_LEASE_SECONDS`.
  `acquire` and `renew` print how long you have (`expiresAt` in `--json`).
  An expired device is re-created under a new name and handed to someone else, on time even while you are busy in a long build: the old name and UDID then fail with exit code 3.
  If your work may run longer, run `simctlhouse renew "$UDID"` before each long step, at the latest when two thirds of the lease have passed.
- `acquire`, `release`, `renew` and `run` start a background daemon (`simctlhouse daemon serve`) that enforces lease expiry and idle shutdown on time, and exits on its own once the pool is idle.
  Leave it alone: do not stop, kill or start it, and do not set `SIMCTLHOUSE_DAEMON`.
- Released devices stay booted for the next agent until they have been idle for 15 minutes, and are not erased.
  `release` and `list` say when a free device shuts down (`shutdownAt` in `--json`).
  If you need a pristine device, release it and run `simctlhouse erase <name>`, then acquire again; or uninstall your app first.
- Never `xcrun simctl shutdown/erase/delete` a device yourself, and never touch simulators simctlhouse did not give you.
- For retry-safe scripts, use `--json` and pass the lease ID back:

  ```sh
  simctlhouse acquire --json   # {"udid": ..., "name": ..., "leaseId": ..., "expiresAt": ...}
  simctlhouse release "$UDID" --lease-id "$LEASE_ID"
  ```

## Exit codes of `run`

`run` exits with its command's own code, or 128+N if signal N ended the command.
simctlhouse's own failures use codes commands rarely do:

| Code | Meaning | What to do |
| --- | --- | --- |
| 124 | `--timeout` passed; the command was stopped | Raise the timeout, or find out why the command hangs |
| 125 | simctlhouse failed: no device (stderr names the reason as for `acquire` below), a refused `-destination`, invalid usage, or the lease ended mid-run because someone released or deleted the device | Read stderr; fix the command, or run it again |
| 126 | The command cannot be executed | Fix the command |
| 127 | The command was not found | Fix the command or `PATH` |

## Exit codes of the other commands

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | OK | |
| 2 | Unknown model, or no runtime for that model/OS | Check `xcrun simctl list devicetypes` / `runtimes`, or drop `--model` / `--os` |
| 3 | Device not found | Your lease expired and the device was reclaimed. Acquire a new one; on `release` this is harmless |
| 4 | Lease ID mismatch / not leased | The device is no longer yours. Acquire a new one |
| 5 | Device leased, busy, or used by another process | Pick another device, or use `--force` only on a device you own |
| 1 | simctl failure, or no Xcode selected | Read stderr. If it says Xcode is needed, stop and tell the user; do not run `sudo xcode-select` yourself. Otherwise retry once, then report |
| 64 | Invalid usage or `SIMCTLHOUSE_*` value | Fix the command or the environment variable named in stderr |

## Other commands

Every command that takes a device accepts its name or its UDID.

- `simctlhouse list` shows devices, their status, holder, and what happens next: when a lease expires or a free device shuts down (`--json` available).
  Filter like `simctl list devices`: `list booted`, `list available`, or a search term such as a name, UDID or holder.
- `simctlhouse udid <name>` prints the UDID of a device you know by name.
- `simctlhouse history [<name|udid>]` shows who held a device, when, and how each lease ended (released, expired, vanished, ...).
  Use it when a device disappeared or misbehaved; old names and UDIDs still resolve.
- `simctlhouse renew <udid>` extends an `acquire` lease by a full lease length from now.
- `simctlhouse create [--family ipad]` pre-provisions a free device.
- `simctlhouse erase <name>` wipes a free device's contents and settings.
- `simctlhouse delete <name>` deletes a device.
  Do not run `simctlhouse delete --unused` or `delete --all` unless the user asks: other agents' devices are in the same pool, and freeing disk space is the user's call.
- `simctlhouse gc` reclaims expired leases and shuts down every free booted device now.
- `simctlhouse daemon status` shows whether the daemon runs; its log is `~/.simctlhouse/daemon.log`.
- `simctlhouse skill status` shows where this skill is linked from; `skill install` and `skill uninstall` manage the links for the user.

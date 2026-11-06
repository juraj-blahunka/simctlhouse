---
name: simctlhouse
description: Get an exclusive iOS simulator (iPhone or iPad) for building, testing or running an app, and give it back when done. Use whenever you are about to run `xcodebuild test`/`build` or `xcrun simctl` against a simulator, need a simulator destination or UDID, or choose a simulator, so parallel agents never share or fight over one. Use it instead of picking a simulator from `xcrun simctl list`, using "booted", or using `-destination 'name=iPhone ...'`.
---

# simctlhouse: exclusive simulators for agents

Other agents use this machine's simulators at the same time.
A simulator you pick yourself (by name, `booted`, or from `simctl list`) collides with theirs and fails at random.
Always get your device from simctlhouse, in one of two ways:

- One command does the whole job, such as an end-to-end `xcodebuild test`: wrap it in `simctlhouse run`.
- Several steps must happen on the same device, such as install, launch and screenshot: hold it with `acquire` and `release`.
  Two `run`s may get two different devices, so never split such steps across `run`s, and do not chain them into one `run` with `sh -c`.

## One command: `simctlhouse run`

```sh
simctlhouse run --holder "<short task label>" -- xcodebuild test -scheme App
```

It leases a device, boots it, runs the command, and releases the device when the command exits, also when it fails, is interrupted or is killed.
The lease lasts as long as the command, so there is nothing to renew.

- xcodebuild gets `-destination id=<UDID>` added.
  Do not pass a simulator `-destination` yourself: one naming another simulator (`name=...`, `booted`) is refused with exit code 125.
  `generic/platform=iOS Simulator` is fine.
- Any other command gets the device through `{udid}` and `{name}` in its arguments, or `$SIMCTLHOUSE_UDID` and `$SIMCTLHOUSE_DEVICE_NAME`:

  ```sh
  simctlhouse run -- ./scripts/ui-tests.sh {udid}
  ```

- Device options are those of `acquire` (below): `--family`, `--model`, `--os`, or a device name or UDID.
- `--count N` leases N devices; xcodebuild then tests on all of them at once (add `-parallelize-tests-among-destinations` to split the tests instead).
  Other commands name each device with `{udid0}` to `{udid<N-1>}` (`{udid}` is refused then), or read `$SIMCTLHOUSE_UDID_0` to `$SIMCTLHOUSE_UDID_<N-1>`.
- `--timeout SECONDS` stops the command after that long, with exit code 124.
- stdout is the command's own; simctlhouse's messages go to stderr, prefixed with `simctlhouse:`.
- If your shell tool times out sooner than the command may take, run it in the background rather than under that timeout.

## Several steps: `acquire` and `release`

1. Acquire a device. stdout is just the UDID; progress messages go to stderr.

   ```sh
   UDID=$(simctlhouse acquire --holder "<short task label>")
   ```

   Options: `--family ipad` (default `iphone`), `--model "iPhone 17 Pro"` (exact name from `xcrun simctl list devicetypes`), `--os 26` or `--os 26.5`.
   Defaults are the latest iPhone Pro or iPad Pro 11-inch on the newest installed iOS.
   The device is booted when the command returns: at once for a free device, after about 30s when one has to be created.
   If you only build (`xcodebuild build`, `build-for-testing`) and need no running simulator, add `--skip-boot` to skip that wait.
   To get a specific device back (say, one where your app is already installed), pass its name or UDID: `simctlhouse acquire <name|udid> --holder "..."`.

2. Use the UDID everywhere, never `booted` or a device name:

   ```sh
   xcodebuild test -scheme App -destination "id=$UDID"
   xcrun simctl install "$UDID" path/to/App.app
   xcrun simctl launch "$UDID" com.example.app
   ```

3. Release it as soon as you are done, also after failures:

   ```sh
   simctlhouse release "$UDID"
   ```

## Rules

- Always pass `--holder` with a label that says who you are and what you are doing; `list` and `history` show it to whoever investigates later.
- One lease per task: reuse your UDID for every build and test in it instead of acquiring again for each command.
- A lease from `acquire` expires 30 minutes (or `$SIMCTLHOUSE_LEASE_SECONDS`) after `acquire` returns or the last `renew`; `acquire` and `renew` print how long you have (`expiresAt` in `--json`).
  An expired device is re-created under a new name and handed to someone else, even in the middle of your build; its old name and UDID then fail with exit code 3.
  If your work may run longer, run `simctlhouse renew "$UDID"` before each long step, at the latest when two thirds of the lease have passed.
- Released devices stay booted for the next agent and are not erased.
  For a pristine device, release it, run `simctlhouse erase <name>`, and acquire again; or uninstall your app first.
- Never `xcrun simctl shutdown/erase/delete` a device yourself, and never touch simulators simctlhouse did not give you.
- A background daemon (`simctlhouse daemon serve`) enforces expiry and idle shutdown on time; commands start it and it exits on its own.
  Do not stop, kill or start it, and do not set `SIMCTLHOUSE_DAEMON`.
- Do not run `simctlhouse delete --unused`, `delete --all` or `simctlhouse uninstall` unless the user asks: other agents' devices are in the same pool.
- For retry-safe scripts, take the lease ID from `simctlhouse acquire --json` and pass it back: `simctlhouse release "$UDID" --lease-id "$LEASE_ID"`.

## Exit codes

`run` exits with its command's own code, or 128+N if signal N ended the command.
Its own failures use codes commands rarely do:

| Code | Meaning | What to do |
| --- | --- | --- |
| 124 | `--timeout` passed; the command was stopped | Raise the timeout, or find out why the command hangs |
| 125 | simctlhouse failed: no device (stderr says why, as for `acquire`), a refused `-destination`, invalid usage, or someone released or deleted the device mid-run | Read stderr; fix the command, or run it again |
| 126 | The command cannot be executed | Fix the command |
| 127 | The command was not found | Fix the command or `PATH` |

The other commands:

| Code | Meaning | What to do |
| --- | --- | --- |
| 1 | simctl failure, or no Xcode selected | Read stderr. If it says Xcode is needed, stop and tell the user; do not run `sudo xcode-select` yourself. Otherwise retry once, then report |
| 2 | Unknown model, or no runtime for that model/OS | Check `xcrun simctl list devicetypes` / `runtimes`, or drop `--model` / `--os` |
| 3 | Device not found | Your lease expired and the device was reclaimed. Acquire a new one; on `release` this is harmless |
| 4 | Lease ID mismatch / not leased | The device is no longer yours. Acquire a new one |
| 5 | Device leased, busy, or used by another process | Pick another device, or try again shortly; use `--force` only on a device you hold |
| 64 | Invalid usage or `SIMCTLHOUSE_*` value | Fix the command or the environment variable named in stderr |

## Looking around

Every command that takes a device accepts its name or its UDID.

- `simctlhouse list` shows each device's status, holder, and what happens next: when a lease expires or a free device shuts down (`--json` available).
  Filter like `simctl list devices`: `list booted`, `list available`, or a search term such as a name, UDID or holder.
- `simctlhouse udid <name>` prints the UDID of a device you know by name.
- `simctlhouse history [<name|udid>]` shows who held a device, when, and how each lease ended; use it when a device disappeared or misbehaved.
  Old names and UDIDs still resolve.
- `simctlhouse daemon status` shows whether the daemon runs; its log is `$(simctlhouse home)/daemon.log`.

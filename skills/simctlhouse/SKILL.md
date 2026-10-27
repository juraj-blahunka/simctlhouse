---
name: simctlhouse
description: Get an exclusive iOS simulator (iPhone or iPad) for building, testing or running an app, and give it back when done. Use whenever you are about to run `xcodebuild test`/`build` or `xcrun simctl` against a simulator, need a simulator destination or UDID, or choose a simulator, so parallel agents never share or fight over one. Use it instead of picking a simulator from `xcrun simctl list`, using "booted", or using `-destination 'name=iPhone ...'`.
---

# simctlhouse: exclusive simulators for agents

Other agents run on this machine at the same time.
If you pick a simulator yourself (by name, `booted`, or from `simctl list`), you will collide with them and get random failures.
Always lease a device from simctlhouse, use it only through its UDID, and release it when done.

## Workflow

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

- Always pass `--holder` with a label that says who you are and what you are doing; `simctlhouse history` shows it to whoever investigates later.
- One lease per task.
  Reuse your UDID for every build and test in the task; do not acquire again for each command.
- Leases expire a fixed time after acquire or the last renew: 30 minutes by default, or `$SIMCTLHOUSE_LEASE_SECONDS`.
  `acquire` and `renew` print how long you have (`expiresAt` in `--json`).
  An expired device is erased and handed to someone else.
  If your work may run longer, run `simctlhouse renew "$UDID"` before each long step, at the latest when two thirds of the lease have passed.
- Released devices stay booted and are not erased.
  If you need a pristine device, release it and run `simctlhouse erase <name>`, then acquire again; or uninstall your app first.
- Never `xcrun simctl shutdown/erase/delete` a device yourself, and never touch simulators simctlhouse did not give you.
- For retry-safe scripts, use `--json` and pass the lease ID back:

  ```sh
  simctlhouse acquire --json   # {"udid": ..., "name": ..., "leaseId": ..., "expiresAt": ...}
  simctlhouse release "$UDID" --lease-id "$LEASE_ID"
  ```

## Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | OK | |
| 2 | Unknown model, or no runtime for that model/OS | Check `xcrun simctl list devicetypes` / `runtimes`, or drop `--model` / `--os` |
| 3 | Device not found | Your lease expired and the device was reclaimed. Acquire a new one; on `release` this is harmless |
| 4 | Lease ID mismatch / not leased | The device is no longer yours. Acquire a new one |
| 5 | Device leased, busy, or used by another process | Pick another device, or use `--force` only on a device you own |
| 1 | simctl failure | Read stderr; retry once, then report |

## Other commands

Every command that takes a device accepts its name or its UDID.

- `simctlhouse list [<name|udid>...]` shows devices, their status, holder and time left (`--json` available).
- `simctlhouse udid <name>` prints the UDID of a device you know by name.
- `simctlhouse history [<name|udid>]` shows who held a device, when, and how each lease ended (released, expired, vanished, ...).
  Use it when a device disappeared or misbehaved; old names and UDIDs still resolve.
- `simctlhouse renew <udid>` extends your lease by a full lease length from now.
- `simctlhouse create [--family ipad]` pre-provisions a free device.
- `simctlhouse erase <name>` wipes a free device's contents and settings.
- `simctlhouse delete <name>` deletes a device.
- `simctlhouse gc` reclaims expired leases and shuts down every free booted device now.

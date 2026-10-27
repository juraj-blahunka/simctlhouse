# simctlhouse

**Device Hub for Agents.**

When several AI agents build and test iOS apps on one Mac, they tend to grab the same simulator.
The runs then fight over it and fail at random.
simctlhouse gives every agent its own simulator from a shared pool, with an exclusive lease, and cleans up after agents that forget.

```sh
UDID=$(simctlhouse acquire)                       # lease + boot a free iPhone, print its UDID
xcodebuild test -scheme App -destination "id=$UDID"
simctlhouse release "$UDID"                       # back to the pool, still booted for the next agent
```

## What it does

- **Exclusive leases.** A device is handed to one agent at a time.
- **Pooling.** Released devices are reused, still booted, by the next agent asking for the same model and OS.
- **Plain simulators.** Devices are ordinary simulators made with `simctl create`, visible in Xcode.
  A new device's first boot takes about 25s, a reused one is ready immediately.
- **Audit trail.** Each device remembers its last 5 holders with acquire and release times, and devices that left the pool stay queryable.
- **Automatic reclaim.** A lease not released or renewed within 30 minutes is erased and returned to the pool.
- **Idle shutdown.** Free devices shut down after 15 minutes of inactivity, or right away with `simctlhouse gc`.
- **Hands off your simulators.** simctlhouse only touches devices it created, and skips any device it sees another process using.

## Commands

| Command | Purpose |
| --- | --- |
| `acquire [--device iphone\|ipad] [--model NAME] [--os VERSION] [--holder LABEL] [--json]` | Lease a free matching device or create one, boot it, print the UDID |
| `acquire <name\|udid> [--holder LABEL] [--json]` | Lease that specific free device |
| `release <name\|udid> [--lease-id ID]` | Return a device to the pool |
| `renew <name\|udid> [--lease-id ID]` | Extend a lease by 30 minutes from now |
| `list [<name\|udid>...] [--json]` | Show all simctlhouse devices, or only the given ones |
| `history [<name\|udid>] [--json]` | Show who held devices, when, and how each lease ended |
| `create [--device] [--model] [--os]` | Add a free device to the pool ahead of time |
| `reset <name\|udid> [--force]` | Erase a device (keeps the name, new UDID) |
| `delete <name\|udid>... \| --all [--force]` | Delete devices |
| `gc [--json]` | Reclaim expired leases and shut down every free booted device now |

Defaults: iPhone, the latest `iPhone N Pro`, or the latest `iPad Pro 11-inch` with `--device ipad`, on the newest installed iOS runtime that supports it.
Devices are named with two random words, such as `amber-falcon`.
Every command that takes a device accepts its name or its UDID.

## Install

```sh
./install.sh
```

This builds a release binary and installs it to `/usr/local/bin` (or `~/.local/bin` if that is not writable).
It also links the agent skill into `~/.claude/skills`, so it updates whenever you pull.
Run `./install.sh --help` for options, including `--uninstall`.

## Docs

- [How-to](docs/how-to.md): usage recipes, exit codes, testing, repair
- [Architecture](docs/architecture.md): state, locking, lifecycle, GC
- [Decisions](docs/decisions.md): what we chose and why

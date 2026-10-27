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
- **Automatic reclaim.** A lease not released or renewed within 30 minutes (configurable) is erased and returned to the pool.
- **Idle shutdown.** Free devices shut down after 15 minutes of inactivity (configurable), or right away with `simctlhouse gc`.
- **Hands off your simulators.** simctlhouse only touches devices it created, and skips any device it sees another process using.

## Commands

| Command | Purpose |
| --- | --- |
| `acquire [--family iphone\|ipad] [--model NAME] [--os VERSION] [--holder LABEL] [--json]` | Lease a free matching device or create one, boot it, print the UDID |
| `acquire <name\|udid> [--holder LABEL] [--json]` | Lease that specific free device |
| `release <name\|udid> [--lease-id ID]` | Return a device to the pool |
| `renew <name\|udid> [--lease-id ID]` | Extend a lease by a full lease length from now |
| `list [booted\|leased\|<search term>...] [--json]` | Show devices, filtered like `simctl list devices` |
| `udid <name\|udid>` | Print a device's UDID |
| `history [<name\|udid>] [--json]` | Show who held devices, when, and how each lease ended |
| `create [--family] [--model] [--os]` | Add a free device to the pool ahead of time |
| `erase <name\|udid> [--force]` | Erase a device's contents and settings (keeps the name and UDID) |
| `delete <name\|udid>... \| --all [--force]` | Delete devices |
| `gc [--json]` | Reclaim expired leases and shut down every free booted device now |
| `skill install\|uninstall\|status [--skills-dir DIR]...` | Link the agent skill shipped with a release into your coding agents |

Defaults: iPhone, the latest `iPhone N Pro`, or the latest `iPad Pro 11-inch` with `--family ipad`, on the newest installed iOS runtime that supports it.
Devices are named with two random words, such as `amber-falcon`.
Every command that takes a device accepts its name or its UDID.
`--json` has the short form `-j`, as in `simctl list -j`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `SIMCTLHOUSE_LEASE_SECONDS` | `1800` | Lease length; a lease not renewed within it is reclaimed |
| `SIMCTLHOUSE_IDLE_SECONDS` | `900` | How long a free booted device may sit idle before it is shut down; `0` shuts it down on the next command |
| `SIMCTLHOUSE_HOLDER` | | Default `--holder` label |
| `SIMCTLHOUSE_HOME` | `~/.simctlhouse` | Where the pool's state lives |

Set them where your agents run, for example in your shell profile, so every simctlhouse invocation sees the same values.

## Install

```sh
scripts/install.sh
```

This builds the binary exactly as a release does (Apple silicon only) and installs it to `/usr/local/bin` (or `~/.local/bin` if that is not writable).
It also links the agent skill (`skills/simctlhouse/SKILL.md`) into every coding agent it finds (Claude Code, Codex and pi), so it updates whenever you pull.
Other agents work too: pass `--skills-dir` for any agent that loads SKILL.md skills, or add a few lines to your project's `AGENTS.md` (see the [how-to](docs/how-to.md#use-it-from-any-agent)).
Run `scripts/install.sh --help` for options, including `--uninstall`.

A release installs the skill next to the binary instead, in `<prefix>/share/simctlhouse/skills`.
Run `simctlhouse skill install` once to link it into your agents; upgrades of the package then update the skill too.

## Docs

- [How-to](docs/how-to.md): usage recipes, exit codes, testing, repair
- [Architecture](docs/architecture.md): state, locking, lifecycle, GC
- [Decisions](docs/decisions.md): what we chose and why

## License

MIT, see [LICENSE](LICENSE).

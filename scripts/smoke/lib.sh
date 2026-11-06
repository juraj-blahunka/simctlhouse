# Helpers for the smoke tests in this directory; scripts/smoke-test.sh sets `bin`, `SIMCTLHOUSE_HOME` and the rest.
# shellcheck shell=bash
set -euo pipefail

: "${bin:?run the smoke tests through scripts/smoke-test.sh}"

fail() { echo "error: $*" >&2; exit 1; }
note() { printf '    %s\n' "$*"; }
udids() { xcrun simctl list devices -j | sed -nE 's/.*"udid" : "([^"]+)".*/\1/p' | sort; }
daemon_running() { [[ "$("$bin" daemon status --json)" == *'"running" : true'* ]]; }
daemon_pid() { "$bin" daemon status --json | sed -nE 's/.*"pid" : ([0-9]+).*/\1/p'; }
kept_alive() { [[ "$("$bin" daemon status --json)" == *'"keepAliveUntil"'* ]]; }
shut_down() { xcrun simctl list devices | /usr/bin/grep -F "$1" | /usr/bin/grep -qF "(Shutdown)"; }
# Counts the lines of $1 that are not empty, so an empty list counts as 0.
count() { /usr/bin/grep -c . <<<"$1" || true; }
pool_size() { count "$("$bin" list --json 2>/dev/null | /usr/bin/grep '"name" :')"; }
leased() { "$bin" list leased 2>/dev/null; }
# How many leases `history` shows as released for device $1.
released_count() { "$bin" history "$1" | /usr/bin/grep -c "released" || true; }
# Waits up to $1 seconds for the daemon to start.
wait_for_daemon() { for _ in $(seq $(($1 * 2))); do daemon_running && return 0 || sleep 0.5; done; daemon_running; }
# Waits up to $1 seconds for the daemon to exit on its own.
wait_for_daemon_exit() { for _ in $(seq $(($1 * 2))); do daemon_running && sleep 0.5 || return 0; done; ! daemon_running; }

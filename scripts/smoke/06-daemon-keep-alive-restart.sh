#!/usr/bin/env bash
# daemon start --keep-alive restarts a running daemon to keep it alive longer.
source "$(dirname "$0")/lib.sh"

udid="$("$bin" acquire --skip-boot --holder smoke-daemon)"
wait_for_daemon 10 || fail "acquire did not start the daemon within 10 seconds."
pid="$(daemon_pid)"
"$bin" daemon start --keep-alive 5
daemon_running || fail "daemon start --keep-alive did not leave a daemon running."
[[ "$(daemon_pid)" != "$pid" ]] || fail "daemon start --keep-alive did not restart the daemon."
kept_alive || fail "daemon start --keep-alive started a daemon without a keep-alive."
"$bin" daemon status | /usr/bin/grep -q "^Kept alive until" || fail "daemon status does not show the keep-alive."
"$bin" release "$udid"

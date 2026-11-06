#!/usr/bin/env bash
# daemon stop stops the daemon, and daemon start --keep-alive 0 starts one without a keep-alive.
source "$(dirname "$0")/lib.sh"

udid="$("$bin" acquire --skip-boot --holder smoke-daemon)"
wait_for_daemon 10 || fail "acquire did not start the daemon within 10 seconds."
"$bin" daemon stop
! daemon_running || fail "daemon stop left the daemon running."
"$bin" daemon start --keep-alive 0
daemon_running || fail "daemon start did not start the daemon."
! kept_alive || fail "daemon start --keep-alive 0 started a daemon with a keep-alive."
"$bin" release "$udid"

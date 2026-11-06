#!/usr/bin/env bash
# With nothing to watch, daemon start needs a keep-alive to run, and stops once it passes.
source "$(dirname "$0")/lib.sh"

"$bin" delete --all --force
wait_for_daemon_exit 30 || fail "the daemon did not stop on its own within 30 seconds of deleting the pool."
"$bin" daemon start --keep-alive 0 2>/dev/null
! daemon_running || fail "daemon start --keep-alive 0 started a daemon with nothing to watch."
"$bin" daemon start --keep-alive 3
daemon_running || fail "daemon start --keep-alive 3 did not start the daemon with nothing to watch."
wait_for_daemon_exit 15 || fail "the daemon did not stop on its own within 15 seconds after its 3 second keep-alive."

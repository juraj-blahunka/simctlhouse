#!/usr/bin/env bash
# daemon serve keeps the daemon alive by default.
source "$(dirname "$0")/lib.sh"

"$bin" daemon serve 2>/dev/null &
wait_for_daemon 10 || fail "daemon serve did not start the daemon within 10 seconds."
kept_alive || fail "daemon serve does not keep the daemon alive by default."
"$bin" daemon stop
wait

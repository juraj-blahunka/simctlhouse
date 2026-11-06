#!/usr/bin/env bash
# daemon start keeps the daemon alive by default.
source "$(dirname "$0")/lib.sh"

"$bin" daemon start
"$bin" daemon status | /usr/bin/grep -q "^Kept alive until" || fail "daemon start does not keep the daemon alive by default."
"$bin" daemon stop

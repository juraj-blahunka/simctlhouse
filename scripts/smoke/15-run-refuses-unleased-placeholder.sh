#!/usr/bin/env bash
# run refuses a placeholder for a device it would not lease with 125, before leasing anything.
source "$(dirname "$0")/lib.sh"

size="$(pool_size)"
status=0
"$bin" run --holder smoke-refused -- echo {udid1} 2>/dev/null || status=$?
[[ $status -eq 125 ]] || fail "run -- echo {udid1} exited with $status instead of 125."
status=0
"$bin" run --count 2 --holder smoke-refused -- echo {udid} 2>/dev/null || status=$?
[[ $status -eq 125 ]] || fail "run --count 2 -- echo {udid} exited with $status instead of 125."
! "$bin" history 2>/dev/null | /usr/bin/grep -q "smoke-refused" || fail "run leased a device for a command it refused."
[[ "$(pool_size)" -eq "$size" ]] || fail "run created a device for a command it refused."

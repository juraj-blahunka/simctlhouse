#!/usr/bin/env bash
# run of a command that does not exist exits with 127 and releases its device.
source "$(dirname "$0")/lib.sh"

status=0
"$bin" run --skip-boot -- simctlhouse-smoke-no-such-command 2>/dev/null || status=$?
[[ $status -eq 127 ]] || fail "run of a missing command exited with $status instead of 127."
[[ -z "$(leased)" ]] || fail "run left a device leased:"$'\n'"$(leased)"

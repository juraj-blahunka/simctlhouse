#!/usr/bin/env bash
# run releases its device when the command exits, and history records the lease as released.
source "$(dirname "$0")/lib.sh"

udid="$("$bin" run --skip-boot --holder smoke-run-release -- echo {udid})"
[[ -z "$(leased)" ]] || fail "run left a device leased:"$'\n'"$(leased)"
"$bin" history "$udid" | /usr/bin/grep -q "released *smoke-run-release" || fail "history does not show the run's lease as released."

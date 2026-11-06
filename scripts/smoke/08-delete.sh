#!/usr/bin/env bash
# delete --all --force deletes the pool's simulators.
source "$(dirname "$0")/lib.sh"

udid="$("$bin" acquire --skip-boot --holder smoke-delete)"
"$bin" release "$udid"
"$bin" delete --all --force
! udids | /usr/bin/grep -qxF "$udid" || fail "deleted device $udid still exists."
[[ "$(pool_size)" -eq 0 ]] || fail "delete --all left devices in the pool:"$'\n'"$("$bin" list 2>&1)"

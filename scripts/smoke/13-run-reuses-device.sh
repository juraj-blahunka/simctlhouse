#!/usr/bin/env bash
# A second run reuses the device the first one released instead of creating another.
source "$(dirname "$0")/lib.sh"

first="$("$bin" run --holder smoke-run -- echo {udid})"
size="$(pool_size)"
wait_for_daemon_exit 30 || fail "the daemon did not stop on its own within 30 seconds of the release."
second="$("$bin" run --holder smoke-run -- echo {udid})"
[[ "$second" == "$first" ]] || fail "the second run got $second instead of reusing $first."
[[ "$(pool_size)" -eq "$size" ]] || fail "the second run created another device:"$'\n'"$("$bin" list 2>&1)"

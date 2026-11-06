#!/usr/bin/env bash
# run without --skip-boot creates a device and boots it before the command starts (a first boot; about 30 seconds).
source "$(dirname "$0")/lib.sh"

"$bin" delete --all --force
wait_for_daemon_exit 30 || fail "the daemon did not stop on its own within 30 seconds of deleting the pool."
state="$("$bin" run --holder smoke-run-boot -- sh -c 'xcrun simctl list devices | /usr/bin/grep -F {udid}')"
[[ "$state" == *"(Booted)"* ]] || fail "run did not boot the device it created; while the command ran, simctl listed: $state"
[[ "$(pool_size)" -eq 1 ]] || fail "run did not create exactly one device:"$'\n'"$("$bin" list 2>&1)"

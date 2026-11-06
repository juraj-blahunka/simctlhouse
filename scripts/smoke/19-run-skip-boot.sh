#!/usr/bin/env bash
# run --skip-boot hands the command a device without booting it.
source "$(dirname "$0")/lib.sh"

state="$("$bin" run --skip-boot --holder smoke-run-skip-boot -- sh -c 'xcrun simctl list devices | /usr/bin/grep -F {udid}')"
[[ "$state" == *"(Shutdown)"* ]] || fail "run --skip-boot booted the device; while the command ran, simctl listed: $state"

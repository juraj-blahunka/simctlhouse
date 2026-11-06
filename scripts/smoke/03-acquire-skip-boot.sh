#!/usr/bin/env bash
# acquire --skip-boot leases a device and leaves it shut down.
source "$(dirname "$0")/lib.sh"

udid="$("$bin" acquire --skip-boot --holder smoke-acquire)"
[[ -n "$udid" ]] || fail "acquire printed no UDID."
shut_down "$udid" || fail "acquire --skip-boot booted device $udid."
leased | /usr/bin/grep -qF "$udid" || fail "list does not show $udid as leased."
"$bin" release "$udid"

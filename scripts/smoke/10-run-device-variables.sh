#!/usr/bin/env bash
# run hands the command its device through variables and placeholders.
source "$(dirname "$0")/lib.sh"

out="$("$bin" run --holder smoke-run -- sh -c \
    'echo "$SIMCTLHOUSE_UDID $SIMCTLHOUSE_UDID_0 $SIMCTLHOUSE_UDIDS {udid} {udid0} $SIMCTLHOUSE_DEVICE_NAME {name} {name0}"')"
read -r udid udid0 udids arg arg0 name name_arg name_arg0 <<<"$out"
[[ -n "$udid" && "$udid" == "$udid0" && "$udid" == "$udids" && "$udid" == "$arg" && "$udid" == "$arg0" ]] ||
    fail "run gave the command '$out' instead of its UDID five times."
[[ -n "$name" && "$name" == "$name_arg" && "$name" == "$name_arg0" ]] || fail "run gave the command '$out' instead of its name three times."
"$bin" list | /usr/bin/grep -F "$udid" | /usr/bin/grep -qF "$name" || fail "the run's device is not $name ($udid) in list."

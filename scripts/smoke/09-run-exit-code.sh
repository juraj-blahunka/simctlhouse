#!/usr/bin/env bash
# run passes the command's exit code through (the first run boots a device; about 30 seconds).
source "$(dirname "$0")/lib.sh"

status=0
"$bin" run --holder smoke-run -- sh -c 'exit 7' || status=$?
[[ $status -eq 7 ]] || fail "run did not pass the command's exit code 7 through (got $status)."

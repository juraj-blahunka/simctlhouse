#!/usr/bin/env bash
# run passes the command's exit code through.
source "$(dirname "$0")/lib.sh"

status=0
"$bin" run --skip-boot --holder smoke-run -- sh -c 'exit 7' || status=$?
[[ $status -eq 7 ]] || fail "run did not pass the command's exit code 7 through (got $status)."

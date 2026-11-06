#!/usr/bin/env bash
# Once the last lease is released, the daemon stops on its own.
source "$(dirname "$0")/lib.sh"

udid="$("$bin" acquire --skip-boot --holder smoke-daemon)"
wait_for_daemon 10 || fail "acquire did not start the daemon within 10 seconds."
"$bin" release "$udid"
wait_for_daemon_exit 30 || fail "the daemon did not stop on its own within 30 seconds of the release."

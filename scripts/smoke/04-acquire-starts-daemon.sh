#!/usr/bin/env bash
# acquire starts a daemon running this build, without a keep-alive.
source "$(dirname "$0")/lib.sh"

! daemon_running || fail "a daemon was already running before acquire."
udid="$("$bin" acquire --skip-boot --holder smoke-daemon)"
# acquire starts it in the background without waiting for it.
wait_for_daemon 10 || fail "acquire did not start the daemon within 10 seconds."
[[ "$("$bin" daemon status --json)" == *'"isCurrentBuild" : true'* ]] || fail "the daemon does not run this binary."
! kept_alive || fail "the daemon acquire started has a keep-alive."
"$bin" release "$udid"

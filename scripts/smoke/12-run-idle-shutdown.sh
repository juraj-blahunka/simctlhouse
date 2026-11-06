#!/usr/bin/env bash
# The daemon shuts down a device a run released, then stops on its own.
source "$(dirname "$0")/lib.sh"

udid="$("$bin" run --holder smoke-run -- echo {udid})"
# The daemon exits only once nothing is in progress, so the device is free again rather than mid-shutdown.
wait_for_daemon_exit 30 || fail "the daemon did not stop on its own within 30 seconds of the release."
shut_down "$udid" || fail "the daemon stopped but left released device $udid booted."

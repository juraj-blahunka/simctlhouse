#!/usr/bin/env bash
# Runs a release tarball end to end against real simulators, the way a user would after `brew install`:
# link the skill, acquire a device, check the daemon, release it, delete the pool, wrap a command in `run`,
# and check that no other simulator was touched.
# Everything runs in throwaway directories (SIMCTLHOUSE_HOME and the skills directory), never in your own setup.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/smoke-test.sh TARBALL [VERSION]

  TARBALL   A release tarball, e.g. dist/simctlhouse-1.4.0-macos.tar.gz.
  VERSION   The version the binary must report. Default: taken from the tarball name.

Needs an installed iOS simulator runtime. A first boot takes about 30 seconds.
EOF
}

[[ $# -ge 1 && "$1" != -* ]] || { usage >&2; exit 64; }
tarball="$1"
version="${2:-$(basename "$tarball" | sed -nE 's/^simctlhouse-([0-9]+\.[0-9]+\.[0-9]+)-macos\.tar\.gz$/\1/p')}"
[[ -n "$version" ]] || { echo "error: cannot tell the version from $tarball; pass it." >&2; exit 64; }

step() { printf '==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }
udids() { xcrun simctl list devices -j | sed -nE 's/.*"udid" : "([^"]+)".*/\1/p' | sort; }
daemon_running() { [[ "$("$bin" daemon status --json)" == *'"running" : true'* ]]; }
daemon_pid() { "$bin" daemon status --json | sed -nE 's/.*"pid" : ([0-9]+).*/\1/p'; }
kept_alive() { [[ "$("$bin" daemon status --json)" == *'"keepAliveUntil"'* ]]; }
# Waits up to $1 seconds for the daemon to exit on its own.
wait_for_daemon_exit() { for _ in $(seq $(($1 * 2))); do daemon_running && sleep 0.5 || return 0; done; ! daemon_running; }

work="$(mktemp -d)"
export SIMCTLHOUSE_HOME="$work/home"
# Free devices shut down after 1s, so the daemon stops on its own right after the release instead of 15 minutes later.
export SIMCTLHOUSE_IDLE_SECONDS=1
bin=""
cleanup() {
    # Leave no pool device behind, even when a check failed halfway.
    [[ -n "$bin" && -x "$bin" ]] && "$bin" delete --all --force >/dev/null 2>&1 || true
    [[ -n "$bin" && -x "$bin" ]] && "$bin" daemon stop >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

step "Unpacking $(basename "$tarball")"
tar -C "$work" -xzf "$tarball"
found=("$work"/simctlhouse-*/bin/simctlhouse)
[[ ${#found[@]} -eq 1 && -x "${found[0]}" ]] || fail "the tarball has no simctlhouse-<version>/bin/simctlhouse."
bin="${found[0]}"
reported="$("$bin" --version)"
[[ "$reported" == "$version" ]] || fail "the binary reports version $reported, not $version."
codesign --verify --strict "$bin"

step "Linking the skill"
"$bin" skill install --skills-dir "$work/skills" >/dev/null 2>&1
[[ "$("$bin" skill status --skills-dir "$work/skills" --json)" == *'"status" : "linked"'* ]] ||
    fail "skill status does not report the link as linked."
[[ -f "$work/skills/simctlhouse/SKILL.md" ]] || fail "the linked skill has no SKILL.md."

before="$(udids)"

step "Acquiring a device (creates and boots one; about 30 seconds)"
udid="$("$bin" acquire --holder smoke-test)"
[[ -n "$udid" ]] || fail "acquire printed no UDID."
xcrun simctl list devices booted | /usr/bin/grep -qF "$udid" || fail "acquired device $udid is not booted."
"$bin" list leased | /usr/bin/grep -qF "$udid" || fail "list does not show $udid as leased."

step "Checking the daemon acquire started"
# acquire starts it in the background without waiting for it.
for _ in {1..20}; do daemon_running && break || sleep 0.5; done
daemon_running || fail "acquire did not start the daemon within 10 seconds."
[[ "$("$bin" daemon status --json)" == *'"isCurrentBuild" : true'* ]] || fail "the daemon does not run this binary."
! kept_alive || fail "the daemon acquire started has a keep-alive."
"$bin" daemon stop
! daemon_running || fail "daemon stop left the daemon running."
"$bin" daemon start --keep-alive 0
daemon_running || fail "daemon start did not start the daemon."
! kept_alive || fail "daemon start --keep-alive 0 started a daemon with a keep-alive."

step "Restarting the daemon to keep it alive for 5 seconds"
pid="$(daemon_pid)"
"$bin" daemon start --keep-alive 5
daemon_running || fail "daemon start --keep-alive did not leave a daemon running."
[[ "$(daemon_pid)" != "$pid" ]] || fail "daemon start --keep-alive did not restart the daemon."
kept_alive || fail "daemon start --keep-alive started a daemon without a keep-alive."
"$bin" daemon status | /usr/bin/grep -q "^Kept alive until" || fail "daemon status does not show the keep-alive."

step "Releasing it; the daemon shuts it down and stops on its own"
"$bin" release "$udid"
wait_for_daemon_exit 30 || fail "the daemon did not stop on its own within 30 seconds of the release."
xcrun simctl list devices | /usr/bin/grep -F "$udid" | /usr/bin/grep -qF "(Shutdown)" ||
    fail "the daemon stopped but left released device $udid booted."

step "Deleting it"
"$bin" delete --all --force
! udids | /usr/bin/grep -qxF "$udid" || fail "deleted device $udid still exists."

step "Running a command on a leased device with run (creates and boots one; about 30 seconds)"
status=0
out="$("$bin" run --holder smoke-run -- sh -c 'echo "$SIMCTLHOUSE_UDID {udid}"; exit 7')" || status=$?
[[ $status -eq 7 ]] || fail "run did not pass the command's exit code 7 through (got $status)."
read -r run_udid run_arg <<<"$out"
[[ -n "$run_udid" && "$run_udid" == "$run_arg" ]] || fail "run gave the command '$out' instead of its UDID twice."
[[ -z "$("$bin" list leased 2>/dev/null)" ]] || fail "run left a device leased."
"$bin" history "$run_udid" | /usr/bin/grep -q "released *smoke-run" || fail "history does not show the run's lease as released."
status=0
"$bin" run -- simctlhouse-smoke-no-such-command 2>/dev/null || status=$?
[[ $status -eq 127 ]] || fail "run of a missing command exited with $status instead of 127."
"$bin" delete --all --force
wait_for_daemon_exit 30 || fail "the daemon did not stop on its own within 30 seconds of deleting the pool."

step "Keeping a daemon alive with nothing to watch"
"$bin" daemon start --keep-alive 0 2>/dev/null
! daemon_running || fail "daemon start --keep-alive 0 started a daemon with nothing to watch."
"$bin" daemon start --keep-alive 3
daemon_running || fail "daemon start --keep-alive 3 did not start the daemon with nothing to watch."
wait_for_daemon_exit 15 || fail "the daemon did not stop on its own within 15 seconds after its 3 second keep-alive."
"$bin" daemon start
"$bin" daemon status | /usr/bin/grep -q "^Kept alive until" || fail "daemon start does not keep the daemon alive by default."
"$bin" daemon stop
"$bin" daemon serve 2>/dev/null &
for _ in {1..20}; do daemon_running && break || sleep 0.5; done
kept_alive || fail "daemon serve does not keep the daemon alive by default."
"$bin" daemon stop
wait

# Every simulator that existed before must still exist. Other agents on this machine may delete their own devices
# meanwhile; a failure lists the missing UDIDs so you can tell whether this run touched them.
missing="$(comm -23 <(echo "$before") <(udids))"
[[ -z "$missing" ]] || fail "simulators that existed before the run are gone:"$'\n'"$missing"

step "Smoke test passed for simctlhouse $version"

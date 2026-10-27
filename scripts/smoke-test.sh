#!/usr/bin/env bash
# Runs a release tarball end to end against real simulators, the way a user would after `brew install`:
# link the skill, acquire a device, release it, delete the pool, and check that no other simulator was touched.
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

work="$(mktemp -d)"
export SIMCTLHOUSE_HOME="$work/home"
bin=""
cleanup() {
    # Leave no pool device behind, even when a check failed halfway.
    [[ -n "$bin" && -x "$bin" ]] && "$bin" delete --all --force >/dev/null 2>&1 || true
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

step "Releasing and deleting it"
"$bin" release "$udid"
"$bin" delete --all --force
! udids | /usr/bin/grep -qxF "$udid" || fail "deleted device $udid still exists."

# Every simulator that existed before must still exist. Other agents on this machine may delete their own devices
# meanwhile; a failure lists the missing UDIDs so you can tell whether this run touched them.
missing="$(comm -23 <(echo "$before") <(udids))"
[[ -z "$missing" ]] || fail "simulators that existed before the run are gone:"$'\n'"$missing"

step "Smoke test passed for simctlhouse $version"

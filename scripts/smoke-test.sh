#!/usr/bin/env bash
# Runs a release tarball end to end against real simulators, the way a user would after `brew install`.
# Each script in scripts/smoke checks one thing; they run in order against one throwaway pool, so later ones reuse
# the device an earlier one created instead of creating their own. Tests whose command needs no running simulator pass
# --skip-boot to run and acquire; only those that check booting boot.
# Between scripts, nothing may be left leased and the daemon must stop on its own, so each starts from a pool of free,
# shut down devices and no daemon, and can also run alone.
# Afterwards, no other simulator may have been touched and the number of simulators must be unchanged.
# Everything runs in throwaway directories (SIMCTLHOUSE_HOME and the skills directory), never in your own setup.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/smoke-test.sh TARBALL [--version VERSION] [TEST...]

  TARBALL            A release tarball, e.g. dist/simctlhouse-1.4.0-macos.tar.gz.
  --version VERSION  The version the binary must report. Default: taken from the tarball name.
  TEST               Run only these tests from scripts/smoke, by name or part of it (run-reuses-device, 13).
                     Default: all of them.

Needs an installed iOS simulator runtime. A first boot takes about 30 seconds.
EOF
}

[[ $# -ge 1 && "$1" != -* ]] || { usage >&2; exit 64; }
tarball="$1"
shift
version=""
names=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; version="$2"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; exit 64 ;;
        *) names+=("$1"); shift ;;
    esac
done
version="${version:-$(basename "$tarball" | sed -nE 's/^simctlhouse-([0-9]+\.[0-9]+\.[0-9]+)-macos\.tar\.gz$/\1/p')}"
[[ -n "$version" ]] || { echo "error: cannot tell the version from $tarball; pass --version." >&2; exit 64; }

dir="$(cd "$(dirname "$0")/smoke" && pwd)"
tests=()
if [[ ${#names[@]} -eq 0 ]]; then
    tests=("$dir"/[0-9][0-9]-*.sh)
else
    for name in "${names[@]}"; do
        found=()
        for test in "$dir"/[0-9][0-9]-*.sh; do [[ "$(basename "$test")" == *"$name"* ]] && found+=("$test"); done
        [[ ${#found[@]} -eq 1 ]] || { echo "error: '$name' matches ${#found[@]} tests in scripts/smoke, not one." >&2; exit 64; }
        tests+=("${found[0]}")
    done
fi

work="$(mktemp -d)"
export SIMCTLHOUSE_HOME="$work/home" SMOKE_WORK="$work" SMOKE_VERSION="$version"
# Free devices shut down after 1s, so the daemon stops on its own right after a release instead of 15 minutes later.
export SIMCTLHOUSE_IDLE_SECONDS=1
bin=""
cleanup() {
    # Leave no pool device behind, even when a check failed halfway.
    [[ -n "$bin" && -x "$bin" ]] && "$bin" delete --all --force >/dev/null 2>&1 || true
    [[ -n "$bin" && -x "$bin" ]] && "$bin" daemon stop >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

printf '==> Unpacking %s\n' "$(basename "$tarball")"
tar -C "$work" -xzf "$tarball"
found=("$work"/simctlhouse-*/bin/simctlhouse)
[[ ${#found[@]} -eq 1 && -x "${found[0]}" ]] || { echo "error: the tarball has no simctlhouse-<version>/bin/simctlhouse." >&2; exit 1; }
export bin="${found[0]}"
source "$dir/lib.sh"

before="$(udids)"
before_count="$(count "$before")"
printf '==> %s simulators before the tests\n' "$before_count"

for test in "${tests[@]}"; do
    name="$(basename "$test" .sh)"
    printf '==> %s: %s\n' "$name" "$(sed -n '2s/^# //p' "$test")"
    # Indents what the test prints under its heading; stdout stays stdout.
    { bash "$test" 2>&1 1>&3 3>&- | sed 's/^/    /' >&2; } 3>&1 || fail "$name failed."
    [[ -z "$(leased)" ]] || fail "$name left a device leased:"$'\n'"$(leased)"
    wait_for_daemon_exit 30 || fail "$name left the daemon running for more than 30 seconds."
done

"$bin" delete --all --force >/dev/null 2>&1
# Every simulator that existed before must still exist. Other agents on this machine may delete their own devices
# meanwhile; a failure lists the missing UDIDs so you can tell whether this run touched them.
after="$(udids)"
after_count="$(count "$after")"
printf '==> %s simulators after the tests\n' "$after_count"
missing="$(comm -23 <(echo "$before") <(echo "$after"))"
[[ -z "$missing" ]] || fail "simulators that existed before the tests are gone:"$'\n'"$missing"
# Other agents on this machine may create simulators meanwhile; a failure lists the new UDIDs so you can tell.
added="$(comm -13 <(echo "$before") <(echo "$after"))"
[[ "$after_count" -eq "$before_count" ]] ||
    fail "there are $after_count simulators after the tests, $before_count before. New ones:"$'\n'"$added"

printf '==> Smoke test passed for simctlhouse %s (%s tests)\n' "$version" "${#tests[@]}"

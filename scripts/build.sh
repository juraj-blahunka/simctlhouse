#!/usr/bin/env bash
# Builds the simctlhouse binary exactly as it is released, so a local install runs the same bytes a release ships:
# an arm64 release build, stripped of build paths, signed with the hardened runtime.
# scripts/install.sh and scripts/release.sh both build through this script (see D27 in docs/decisions.md).
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build.sh [--identity NAME] [--developer-id] OUTPUT

  OUTPUT          Where to write the binary, e.g. dist/simctlhouse-1.4.0/bin/simctlhouse.
  --identity NAME Code signing identity. Default: the only "Developer ID Application" identity
                  in the keychain, or an ad-hoc signature when there is none.
  --developer-id  Fail instead of signing ad-hoc when no Developer ID identity is found.
                  Releases need it; local installs do not.
EOF
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output=""
identity=""
require_developer_id=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) identity="${2:?--identity needs a value}"; shift 2 ;;
        --developer-id) require_developer_id=1; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) echo "error: unknown option $1" >&2; usage >&2; exit 64 ;;
        *) [[ -z "$output" ]] || { echo "error: unexpected argument $1" >&2; exit 64; }; output="$1"; shift ;;
    esac
done
[[ -n "$output" ]] || { usage >&2; exit 64; }

step() { printf '==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

if [[ -z "$identity" ]]; then
    identities="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | sort -u)"
    if [[ -z "$identities" ]]; then
        [[ $require_developer_id -eq 0 ]] || fail "no Developer ID Application identity in the keychain; pass --identity."
        identity="-"
    elif [[ "$(wc -l <<<"$identities")" -eq 1 ]]; then
        identity="$identities"
    else
        fail "several Developer ID Application identities; pass --identity:"$'\n'"$identities"
    fi
fi

# The deployment target the formula promises (`depends_on macos:`) comes from Package.swift, so check the binary against it.
minimum_macos="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)\).*/\1/p' "$repo_dir/Package.swift").0"

step "Building arm64 release binary"
build_args=(-c release --arch arm64 --package-path "$repo_dir")
swift build "${build_args[@]}"
binary="$(swift build "${build_args[@]}" --show-bin-path)/simctlhouse"

# Work on a temporary file next to OUTPUT and move it into place last, so a failure never leaves a half-made binary there.
mkdir -p "$(dirname "$output")"
work="$(mktemp "$(dirname "$output")/.simctlhouse.XXXXXX")"
trap 'rm -f "$work"' EXIT
install -m 755 "$binary" "$work"
[[ "$(lipo -archs "$work")" == "arm64" ]] || fail "the binary is not arm64 only: $(lipo -archs "$work")."
built_minimum="$(vtool -show-build "$work" | awk '/minos/ { print $2; exit }')"
[[ "$built_minimum" == "$minimum_macos" ]] ||
    fail "the binary needs macOS $built_minimum, but Package.swift declares $minimum_macos."

# The debug symbol table holds absolute build paths, which would publish the builder's home directory and checkout layout.
strip -S "$work"
for leak in "$repo_dir" "$HOME/"; do
    ! /usr/bin/grep -aqF "$leak" "$work" || fail "the binary still contains the build path $leak."
done

if [[ "$identity" == "-" ]]; then
    step "Signing ad-hoc (no Developer ID identity), with the hardened runtime"
    codesign --force --sign - --identifier simctlhouse --options runtime "$work"
else
    step "Signing with $identity"
    # Notarization requires the hardened runtime and a secure timestamp.
    codesign --force --sign "$identity" --identifier simctlhouse --options runtime --timestamp "$work"
fi
codesign --verify --strict "$work"
mv -f "$work" "$output"

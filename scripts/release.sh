#!/usr/bin/env bash
# Builds a release of simctlhouse: the arm64 binary from scripts/build.sh, signed with a Developer ID and notarized,
# plus the agent skill, packed as a prefix-shaped tarball, and the Homebrew formula that installs it
# (see D27 in docs/decisions.md). It only writes to dist/; publishing the GitHub release and the tap is a separate step.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/release.sh <version> [--identity NAME] [--notary-profile NAME] [--skip-notarize] [--allow-dirty]

  <version>               The release version, e.g. 1.4.0. Must match `version:` in
                          Sources/simctlhouse/SimctlHouse.swift; bump it there first.
  --identity NAME         Code signing identity. Default: the only "Developer ID Application"
                          identity in the keychain.
  --notary-profile NAME   notarytool keychain profile. Default: notarytool-profile,
                          shared by every project notarizing with this Apple ID.
                          Create it once with: xcrun notarytool store-credentials notarytool-profile
                          In CI, set NOTARY_KEY (path to the .p8), NOTARY_KEY_ID and
                          NOTARY_ISSUER instead.
  --skip-notarize         Sign but do not notarize, for trying the script out. Not for publishing.
  --allow-dirty           Build even if the sources have uncommitted changes. Not for publishing.

Output in dist/:
  simctlhouse-<version>-macos.tar.gz   bin/simctlhouse, share/simctlhouse/skills/simctlhouse, LICENSE
  simctlhouse.rb                       the formula for the Homebrew tap
EOF
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$repo_dir/dist"
# This repository on GitHub; the formula downloads the release tarball from it.
repo="juraj-blahunka/simctlhouse"
version=""
identity_args=()
notary_profile="notarytool-profile"
notarize=1
allow_dirty=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) identity_args=(--identity "${2:?--identity needs a value}"); shift 2 ;;
        --notary-profile) notary_profile="${2:?--notary-profile needs a value}"; shift 2 ;;
        --skip-notarize) notarize=0; shift ;;
        --allow-dirty) allow_dirty=1; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) echo "error: unknown option $1" >&2; usage >&2; exit 64 ;;
        *) [[ -z "$version" ]] || { echo "error: unexpected argument $1" >&2; exit 64; }; version="$1"; shift ;;
    esac
done

step() { printf '==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

# Checks that need no build come first, so a mistake fails in seconds rather than after a build and a notarization.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: pass a version like 1.4.0" >&2; usage >&2; exit 64; }

source_version="$(sed -nE 's/^ *version: "([^"]+)",$/\1/p' "$repo_dir/Sources/simctlhouse/SimctlHouse.swift")"
[[ "$source_version" == "$version" ]] ||
    fail "SimctlHouse.swift says version \"$source_version\", not \"$version\". Bump it, commit, then release."

cd "$repo_dir"
# The paths the release is built from. Other uncommitted files (docs, other agents' work) do not affect the build.
source_paths=(Package.swift Package.resolved Sources skills LICENSE scripts/build.sh)
sources_clean() { [[ -z "$(git status --porcelain -- "${source_paths[@]}")" ]]; }
if [[ $allow_dirty -eq 0 ]]; then
    sources_clean || fail "uncommitted changes in the sources; commit them, or pass --allow-dirty to try the script out."
fi
# The commit this build is made from. Publishing tags and pushes exactly this commit, not whatever HEAD is by then.
commit="$(git rev-parse HEAD)"
if tagged="$(git rev-parse -q --verify "refs/tags/v$version^{commit}")"; then
    [[ "$tagged" == "$(git rev-parse HEAD)" ]] || fail "tag v$version exists but does not point at HEAD."
fi

# The formula's `depends_on macos:` takes Homebrew's name for the release that Package.swift requires.
minimum_macos="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)\).*/\1/p' Package.swift)"
case "$minimum_macos" in
    14) macos_symbol=sonoma ;;
    15) macos_symbol=sequoia ;;
    26) macos_symbol=tahoe ;;
    *) fail "no Homebrew name known for macOS $minimum_macos (Package.swift); add it to scripts/release.sh." ;;
esac

notary_args=()
if [[ $notarize -eq 1 ]]; then
    if [[ -n "${NOTARY_KEY:-}" ]]; then
        notary_args=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY}" --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER is required with NOTARY_KEY}")
    else
        notary_args=(--keychain-profile "$notary_profile")
    fi
    xcrun notarytool history "${notary_args[@]}" >/dev/null 2>&1 ||
        fail "notarytool cannot log in with ${notary_args[*]}. Run: xcrun notarytool store-credentials $notary_profile"
fi

step "Running tests and lint"
swift test --package-path "$repo_dir"
"$repo_dir/scripts/lint.sh"

name="simctlhouse-$version"
stage="$dist/$name"
tarball="$dist/$name-macos.tar.gz"
rm -rf "$stage" "$tarball" "$dist/simctlhouse.rb" "$dist/notarize.zip" "$dist/release-$version.commit"

"$repo_dir/scripts/build.sh" --developer-id ${identity_args[@]+"${identity_args[@]}"} "$stage/bin/simctlhouse"

step "Staging $name"
ditto "$repo_dir/skills/simctlhouse" "$stage/share/simctlhouse/skills/simctlhouse"
cp "$repo_dir/LICENSE" "$stage/LICENSE"
built_version="$("$stage/bin/simctlhouse" --version)"
[[ "$built_version" == "$version" ]] || fail "the built binary reports version $built_version, not $version."

if [[ $notarize -eq 1 ]]; then
    step "Notarizing (this takes a few minutes)"
    # notarytool takes zip, pkg or dmg. The ticket covers the binary's code hash, so the tarball we ship is covered too;
    # a bare binary cannot be stapled, so Gatekeeper checks the ticket online on first run.
    ditto -c -k --keepParent "$stage/bin/simctlhouse" "$dist/notarize.zip"
    result="$(xcrun notarytool submit "$dist/notarize.zip" "${notary_args[@]}" --wait --output-format json)"
    rm -f "$dist/notarize.zip"
    status="$(plutil -extract status raw - <<<"$result")"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$(plutil -extract id raw - <<<"$result")" "${notary_args[@]}" >&2 || true
        fail "notarization finished with status $status."
    fi
    # Check that the ticket is published for this exact code hash, in the service Gatekeeper on users' Macs asks.
    # `spctl` cannot do this: asked before the ticket is published, it caches "Unnotarized" for the hash for a while.
    # The endpoint is the one `stapler` uses; Apple does not document it.
    cdhash="$(codesign -dvvv "$stage/bin/simctlhouse" 2>&1 | sed -nE 's/^CDHash=([0-9a-f]+)$/\1/p')"
    for attempt in $(seq 1 24); do
        ticket="$(curl -fsS -X POST -H 'Content-Type: application/json' \
            -d "{\"records\":[{\"recordName\":\"2/2/$cdhash\"}]}" \
            https://api.apple-cloudkit.com/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup || true)"
        [[ "$ticket" == *'"recordType" : "DeveloperIDTicket"'* ]] && break
        [[ $attempt -lt 24 ]] || fail "no notarization ticket published for cdhash $cdhash after 2 minutes (or Apple changed the ticket service): $ticket"
        sleep 5
    done
else
    echo "warning: not notarized (--skip-notarize); do not publish this build." >&2
fi

step "Packing $(basename "$tarball")"
# No AppleDouble files or extended attributes, and neutral ownership, so the archive is the same wherever it is built.
COPYFILE_DISABLE=1 tar -C "$dist" --no-xattrs --no-mac-metadata --uid 0 --gid 0 -czf "$tarball" "$name"
sha256="$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)"

step "Checking the tarball"
# Install it the way a user would, so a broken layout fails here instead of in someone's `brew install`.
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
tar -C "$check" -xzf "$tarball"
codesign --verify --strict "$check/$name/bin/simctlhouse"
"$check/$name/bin/simctlhouse" skill install --skills-dir "$check/skills" >/dev/null 2>&1 ||
    fail "the packed binary cannot find its skill in share/simctlhouse."

cat >"$dist/simctlhouse.rb" <<EOF
class Simctlhouse < Formula
  desc "Lease iOS simulators to parallel coding agents"
  homepage "https://github.com/$repo"
  url "https://github.com/$repo/releases/download/v$version/$(basename "$tarball")"
  sha256 "$sha256"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :$macos_symbol

  def install
    bin.install "bin/simctlhouse"
    pkgshare.install "share/simctlhouse/skills"
  end

  def caveats
    <<~EOS
      To make the simctlhouse skill available to your coding agents, run once:
        simctlhouse skill install
      Upgrades update the skill automatically.
      Before uninstalling, remove the pool's simulators, the daemon and the skill links:
        simctlhouse uninstall
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/simctlhouse --version").strip
    assert_path_exists pkgshare/"skills/simctlhouse/SKILL.md"
  end
end
EOF

# Other agents may share this checkout: make sure nobody changed the sources or moved HEAD while this built.
if [[ $allow_dirty -eq 0 ]]; then
    # Compares the working tree with $commit, so it also catches source changes someone committed meanwhile.
    git diff --quiet "$commit" -- "${source_paths[@]}" && [[ -z "$(git ls-files --others --exclude-standard -- "${source_paths[@]}")" ]] ||
        fail "the sources changed during the build, so the binary may not match $commit; release again."
fi
[[ "$(git rev-parse HEAD)" == "$commit" ]] ||
    echo "note: HEAD moved during the build; this release is $commit, and later commits are not in it." >&2
echo "$commit" >"$dist/release-$version.commit"

step "Done"
cat <<EOF
  $tarball
  sha256 $sha256
  commit $commit
  $dist/simctlhouse.rb
EOF

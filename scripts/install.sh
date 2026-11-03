#!/usr/bin/env bash
# Builds simctlhouse the way a release does (scripts/build.sh), installs the binary, and links the agent skill
# from this checkout into each coding agent's skills directory.
# Safe to re-run: it rebuilds, replaces the binary, and refreshes the skill links.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/install.sh [--bin-dir DIR] [--skills-dir DIR]... [--no-skill] [--uninstall]

  --bin-dir DIR     Where to install the binary.
                    Default: /usr/local/bin if writable, otherwise ~/.local/bin.
  --skills-dir DIR  A skills directory to link the simctlhouse skill into. Repeatable.
                    Default: the skills directory of every agent found:
                      Claude Code  ~/.claude/skills
                      Codex        ~/.codex/skills
                      pi           ~/.pi/agent/skills ($PI_CODING_AGENT_DIR/skills)
  --no-skill        Do not link the agent skill.
  --uninstall       Remove the skill links and the installed binary instead.
                    Your simulator pool (~/.simctlhouse) is left alone;
                    run `simctlhouse delete --all --force` first to remove it.

Agents without skill support can read skills/simctlhouse/SKILL.md directly;
see "Use it from any agent" in docs/how-to.md.
EOF
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill_source="$repo_dir/skills/simctlhouse"
bin_dir=""
skills_dirs=()
link_skill=1
uninstall=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-dir) bin_dir="${2:?--bin-dir needs a value}"; shift 2 ;;
        --skills-dir) skills_dirs+=("${2:?--skills-dir needs a value}"); shift 2 ;;
        --no-skill) link_skill=0; shift ;;
        --uninstall) uninstall=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "error: unknown option $1" >&2; usage >&2; exit 64 ;;
    esac
done

if [[ -z "$bin_dir" ]]; then
    if [[ -w /usr/local/bin ]]; then bin_dir=/usr/local/bin; else bin_dir="$HOME/.local/bin"; fi
fi
binary="$bin_dir/simctlhouse"

# The binary detects the agents and owns the links (`simctlhouse skill`); --skills-dir replaces its detection.
skills_args=()
for dir in ${skills_dirs[@]+"${skills_dirs[@]}"}; do skills_args+=(--skills-dir "$dir"); done

step() { printf '==> %s\n' "$*"; }

if [[ $uninstall -eq 1 ]]; then
    if [[ $link_skill -eq 1 ]]; then
        step "Removing skill links"
        # `skill --help` succeeds on binaries without the command too (it prints the root help), so probe a read-only call.
        if [[ -x "$binary" ]] && "$binary" skill status --skills-dir /dev/null >/dev/null 2>&1; then
            "$binary" skill uninstall ${skills_args[@]+"${skills_args[@]}"}
        else
            echo "error: $binary cannot remove skill links (missing or too old). Run scripts/install.sh first, then scripts/install.sh --uninstall." >&2
            exit 1
        fi
    fi
    # A daemon would go on running the removed binary until the pool is idle. Builds without a daemon fail this harmlessly.
    if [[ -x "$binary" ]] && "$binary" daemon stop >/dev/null 2>&1; then step "Stopped the daemon"; fi
    if [[ -e "$binary" ]]; then rm -f "$binary" && step "Removed $binary"; else step "No binary at $binary"; fi
    exit 0
fi

command -v swift >/dev/null || { echo "error: swift not found. Install Xcode or the Xcode command line tools." >&2; exit 1; }
xcrun simctl help >/dev/null 2>&1 || { echo "error: xcrun simctl is unavailable. Install Xcode and run 'sudo xcode-select -s /Applications/Xcode.app'." >&2; exit 1; }

# The same build a release ships, so what you test locally is what users get.
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
"$repo_dir/scripts/build.sh" "$build_dir/simctlhouse"

step "Installing $binary"
mkdir -p "$bin_dir"
# -S replaces the file by rename: rewriting a signed binary in place can leave the kernel's signature cache stale.
install -S -m 755 "$build_dir/simctlhouse" "$binary"

if [[ $link_skill -eq 1 ]]; then
    # Link the checkout rather than a copy, so edits to the skill take effect immediately.
    step "Linking skill"
    "$binary" skill install --source "$skill_source" ${skills_args[@]+"${skills_args[@]}"}
fi

step "Installed $("$binary" --version)"
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "warning: $bin_dir is not on your PATH. Add it, e.g. for fish: fish_add_path $bin_dir" >&2 ;;
esac

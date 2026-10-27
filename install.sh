#!/usr/bin/env bash
# Builds simctlhouse, installs the binary, and links the agent skill into ~/.claude/skills.
# Safe to re-run: it rebuilds, replaces the binary, and refreshes the skill link.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./install.sh [--bin-dir DIR] [--skills-dir DIR] [--no-skill] [--uninstall]

  --bin-dir DIR     Where to install the binary.
                    Default: /usr/local/bin if writable, otherwise ~/.local/bin.
  --skills-dir DIR  Claude Code skills directory. Default: ~/.claude/skills.
  --no-skill        Do not link the agent skill.
  --uninstall       Remove the installed binary and skill link instead.
                    Your simulator pool (~/.simctlhouse) is left alone;
                    run `simctlhouse delete --all --force` first to remove it.
EOF
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_source="$repo_dir/.claude/skills/simctlhouse"
bin_dir=""
skills_dir="$HOME/.claude/skills"
link_skill=1
uninstall=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-dir) bin_dir="${2:?--bin-dir needs a value}"; shift 2 ;;
        --skills-dir) skills_dir="${2:?--skills-dir needs a value}"; shift 2 ;;
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
skill_link="$skills_dir/simctlhouse"

step() { printf '==> %s\n' "$*"; }

if [[ $uninstall -eq 1 ]]; then
    if [[ -e "$binary" ]]; then rm -f "$binary" && step "Removed $binary"; else step "No binary at $binary"; fi
    if [[ -L "$skill_link" ]]; then rm -f "$skill_link" && step "Removed skill link $skill_link"; else step "No skill link at $skill_link"; fi
    exit 0
fi

command -v swift >/dev/null || { echo "error: swift not found. Install Xcode or the Xcode command line tools." >&2; exit 1; }
xcrun simctl help >/dev/null 2>&1 || { echo "error: xcrun simctl is unavailable. Install Xcode and run 'sudo xcode-select -s /Applications/Xcode.app'." >&2; exit 1; }

step "Building release binary"
swift build -c release --package-path "$repo_dir"

step "Installing $binary"
mkdir -p "$bin_dir"
install -m 755 "$repo_dir/.build/release/simctlhouse" "$binary"

if [[ $link_skill -eq 1 ]]; then
    mkdir -p "$skills_dir"
    if [[ -e "$skill_link" && ! -L "$skill_link" ]]; then
        # A real directory here is someone's copy; do not delete it.
        echo "error: $skill_link exists and is not a symlink. Remove it or pass --no-skill." >&2
        exit 1
    fi
    step "Linking skill $skill_link -> $skill_source"
    ln -sfn "$skill_source" "$skill_link"
fi

step "Installed $("$binary" --version)"
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "warning: $bin_dir is not on your PATH. Add it, e.g. for fish: fish_add_path $bin_dir" >&2 ;;
esac

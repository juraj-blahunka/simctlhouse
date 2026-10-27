#!/usr/bin/env bash
# Builds simctlhouse, installs the binary, and links the agent skill into each coding agent's skills directory.
# Safe to re-run: it rebuilds, replaces the binary, and refreshes the skill links.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./install.sh [--bin-dir DIR] [--skills-dir DIR]... [--no-skill] [--uninstall]

  --bin-dir DIR     Where to install the binary.
                    Default: /usr/local/bin if writable, otherwise ~/.local/bin.
  --skills-dir DIR  A skills directory to link the simctlhouse skill into. Repeatable.
                    Default: the skills directory of every agent found:
                      Claude Code  ~/.claude/skills
                      Codex        ~/.codex/skills
                      pi           ~/.pi/agent/skills ($PI_CODING_AGENT_DIR/skills)
  --no-skill        Do not link the agent skill.
  --uninstall       Remove the installed binary and skill links instead.
                    Your simulator pool (~/.simctlhouse) is left alone;
                    run `simctlhouse delete --all --force` first to remove it.

Agents without skill support can read skills/simctlhouse/SKILL.md directly;
see "Use it from any agent" in docs/how-to.md.
EOF
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Agents that load SKILL.md skills from a per-user directory. Only agents that are set up on this machine get a link.
if [[ ${#skills_dirs[@]} -eq 0 ]]; then
    for agent_home in "$HOME/.claude" "$HOME/.codex" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"; do
        [[ -d "$agent_home" ]] && skills_dirs+=("$agent_home/skills")
    done
fi

step() { printf '==> %s\n' "$*"; }

# A link is ours if it points into this checkout (including the skill's earlier location).
is_our_link() { [[ -L "$1" && "$(readlink "$1")" == "$repo_dir"/* ]]; }

if [[ $uninstall -eq 1 ]]; then
    if [[ -e "$binary" ]]; then rm -f "$binary" && step "Removed $binary"; else step "No binary at $binary"; fi
    for dir in ${skills_dirs[@]+"${skills_dirs[@]}"}; do
        link="$dir/simctlhouse"
        if is_our_link "$link"; then rm -f "$link" && step "Removed skill link $link"; else step "No simctlhouse skill link at $link"; fi
    done
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
    if [[ ${#skills_dirs[@]} -eq 0 ]]; then
        echo "note: no agent skills directory found (looked for Claude Code, Codex and pi)." >&2
        echo "      Pass --skills-dir for your agent, or see \"Use it from any agent\" in docs/how-to.md." >&2
    fi
    for dir in ${skills_dirs[@]+"${skills_dirs[@]}"}; do
        link="$dir/simctlhouse"
        if [[ -e "$link" || -L "$link" ]] && ! is_our_link "$link"; then
            # Someone else's skill or a real copy; do not delete it.
            echo "error: $link exists and is not a link into this checkout. Remove it or pass --no-skill." >&2
            exit 1
        fi
        mkdir -p "$dir"
        ln -sfn "$skill_source" "$link"
        step "Linked skill $link -> $skill_source"
    done
fi

step "Installed $("$binary" --version)"
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "warning: $bin_dir is not on your PATH. Add it, e.g. for fish: fish_add_path $bin_dir" >&2 ;;
esac

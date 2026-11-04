#!/usr/bin/env bash
# Lints the Swift sources the way CI and scripts/release.sh do, so a clean local run means a clean release.
# Warnings fail too (--strict): a release is only cut from a tree with none.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/lint.sh [--fix]

  --fix   Reformat the sources in place first (swift format format -i), then lint what remains.
          Most findings are fixed this way; the rest need a hand edit.
EOF
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fix=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix) fix=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "error: unknown argument $1" >&2; usage >&2; exit 64 ;;
    esac
done

sources=("$repo_dir/Sources" "$repo_dir/Tests")
[[ "$fix" -eq 0 ]] || swift format format --in-place --recursive "${sources[@]}"
swift format lint --strict --recursive "${sources[@]}"

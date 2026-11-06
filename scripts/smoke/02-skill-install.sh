#!/usr/bin/env bash
# skill install links the skill the tarball ships.
source "$(dirname "$0")/lib.sh"

skills="$SMOKE_WORK/skills"
"$bin" skill install --skills-dir "$skills" >/dev/null 2>&1
[[ "$("$bin" skill status --skills-dir "$skills" --json)" == *'"status" : "linked"'* ]] ||
    fail "skill status does not report the link as linked."
[[ -f "$skills/simctlhouse/SKILL.md" ]] || fail "the linked skill has no SKILL.md."

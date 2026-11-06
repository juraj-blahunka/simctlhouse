#!/usr/bin/env bash
# The binary reports the release's version and has a valid signature.
source "$(dirname "$0")/lib.sh"

reported="$("$bin" --version)"
[[ "$reported" == "$SMOKE_VERSION" ]] || fail "the binary reports version $reported, not $SMOKE_VERSION."
codesign --verify --strict "$bin" || fail "the binary's signature does not verify."

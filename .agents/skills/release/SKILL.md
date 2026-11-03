---
name: release
description: Release a new simctlhouse version end to end - bump the version, agree on release notes with the user, build the signed and notarized tarball with scripts/release.sh, tag, create the GitHub release, and publish the formula to the Homebrew tap. Use when asked to release, publish, ship or cut a simctlhouse version, or to update the Homebrew formula.
---

# Release simctlhouse

Publishes version `X.Y.Z` of this repository: a GitHub release with the notarized tarball, and the formula in the tap.
`scripts/release.sh` does the build, signing, notarization and packaging; this skill does everything around it.
`docs/how-to.md` ("Make a release") and D27 in `docs/decisions.md` explain the design.

Fixed names:

| What | Value |
| --- | --- |
| GitHub repository | `juraj-blahunka/simctlhouse` (remote `origin`) |
| Tap checkout | `../homebrew-tap`, GitHub `juraj-blahunka/homebrew-tap`, used as `juraj-blahunka/tap` |
| Formula in the tap | `Formula/simctlhouse.rb` |
| Tag | `vX.Y.Z` |
| Tarball | `dist/simctlhouse-X.Y.Z-macos.tar.gz` |
| Release notes | `dist/release-notes-X.Y.Z.md` (`dist/` is ignored by git) |

Run every command from the repository root unless a step says otherwise.
Stop at the first failure, report what failed with its output, and do not work around it (no `--skip-notarize`, `--allow-dirty`, `--force` or `--no-verify`).

## 1. Pick the version

Use the version the user gave.
Otherwise propose one and ask: list the changes since the last tag with `git log --oneline $(git describe --tags --abbrev=0 2>/dev/null)..HEAD` (all commits if there is no tag), then bump minor for `feat:` commits and patch for fixes only.

## 2. Check preconditions

Check all of these before changing anything, and report every failure at once:

```sh
git rev-parse --abbrev-ref HEAD                  # main
git status --porcelain --untracked-files=no      # empty
git remote get-url origin                        # github.com/juraj-blahunka/simctlhouse
git fetch origin && git status -sb | head -1     # not behind origin/main
git ls-remote --tags origin "refs/tags/vX.Y.Z"   # empty: the version is unreleased
gh auth status                                   # logged in
git -C ../homebrew-tap status --porcelain        # tap exists and is clean
git -C ../homebrew-tap pull --ff-only            # tap is up to date
```

If `origin` or the tap is missing, stop and tell the user what to create; never create GitHub repositories yourself.
A new tap needs the GitHub repository `juraj-blahunka/homebrew-tap`, cloned to `../homebrew-tap`, with a `Formula/` directory.

## 3. Bump the version

If `version:` in `Sources/simctlhouse/SimctlHouse.swift` is not `X.Y.Z`, change it there, run `swift build` and `swift test`, and commit only that file:

```sh
git commit -m "chore: release X.Y.Z" Sources/simctlhouse/SimctlHouse.swift
```

## 4. Write the release notes with the user

Draft the notes from what changed since the last release:

```sh
git log --format='%h %s%n%b' $(git describe --tags --abbrev=0 2>/dev/null)..HEAD
git diff --stat $(git describe --tags --abbrev=0 2>/dev/null)..HEAD
```

Read the commits and, where a subject is unclear, the diff itself; the notes describe what users of the CLI and the skill notice, not how the code changed.

- Start with one or two sentences on what the release is about.
- Then sections, leaving out empty ones: `## New`, `## Changed`, `## Fixed`, and `## Breaking` first if anything breaks scripts or agents (renamed commands or flags, changed output, changed exit codes).
- One bullet per change, with the command or flag in backticks, e.g. `simctlhouse skill install`.
- Leave out `chore:`, `refactor:`, `test:` and docs-only commits unless users would notice them.
- End with how to get it, exactly like this:

  ````markdown
  ## Install

  ```sh
  brew install juraj-blahunka/tap/simctlhouse   # or: brew upgrade simctlhouse
  simctlhouse skill install                     # once, to link the agent skill
  ```
  ````

Write the draft to `dist/release-notes-X.Y.Z.md` and show the user the full text.
Ask them to accept it or say what to change; apply their changes to the file and show the whole text again.
Repeat until they accept it explicitly, and do not go on to the build before that.
The file is published verbatim, so it must not contain anything addressed to the user, such as questions or TODOs.

## 5. Build the release

```sh
scripts/release.sh X.Y.Z
```

It takes a few minutes, most of it waiting for Apple's notarization; allow up to 10 minutes.
It refuses to run on a version mismatch, uncommitted sources, or a tag pointing elsewhere, runs the tests and lint, builds through `scripts/build.sh`, checks that Apple published the notarization ticket, and verifies its own tarball.
It ends by printing the tarball path, its sha256, and `dist/simctlhouse.rb`.

## 6. Smoke test the tarball

Run the exact bytes you are about to publish against real simulators:

```sh
scripts/smoke-test.sh dist/simctlhouse-X.Y.Z-macos.tar.gz
```

It unpacks the tarball into a temporary directory, links the skill there, acquires a device in a throwaway `SIMCTLHOUSE_HOME`, checks that the daemon started and can be stopped and started again, releases the device and waits for the daemon to shut it down and exit on its own, deletes it, and checks that every simulator that existed before still exists.
A first boot takes about 30 seconds; allow up to 5 minutes on a loaded machine.
If it reports missing simulators, show the list to the user: other agents may have deleted their own devices meanwhile, and only the user can tell.

## 7. Confirm before publishing

Everything from here is public and hard to undo.
Show the user the version, the commit (`git log --oneline -1`), the sha256, the smoke test result, the accepted release notes file, and the steps below, and wait for an explicit go-ahead.

## 8. Publish

In this order, so that every published step points at something that already exists:

```sh
git push origin main
git tag -a vX.Y.Z -m "simctlhouse X.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z dist/simctlhouse-X.Y.Z-macos.tar.gz \
    --repo juraj-blahunka/simctlhouse --verify-tag --title "simctlhouse X.Y.Z" --notes-file dist/release-notes-X.Y.Z.md
```

Check that the uploaded tarball is the one the formula describes; a mismatch means `scripts/release.sh` ran again after the upload:

```sh
gh release download vX.Y.Z --repo juraj-blahunka/simctlhouse --pattern '*.tar.gz' --output - | shasum -a 256
grep sha256 dist/simctlhouse.rb
```

Then publish the formula:

```sh
mkdir -p ../homebrew-tap/Formula
cp dist/simctlhouse.rb ../homebrew-tap/Formula/simctlhouse.rb
git -C ../homebrew-tap add Formula/simctlhouse.rb
git -C ../homebrew-tap commit -m "simctlhouse X.Y.Z"
git -C ../homebrew-tap push
```

## 9. Verify through Homebrew

These read only; they do not install anything:

```sh
brew tap juraj-blahunka/tap 2>/dev/null; brew update
brew info juraj-blahunka/tap/simctlhouse         # shows X.Y.Z
brew fetch --force juraj-blahunka/tap/simctlhouse  # downloads and checks the sha256
brew audit --strict juraj-blahunka/tap/simctlhouse
```

If the user already has simctlhouse installed from the tap, offer `brew upgrade simctlhouse` and then `simctlhouse --version` and `simctlhouse skill status`.

## 10. Report

Give the user the release URL (`gh release view vX.Y.Z --repo juraj-blahunka/simctlhouse --json url -q .url`), the tap commit, and the install command `brew install juraj-blahunka/tap/simctlhouse`.

## Recovering from a failed release

- Failure before step 8: nothing is public. Fix the cause and start again; re-running `scripts/release.sh` is fine.
- Tag pushed, release missing: run the `gh release create` step again.
- Release created, tap not updated: run the tap steps again.
- Notes need fixing after publishing: edit `dist/release-notes-X.Y.Z.md` with the user, then `gh release edit vX.Y.Z --repo juraj-blahunka/simctlhouse --notes-file dist/release-notes-X.Y.Z.md`.
- Never re-run `scripts/release.sh` for a version whose tarball is uploaded, because every build has a new sha256.
  To replace a broken upload, ask the user first, then `gh release upload vX.Y.Z <tarball> --clobber` with a fresh build and publish the matching formula.
- Never delete or move a pushed tag or a published release without the user's explicit approval.

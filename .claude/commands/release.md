# Release op-who

You are performing a release of op-who, a macOS menu-bar app. Arguments: $ARGUMENTS

## Step 1: Determine target version

Parse `$ARGUMENTS` for `--bump {major,minor,patch}` or `--set X.Y.Z`. If neither is provided, determine the bump level automatically:

1. Find the latest version tag: `git tag --sort=-v:refname | head -1`
2. Get the diff summary since that tag: `git log <tag>..HEAD --oneline`
3. Classify:
   - **minor**: if there are any `feat:` commits or non-trivial new functionality
   - **patch**: if only `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, or similar non-feature commits
   - **NEVER bump major** unless the user explicitly passed `--bump major`

Special case — first release: if there are no version tags yet, look at `CFBundleShortVersionString` in `Sources/OpWhoLib/Info.plist`. If that version has never been released, prefer `--set <plist version>` so the first tag matches the plist value rather than bumping past it.

State the chosen mode (`--bump <level>` or `--set X.Y.Z`) and the reasoning.

## Step 2: Generate changelog entry

First, check if `CHANGELOG.md` exists and has entries under `## [Unreleased]`. If it does, use those as the starting point — they were written incrementally during development and are likely accurate. Supplement with any commits not already covered.

If `CHANGELOG.md` doesn't exist yet, or `[Unreleased]` is empty, review the commits since the last version tag (or all commits, for the first release) and write the entry from scratch.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Use these category prefixes per line (no group headings):

- `- Added:` — new features
- `- Changed:` — changes in existing functionality
- `- Fixed:` — bug fixes
- `- Removed:` — removed features

**Keep it tight.** Each entry is one short line — ideally under ~140 characters. Write for a user skimming the release page, not for an engineer who wants the full story. Rules:

- One line, one sentence. No subclauses piling up rationale, mechanism, edge cases, and follow-ups.
- Lead with the user-visible change. Skip implementation detail (file paths, internal flags, "now patches X at package time") unless it changes how the user interacts with the thing.
- If an existing `[Unreleased]` entry is verbose, rewrite it — don't just copy it forward.
- Details belong in commit messages, `SIGNING.md`, `CONTRIBUTORS.md`, etc. The changelog points at them, it doesn't replace them.

Do NOT include the version header line — `release-version.sh` adds that.

## Step 3: Confirm with user

Show the user:
- Current version → target version
- The chosen mode (bump level or explicit set) and reasoning
- The changelog entry

Ask for confirmation before proceeding. If the user wants changes, revise accordingly.

## Step 4: Run the release script

Once confirmed, pipe the changelog entry to `scripts/release-version.sh` via heredoc (the changelog often contains characters that break naive quoting):

```bash
scripts/release-version.sh --bump <level> <<'CHANGELOG'
<changelog entry>
CHANGELOG
```

Or for an explicit version:

```bash
scripts/release-version.sh --set X.Y.Z <<'CHANGELOG'
<changelog entry>
CHANGELOG
```

The script bumps/sets `CFBundleShortVersionString` and `CFBundleVersion` in `Sources/OpWhoLib/Info.plist`, prepends the entry to `CHANGELOG.md`, makes a `release: vX.Y.Z` commit, and creates a **signed** tag (`git tag -s`).

Prerequisite: `user.signingkey` and (for SSH signing) `gpg.format=ssh` must be configured in git. If `git tag -s` fails because no signing key is set, fix the git config and re-run — release tags must be signed.

If the tag creation fails after the commit is made, the script will have left the release commit in place. Verify with `git log -1`; you can either re-run after fixing the signing config (and delete the orphaned commit first) or manually create the tag with `git tag -s vX.Y.Z -m "Release vX.Y.Z"`.

## Step 5: Push and finish on GitHub

Show the user the commands to push:

```bash
git push && git push --tags
```

Then explain what happens on push:

1. The `release.yml` workflow runs on the tag and opens a **draft** GitHub Release titled `op-who X.Y.Z` with auto-generated notes.
2. Build the artifact locally and attach it. While there's no Apple Developer ID cert yet, use the dev-build package — it also produces signed checksums (`SHA256SUMS` and `SHA256SUMS.sig`) that anchor end-user trust at `https://github.com/stigsb.keys`. See `SIGNING.md` for the threat model.

   ```bash
   scripts/package-dev.sh
   gh release upload "vX.Y.Z" dist/*
   ```

   `package-dev.sh` puts exactly three files in `dist/`: the arch-tagged tarball (`op-who-dev-macos-<arch>.tar.gz`), `SHA256SUMS`, and `SHA256SUMS.sig`.

   Once an Apple Developer ID cert is configured and the relevant secrets are in place, switch over to the notarized workflow (`release-notarized.yml`) and use `scripts/release.sh` instead. The signed-checksums flow should remain in place there too — notarization covers Gatekeeper, not artifact tampering at rest.
3. Review the release notes in the GitHub UI, edit if needed, then publish:

   ```bash
   gh release edit "vX.Y.Z" --draft=false
   ```

If the user hasn't pushed yet (e.g. they want to review the commit first), stop after Step 4 and let them push when ready.

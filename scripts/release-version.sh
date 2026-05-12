#!/bin/bash
set -euo pipefail

# Release automation for op-who.
#
# Reads a changelog entry from stdin, updates the version in Info.plist
# (either by bumping or setting an explicit value), prepends the entry to
# CHANGELOG.md, commits, and tags.
#
# Usage:
#   echo "changelog text" | scripts/release-version.sh --bump minor
#   echo "changelog text" | scripts/release-version.sh --set 0.5.0

cd "$(dirname "$0")/.."

PLIST="Sources/OpWhoLib/Info.plist"
CHANGELOG="CHANGELOG.md"

# --- Parse arguments ---

BUMP=""
SET_VERSION=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bump)
            BUMP="$2"
            shift 2
            ;;
        --set)
            SET_VERSION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -n "$BUMP" && -n "$SET_VERSION" ]]; then
    echo "error: --bump and --set are mutually exclusive" >&2
    exit 1
fi

if [[ -z "$BUMP" && -z "$SET_VERSION" ]]; then
    echo "Usage: scripts/release-version.sh {--bump major|minor|patch | --set X.Y.Z}" >&2
    exit 1
fi

if [[ -n "$BUMP" && "$BUMP" != "major" && "$BUMP" != "minor" && "$BUMP" != "patch" ]]; then
    echo "error: --bump must be major, minor, or patch" >&2
    exit 1
fi

if [[ -n "$SET_VERSION" && ! "$SET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: --set must be X.Y.Z (e.g. 0.5.0)" >&2
    exit 1
fi

# --- Read changelog from stdin ---

ENTRY=$(cat)
if [[ -z "$ENTRY" ]]; then
    echo "error: No changelog entry provided on stdin" >&2
    exit 1
fi

# --- Get current version ---

OLD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
IFS='.' read -r MAJOR MINOR PATCH <<< "$OLD_VERSION"

# --- Resolve target version ---

if [[ -n "$SET_VERSION" ]]; then
    NEW_VERSION="$SET_VERSION"
else
    case "$BUMP" in
        major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
        minor) NEW_VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
        patch) NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
    esac
fi

# Refuse to re-tag an existing version.
if git rev-parse -q --verify "refs/tags/v${NEW_VERSION}" >/dev/null; then
    echo "error: tag v${NEW_VERSION} already exists" >&2
    exit 1
fi

echo "Version: $OLD_VERSION -> $NEW_VERSION"
echo "Changelog:"
echo "$ENTRY"
echo ""

if $DRY_RUN; then
    echo "(dry run — no changes made)"
    exit 0
fi

# --- Update Info.plist ---

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION" "$PLIST"

# --- Update CHANGELOG.md ---

TODAY=$(date +%Y-%m-%d)
HEADER="## [$NEW_VERSION] - $TODAY"

if [[ -f "$CHANGELOG" ]]; then
    # Insert after ## [Unreleased] if present, otherwise after the title
    if grep -q '## \[Unreleased\]' "$CHANGELOG"; then
        sed -i '' "/## \[Unreleased\]/a\\
\\
${HEADER}\\
\\
${ENTRY}\\
" "$CHANGELOG"
    else
        # Insert after first heading
        sed -i '' "1,/^# /s/^# .*/&\\
\\
${HEADER}\\
\\
${ENTRY}\\
/" "$CHANGELOG"
    fi
else
    cat > "$CHANGELOG" << EOF
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

${HEADER}

${ENTRY}
EOF
fi

# --- Commit and tag ---

TAG="v${NEW_VERSION}"
git add "$PLIST" "$CHANGELOG"
git commit -m "release: $TAG"
git tag -a "$TAG" -m "Release $TAG"

echo "Created commit and tag $TAG"

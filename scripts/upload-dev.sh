#!/bin/bash
set -euo pipefail

# Upload dev-build artifacts in dist/ to the matching GitHub Release.
#
# Expects:
#   - scripts/package-dev.sh has been run (dist/ contains the tarball,
#     SHA256SUMS, and SHA256SUMS.sig).
#   - The release already exists as a draft on GitHub (.github/workflows/
#     release.yml opens it on tag push). This script doesn't create releases.
#
# Default behavior is to upload and publish (draft=false). Pass --draft to
# leave the release as a draft for manual review before publishing.
#
# Usage:
#   scripts/upload-dev.sh                  # upload + publish
#   scripts/upload-dev.sh --draft          # upload, leave as draft
#   scripts/upload-dev.sh vX.Y.Z           # explicit tag (default: from Info.plist)
#   scripts/upload-dev.sh vX.Y.Z --draft

cd "$(dirname "$0")/.."

DRAFT=false
TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --draft)
            DRAFT=true
            shift
            ;;
        v*)
            TAG="$1"
            shift
            ;;
        -h|--help)
            sed -n '3,17p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "Usage: scripts/upload-dev.sh [vX.Y.Z] [--draft]" >&2
            exit 1
            ;;
    esac
done

# Default tag: CFBundleShortVersionString from Info.plist, prefixed with v.
if [[ -z "$TAG" ]]; then
    PLIST="Sources/OpWhoLib/Info.plist"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
    TAG="v${VERSION}"
fi

# Sanity checks before talking to GitHub.
if [[ ! -d dist ]]; then
    echo "error: dist/ does not exist. Run scripts/package-dev.sh first." >&2
    exit 1
fi

shopt -s nullglob
TARBALLS=(dist/op-who-dev-macos-*.tar.gz)
shopt -u nullglob
if [[ ${#TARBALLS[@]} -eq 0 ]]; then
    echo "error: no op-who-dev-macos-*.tar.gz found in dist/. Run scripts/package-dev.sh first." >&2
    exit 1
fi
for required in dist/SHA256SUMS dist/SHA256SUMS.sig; do
    if [[ ! -f "$required" ]]; then
        echo "error: missing $required. Run scripts/package-dev.sh first." >&2
        exit 1
    fi
done

# Confirm the draft release exists. release.yml opens it on tag push;
# if it isn't there yet, the workflow hasn't run (or failed).
if ! gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: release $TAG does not exist on GitHub." >&2
    echo "Push the tag (git push --tags) so release.yml can open the draft first." >&2
    exit 1
fi

echo "Uploading artifacts in dist/ to release $TAG..."
gh release upload "$TAG" "${TARBALLS[@]}" dist/SHA256SUMS dist/SHA256SUMS.sig --clobber

if $DRAFT; then
    echo "Left release $TAG as a draft. Publish with:"
    echo "  gh release edit \"$TAG\" --draft=false"
else
    echo "Publishing release $TAG..."
    gh release edit "$TAG" --draft=false
    echo "Published."
fi

gh release view "$TAG" --json url --jq '.url'

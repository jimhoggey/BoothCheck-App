#!/bin/bash
# Publishes the version in Info.plist as a GitHub release that Booth Check's updater will offer.
#
#   1. Bump CFBundleShortVersionString (and CFBundleVersion) in Info.plist, and commit.
#   2. ./release.sh "What changed, in a line or two"
#
# The tag is v<version> and must match the app's own version: the updater refuses a download whose
# version differs from the tag it was offered.
set -euo pipefail
cd "$(dirname "$0")"

notes=${1:?Usage: ./release.sh "release notes"}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
tag="v$version"

if [ -n "$(git status --porcelain)" ]; then echo "Commit your changes first." >&2; exit 1; fi
if gh release view "$tag" >/dev/null 2>&1; then echo "$tag already exists. Bump the version in Info.plist." >&2; exit 1; fi

./build.sh
built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "build/Booth Check.app/Contents/Info.plist")
[ "$built" = "$version" ] || { echo "Built app says $built, expected $version." >&2; exit 1; }

git push
gh release create "$tag" "build/Booth Check.zip" --title "Booth Check $version" --notes "$notes"

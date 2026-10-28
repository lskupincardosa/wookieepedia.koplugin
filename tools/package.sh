#!/bin/sh
# Build the release zip: dist/wookieepedia.koplugin-<version>.zip, holding a
# wookieepedia.koplugin/ folder that users copy into KOReader's plugins/.
# The version comes from wookapi.lua.
cd "$(dirname "$0")/.." || exit 1
. tools/files.sh
VERSION=$(sed -n 's/^ *version = "\(.*\)",$/\1/p' wookapi.lua)
[ -n "$VERSION" ] || { echo "no version in wookapi.lua" >&2; exit 1; }
STAGE=$(mktemp -d)
mkdir -p "$STAGE/wookieepedia.koplugin" dist
# shellcheck disable=SC2086 # the file list is meant to split
tar -cf - $RUNTIME_FILES | tar -xf - -C "$STAGE/wookieepedia.koplugin"
ZIP="$PWD/dist/wookieepedia.koplugin-$VERSION.zip"
rm -f "$ZIP"
(cd "$STAGE" && COPYFILE_DISABLE=1 zip -qrX "$ZIP" wookieepedia.koplugin)
rm -rf "$STAGE"
echo "$ZIP"

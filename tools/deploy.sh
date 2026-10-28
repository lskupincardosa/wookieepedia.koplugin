#!/bin/sh
# Copy the plugin's runtime files to the e-reader over KOReader's SSH server.
# Usage: tools/deploy.sh [host] [koreader dir]
# The host can also come from KOREADER_HOST, e.g. in an untracked .deploy.env
# file next to this repo's README. KOReader dir default: /mnt/us/koreader (Kindle).
# Needs this Mac's key in <koreader>/settings/SSH/authorized_keys (see DEV.md).
# Restart KOReader on the device afterwards: plugins load at startup.
cd "$(dirname "$0")/.." || exit 1
[ -f .deploy.env ] && . ./.deploy.env
HOST="${1:-$KOREADER_HOST}"
KO="${2:-${KOREADER_DIR:-/mnt/us/koreader}}"
if [ -z "$HOST" ]; then
    echo "usage: tools/deploy.sh <e-reader ip> [koreader dir]  (or set KOREADER_HOST in .deploy.env)" >&2
    exit 1
fi
# COPYFILE_DISABLE keeps macOS tar from adding ._ metadata files.
. tools/files.sh
# shellcheck disable=SC2086 # the file list is meant to split
COPYFILE_DISABLE=1 tar -cf - $RUNTIME_FILES \
    | ssh -p 2222 -o BatchMode=yes "root@$HOST" \
        "mkdir -p '$KO/plugins/wookieepedia.koplugin' && cd '$KO/plugins/wookieepedia.koplugin' && tar -xf - \
         && for f in *.lua data/*.lua; do '$KO/luajit' -e \"assert(loadfile('\$f'))\" || echo \"SYNTAX ERROR: \$f\"; done \
         && echo 'Deployed to $HOST:$KO/plugins/wookieepedia.koplugin, restart KOReader to load it.'"

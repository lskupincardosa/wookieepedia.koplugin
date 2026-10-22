#!/bin/sh
# Copy the plugin's runtime files to the e-reader over KOReader's SSH server.
# Usage: tools/deploy.sh [host] [koreader dir]
# Defaults: the Kindle at 192.168.178.34, KOReader in /mnt/us/koreader.
# Needs this Mac's key in <koreader>/settings/SSH/authorized_keys (see DEV.md).
# Restart KOReader on the device afterwards: plugins load at startup.
HOST="${1:-192.168.178.34}"
KO="${2:-/mnt/us/koreader}"
cd "$(dirname "$0")/.." || exit 1
# COPYFILE_DISABLE keeps macOS tar from adding ._ metadata files.
COPYFILE_DISABLE=1 tar -cf - _meta.lua main.lua wook*.lua data/galaxy_grid.lua data/reading_order.lua LICENSE \
    | ssh -p 2222 -o BatchMode=yes "root@$HOST" \
        "mkdir -p '$KO/plugins/wookieepedia.koplugin' && cd '$KO/plugins/wookieepedia.koplugin' && tar -xf - \
         && for f in *.lua data/*.lua; do '$KO/luajit' -e \"assert(loadfile('\$f'))\" || echo \"SYNTAX ERROR: \$f\"; done \
         && echo 'Deployed to $HOST:$KO/plugins/wookieepedia.koplugin, restart KOReader to load it.'"

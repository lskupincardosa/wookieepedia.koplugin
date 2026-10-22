#!/bin/sh
# Launch the KOReader emulator in debug mode with a book, logging to logs/koreader.log.
# Usage: tools/run.sh [book]   (default: samples/lookup-test.epub)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KOREADER_APP="${KOREADER_APP:-$HOME/Developer/koreader-app/KOReader.app}"
BOOK="${1:-$REPO/samples/lookup-test.epub}"
mkdir -p "$REPO/logs"
echo "Logging to $REPO/logs/koreader.log (Ctrl-C or close the window to quit)"
"$KOREADER_APP/Contents/MacOS/koreader" -d "$BOOK" 2>&1 | tee "$REPO/logs/koreader.log"

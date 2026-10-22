#!/bin/sh
# Runs the spec with KOReader's bundled LuaJIT (from the repo root or anywhere).
K=/Users/lucas/Developer/koreader-app/KOReader.app/Contents/koreader
cd "$(dirname "$0")/.." || exit 1
export LUA_PATH="./?.lua;$K/common/?.lua;;"
exec "$K/luajit" spec/wookhtml_spec.lua

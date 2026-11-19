#!/bin/sh
# Offline checks for the mod: XML well-formedness, Lua syntax, behaviour tests against a mocked Civ6 API.
set -e
cd "$(dirname "$0")/.."
MOD=UI_Extender

for f in "$MOD"/UI_Extender.modinfo "$MOD"/UI/*.xml "$MOD"/Text/*.xml "$MOD"/Data/*.xml; do
	xmllint --noout "$f"
done
echo "ok    xml"

for f in "$MOD"/UI/*.lua "$MOD"/Scripts/*.lua; do
	luajit -b "$f" /dev/null
done
echo "ok    lua syntax"

luajit tests/test_deal_overview.lua
luajit tests/test_deal_archive.lua

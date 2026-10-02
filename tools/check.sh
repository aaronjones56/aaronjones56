#!/usr/bin/env bash
# Vérifications locales : analyse statique (luacheck) + tests unitaires/scénarios (Lua 5.4).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== luacheck =="
# luacheck compare ses globs au chemin absolu : on analyse une copie hors du dossier « [rempart] ».
LINT="$(mktemp -d)"
trap 'rm -rf "$LINT"' EXIT
cp -r "[rempart]/rempart" "[rempart]/rempart_sensor" "$LINT/"
cp -r tests/natives "$LINT/natives"
cp .luacheckrc "$LINT/.luacheckrc"
(cd "$LINT" && luacheck --no-color rempart rempart_sensor)

echo "== tests =="
status=0
for t in tests/test_*.lua; do
    echo "-- $t"
    lua5.4 "$t" || status=1
done
exit $status

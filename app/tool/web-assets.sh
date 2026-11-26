#!/bin/sh
# Refreshes the two files the web build's database needs, matched to the
# locked package versions: sqlite3.wasm from the sqlite3.dart release, and
# drift's worker compiled from web/drift_worker.dart. Run after bumping
# sqlite3 or drift; commit what it writes.
set -eu
cd "$(dirname "$0")/.."
v=$(awk '/^  sqlite3:/{f=1} f&&/version:/{gsub(/"/,"",$2); print $2; exit}' pubspec.lock)
curl -fsSL -o web/sqlite3.wasm "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-$v/sqlite3.wasm"
dart compile js -O4 -o web/drift_worker.js web/drift_worker.dart
rm -f web/drift_worker.js.deps web/drift_worker.js.map
echo "sqlite3 $v: web/sqlite3.wasm, web/drift_worker.js"

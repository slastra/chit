#!/usr/bin/env bash
# Build the desktop app and install it for this user: the bundle in
# ~/.local/lib/chit, a launcher entry, and the fallback icon (a theme's own,
# such as tint's, wins over it: tint writes the same path on every apply).
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build linux --release
dest="$HOME/.local/lib/chit"
mkdir -p "$dest"
rsync -a --delete build/linux/x64/release/bundle/ "$dest/"
apps="$HOME/.local/share/applications"
mkdir -p "$apps"
sed "s|^Exec=chit$|Exec=$dest/chit|" linux/packaging/us.lastra.chit.desktop > "$apps/us.lastra.chit.desktop"
icon="$HOME/.local/share/icons/hicolor/scalable/apps/us.lastra.chit.svg"
mkdir -p "$(dirname "$icon")"
[ -e "$icon" ] || cp linux/packaging/us.lastra.chit.svg "$icon"
update-desktop-database "$apps" 2>/dev/null || true
echo "installed: $dest/chit"

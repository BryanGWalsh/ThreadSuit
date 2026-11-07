#!/bin/sh
# Installs Thread Suit for the current user: the release bundle, its icons
# and a desktop entry, so it shows in your app menu with its icon.
#   flutter build linux --release && linux/packaging/install.sh
#   linux/packaging/install.sh --uninstall
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
id=io.github.bryangwalsh.thread_suit
data=${XDG_DATA_HOME:-$HOME/.local/share}
app="$data/thread-suit"

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$app"
  rm -f "$data/applications/$id.desktop"
  find "$data/icons/hicolor" -name "$id.png" -delete 2>/dev/null || true
  echo "Removed Thread Suit from $data."
  exit 0
fi

bundle="$root/build/linux/x64/release/bundle"
[ -x "$bundle/thread_suit" ] || { echo "Build it first: flutter build linux --release" >&2; exit 1; }

rm -rf "$app"
mkdir -p "$app" "$data/applications"
cp -r "$bundle/." "$app/"
(cd "$here/icons" && find hicolor -name "$id.png" -exec sh -c 'mkdir -p "$1/icons/$(dirname "$2")" && cp "$2" "$1/icons/$2"' _ "$data" {} \;)
sed "s|@EXEC@|$app/thread_suit|" "$here/$id.desktop" > "$data/applications/$id.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$data/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$data/icons/hicolor" 2>/dev/null || true
echo "Installed Thread Suit to $app. Find it in your app menu."

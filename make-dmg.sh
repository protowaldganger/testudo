#!/bin/zsh
# Packs an app into a disk image with an Applications shortcut, so installing
# is a single drag. Uses only macOS's own hdiutil.
#
#   zsh make-dmg.sh path/to/App.app [output.dmg]
set -euo pipefail

APP="${1:?usage: zsh make-dmg.sh path/to/App.app [output.dmg]}"
NAME="$(basename "$APP" .app)"
OUT="${2:-$(dirname "$APP")/${NAME//[^A-Za-z0-9]/}.dmg}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc "$APP" "$STAGE/$NAME.app"
xattr -cr "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -quiet -ov -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format ULFO "$OUT"
echo "Built $(du -h "$OUT" | cut -f1)  $OUT"

#!/usr/bin/env bash
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_NAME="NimScreenRecorder"
BIN_SRC="$SCRIPT_DIR/bin/$APP_NAME"
DESKTOP_SRC="$SCRIPT_DIR/$APP_NAME.desktop"
ICON_DIR_SRC="$SCRIPT_DIR/icons"

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
DESKTOP_DIR="$APP_DIR/applications"
ICON_SCALABLE_DIR="$APP_DIR/icons/hicolor/scalable/apps"
ICON_256_DIR="$APP_DIR/icons/hicolor/256x256/apps"
BIN_DEST="$BIN_DIR/$APP_NAME"
DESKTOP_DEST="$DESKTOP_DIR/$APP_NAME.desktop"
ICON_DEST="$ICON_SCALABLE_DIR/$APP_NAME.svg"

if [ ! -f "$BIN_SRC" ]; then
  echo "Missing compiled binary: $BIN_SRC" >&2
  echo "Build the release binary first." >&2
  exit 1
fi

if [ ! -f "$DESKTOP_SRC" ]; then
  echo "Missing desktop file template: $DESKTOP_SRC" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$DESKTOP_DIR" "$ICON_SCALABLE_DIR" "$ICON_256_DIR"

install -m 755 "$BIN_SRC" "$BIN_DEST"
install -m 644 "$ICON_DIR_SRC/$APP_NAME.svg" "$ICON_SCALABLE_DIR/$APP_NAME.svg"
install -m 644 "$ICON_DIR_SRC/$APP_NAME-recording.svg" "$ICON_SCALABLE_DIR/$APP_NAME-recording.svg"
install -m 644 "$ICON_DIR_SRC/$APP_NAME-paused.svg" "$ICON_SCALABLE_DIR/$APP_NAME-paused.svg"

for icon in "$APP_NAME" "$APP_NAME-recording" "$APP_NAME-paused"; do
  if [ -f "$ICON_DIR_SRC/$icon.png" ]; then
    install -m 644 "$ICON_DIR_SRC/$icon.png" "$ICON_256_DIR/$icon.png"
  fi
done

sed \
  -e "s|@APP_BIN@|$BIN_DEST|g" \
  -e "s|@APP_ICON@|$ICON_DEST|g" \
  "$DESKTOP_SRC" > "$DESKTOP_DEST"
chmod 644 "$DESKTOP_DEST"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -q "${APP_DIR}/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Installed $APP_NAME to $BIN_DEST"

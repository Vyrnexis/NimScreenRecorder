#!/usr/bin/env bash
set -eu

APP_NAME="NimScreenRecorder"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DESKTOP_DIR="$APP_DIR/applications"
ICON_SCALABLE_DIR="$APP_DIR/icons/hicolor/scalable/apps"
ICON_256_DIR="$APP_DIR/icons/hicolor/256x256/apps"

rm -f "$BIN_DIR/$APP_NAME"
rm -f "$DESKTOP_DIR/$APP_NAME.desktop"
rm -f "$ICON_SCALABLE_DIR/$APP_NAME.svg"
rm -f "$ICON_SCALABLE_DIR/$APP_NAME-recording.svg"
rm -f "$ICON_SCALABLE_DIR/$APP_NAME-paused.svg"
rm -f "$ICON_256_DIR/$APP_NAME.png"
rm -f "$ICON_256_DIR/$APP_NAME-recording.png"
rm -f "$ICON_256_DIR/$APP_NAME-paused.png"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -q "${APP_DIR}/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Removed $APP_NAME from user-local install paths"

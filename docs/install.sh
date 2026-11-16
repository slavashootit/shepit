#!/bin/zsh
# Однорядковий інсталятор «Шепіт» для macOS (Apple Silicon)
# Завантажує свіжий реліз у /Applications/Шепіт.app, знімає карантин Gatekeeper і запускає застосунок.

set -euo pipefail

REPO="slavashootit/shepit"
ZIP_URL="https://github.com/${REPO}/releases/latest/download/Shepit-AppleSilicon.zip"
APP_DEST="/Applications/Шепіт.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Помилка: «Шепіт» працює лише на macOS."
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Помилка: потрібен Mac на процесорі Apple Silicon (M1 / M2 / M3 / M4)."
  exit 1
fi

echo "→ Завантажуємо «Шепіт» для Apple Silicon…"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL --progress-bar "$ZIP_URL" -o "$TMP_DIR/Shepit.zip"

echo "→ Розпаковуємо у /Applications/Шепіт.app…"
ditto -x -k "$TMP_DIR/Shepit.zip" "$TMP_DIR/extracted"

pkill -f "/Applications/Шепіт.app/Contents/MacOS/Shepit" 2>/dev/null || true
rm -rf "$APP_DEST"
mv "$TMP_DIR/extracted/Шепіт.app" "$APP_DEST"

# Знімаємо прапорець карантину macOS, щоб система не питала підтвердження для локального релізу
xattr -cr "$APP_DEST" 2>/dev/null || true

echo "✓ Встановлено: $APP_DEST"
echo "→ Запускаємо «Шепіт»…"
open "$APP_DEST"
echo ""
echo "Готово! Надайте доступ до Мікрофона та Доступності (Accessibility),"
echo "а у вкладці «Моделі» натисніть «Встановити локальну модель» — і тисніть правий Option (⌥)."

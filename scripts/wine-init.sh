#!/usr/bin/env bash
set -euo pipefail

WINE="${WINE:-/usr/local/bin/wine64}"
WINEPREFIX="${WINEPREFIX:-/data/.wine}"
MARKER="${WINEPREFIX}/.riftbreaker-runtime-done"

if [[ -f "${MARKER}" ]]; then
  exit 0
fi

echo "[wine-init] Preparing Wine prefix at ${WINEPREFIX}..."
mkdir -p "${WINEPREFIX}"

# Запускаємо Xvfb один раз для всіх операцій
Xvfb :99 -screen 0 1024x768x24 -nolisten tcp &
XVFB_PID=$!
export DISPLAY=:99
sleep 2

cleanup() {
  kill "${XVFB_PID}" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -f "${WINEPREFIX}/system.reg" ]]; then
  echo "[wine-init] Initialising Wine prefix..."
  "${WINE}" wineboot --init 2>/dev/null || true
  sleep 2
fi

echo "[wine-init] Installing vcrun2022 and d3dcompiler_47 (may take a few minutes)..."
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEPREFIX="${WINEPREFIX}"

if winetricks -q vcrun2022 d3dcompiler_47; then
  touch "${MARKER}"
  echo "[wine-init] Done."
else
  echo "[wine-init] WARNING: winetricks failed; server may not start. Reset wine-data volume and retry." >&2
fi
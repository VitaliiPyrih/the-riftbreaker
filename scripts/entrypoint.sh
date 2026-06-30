#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/riftbreaker}"
WINEPREFIX="${WINEPREFIX:-/data/.wine}"
CONFIG_FILE="${CONFIG_FILE:-/data/config/config.cfg}"
SAVE_MOUNT="${SAVE_MOUNT:-/data/saves}"
STEAM_USER="${STEAM_USER:-steamuser}"
WINE="/usr/local/bin/wine64"
LOG_DIR="${WINEPREFIX}/logs"
CONFIG_DEST="${INSTALL_DIR}/config.cfg"
STARTUP_CHECK_SECS="${STARTUP_CHECK_SECS:-90}"

STEAM_MODE=0
STEAM_GAME_APPID="${STEAM_GAME_APPID:-780310}"

export WINEPREFIX
export WINEDEBUG="${WINEDEBUG:--all,err+all}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "[entrypoint] ERROR: missing ${CONFIG_FILE}" >&2
  echo "[entrypoint] Copy config/config.lan.cfg.example to config/config.cfg and edit it." >&2
  exit 1
fi

WINE_USER_DIR="${WINEPREFIX}/drive_c/users/${STEAM_USER}"
WINE_SAVE_DIR="${WINE_USER_DIR}/AppData/LocalLow/The Riftbreaker - Dedicated Server/SaveGames"

copy_server_config() {
  local dest="$1"
  mkdir -p "$(dirname "${dest}")"
  sed 's/\r$//' "${CONFIG_FILE}" | sed 's/^\xEF\xBB\xBF//' > "${dest}"
}

inject_latest_save() {
  local dest="$1"
  local latest_cs

  latest_cs="$(find "${SAVE_MOUNT}" -type f -name '*.cs' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)"

  [[ -n "${latest_cs}" ]] || { echo "[entrypoint] No existing save found — starting fresh game per config"; return 0; }

  local fname save_name
  fname="$(basename "${latest_cs}" .cs)"
  save_name="$(echo "${fname}" | base64 -d 2>/dev/null)"

  [[ -n "${save_name}" ]] || return 0

  echo "[entrypoint] Auto-detected latest save: ${save_name} (${latest_cs})"

  sed -i '/^\s*set\s\+mission_save\s/d' "${dest}"
  printf '\nset mission_save "%s"\n' "${save_name}" >> "${dest}"
}

follow_server_logs() {
  local logfile="$1"
  mkdir -p "$(dirname "${logfile}")" 2>/dev/null || true
  echo "[entrypoint] Streaming ${logfile} to docker logs"
  stdbuf -oL tail -n 0 -F "${logfile}" 2>/dev/null | while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '[server] %s\n' "${line}"
  done &
}

log_search_paths() {
  local paths=(
    "${WINE_USER_DIR}/Documents/The Riftbreaker/exor_logs.txt"
    "${WINE_USER_DIR}/AppData/LocalLow/The Riftbreaker - Dedicated Server/exor_logs.txt"
  )
  if [[ -n "${SERVER_DIR:-}" ]]; then
    paths+=("${SERVER_DIR}/exor_logs.txt" "${INSTALL_DIR}/exor_logs.txt")
  fi
  printf '%s\n' "${paths[@]}"
}

start_log_watchers() {
  while IFS= read -r logfile; do
    follow_server_logs "${logfile}"
  done < <(log_search_paths)

  (
    while true; do
      find "${WINEPREFIX}" "${INSTALL_DIR}" -name 'exor_logs.txt' 2>/dev/null | while read -r logfile; do
        local hash
        hash="$(echo -n "${logfile}" | md5sum | cut -d' ' -f1)"
        if [[ ! -f "${LOG_DIR}/.watching-${hash}" ]]; then
          touch "${LOG_DIR}/.watching-${hash}"
          follow_server_logs "${logfile}"
        fi
      done
      sleep 30
    done
  ) &
}

grep_logs() {
  local pattern="$1" logfile
  while IFS= read -r logfile; do
    [[ -f "${logfile}" ]] || continue
    if grep -q "${pattern}" "${logfile}" 2>/dev/null; then
      return 0
    fi
  done < <(log_search_paths; find "${WINEPREFIX}" "${INSTALL_DIR}" -name 'exor_logs.txt' 2>/dev/null)
  return 1
}

watch_server_startup() {
  local ready_logged=0
  local deadline=$((SECONDS + STARTUP_CHECK_SECS))

  while (( SECONDS < deadline )); do
    if grep_logs 'activating: MenuState' || grep_logs 'missions/inventory.mission'; then
      echo "[entrypoint] ERROR: config was not loaded (MenuState / inventory.mission in logs)." >&2
      echo "[entrypoint] Ensure config.cfg exists at ${CONFIG_DEST} (install root, not bin/)." >&2
      pkill -f 'DedicatedServer.exe' 2>/dev/null || true
      sleep 2
      kill -TERM 1 2>/dev/null || true
      exit 1
    fi
    if (( ready_logged == 0 )) && grep_logs 'ServerGameplayState'; then
      echo "[entrypoint] Server entered ServerGameplayState — config loaded successfully"
      ready_logged=1
    fi
    if (( ready_logged == 0 )) && grep_logs '\[NetServerGNS\] running as:'; then
      echo "[entrypoint] NetServer is listening"
      ready_logged=1
    fi
    if (( ready_logged == 0 )) && (( STEAM_MODE == 1 )) && grep_logs 'listening for P2P connection as'; then
      echo "[entrypoint] Steam P2P networking is active — server should appear in the in-game server browser"
      ready_logged=1
    fi
    sleep 5
  done
}

watch_server_port() {
  if (( STEAM_MODE == 1 )); then
    echo "[entrypoint] Steam mode — traffic uses Steam relay/P2P; not waiting for a local UDP 6321 bind"
    return 0
  fi
  (
    local i
    for i in $(seq 1 36); do
      if ss -H -uln 2>/dev/null | grep -q ':6321 '; then
        echo "[entrypoint] UDP port 6321 is open — server should accept connections"
        return 0
      fi
      if ss -H -ltn 2>/dev/null | grep -q ':6321 '; then
        echo "[entrypoint] TCP port 6321 is open"
      fi
      sleep 5
    done
    echo "[entrypoint] WARNING: port 6321 not open after 3 minutes — check logs and config.cfg" >&2
  ) &
}

/scripts/install-update.sh

mkdir -p "${WINEPREFIX}" "${SAVE_MOUNT}" "${LOG_DIR}" "$(dirname "${WINE_SAVE_DIR}")"
/scripts/wine-init.sh

link_save_dir() {
  local dir="$1"
  mkdir -p "$(dirname "${dir}")"
  rm -rf "${dir}"
  ln -sfn "${SAVE_MOUNT}" "${dir}"
  echo "[entrypoint] Save symlink: ${dir} -> ${SAVE_MOUNT}"
}

link_save_dir "${WINE_USER_DIR}/Documents/The Riftbreaker"

SERVER_EXE="$(find "${INSTALL_DIR}" -iname 'DedicatedServer.exe' -print -quit 2>/dev/null || true)"
if [[ -z "${SERVER_EXE}" || ! -f "${SERVER_EXE}" ]]; then
  echo "[entrypoint] ERROR: DedicatedServer.exe not found in ${INSTALL_DIR}" >&2
  exit 1
fi

SERVER_DIR="$(dirname "${SERVER_EXE}")"

# steamclient DLLs must be in bin/ for Wine to find them
ln -sf "${INSTALL_DIR}/steamclient.dll"   "${SERVER_DIR}/steamclient.dll"   2>/dev/null || true
ln -sf "${INSTALL_DIR}/steamclient64.dll" "${SERVER_DIR}/steamclient64.dll" 2>/dev/null || true

# tier0_s64 and vstdlib_s64 are required by steamclient64.dll.
# Downloaded at build time via app 1007 (Steamworks SDK Redist) into /opt/steam-sdk-win.
WINE_SYS="${WINEPREFIX}/drive_c/windows/system32"
mkdir -p "${WINE_SYS}"

STEAM_SDK_SEARCH=(
    "/opt/steam-sdk-win/redistributable_bin/win64"
    "/opt/steam-sdk-win"
    "/home/${STEAM_USER}/.steam/sdk64"
    "/root/.steam/sdk64"
)

echo "[entrypoint] Linking Steam SDK dependencies (tier0_s64, vstdlib_s64)..."
sdk_found=0
for sdk_path in "${STEAM_SDK_SEARCH[@]}"; do
    if [[ -f "${sdk_path}/tier0_s64.dll" ]]; then
        echo "[entrypoint] Found Steam SDK at ${sdk_path}"
        for dll in tier0_s64.dll vstdlib_s64.dll steamclient64.dll; do
            if [[ -f "${sdk_path}/${dll}" ]]; then
                ln -sf "${sdk_path}/${dll}" "${WINE_SYS}/${dll}"
                echo "[entrypoint] Linked ${dll} -> ${WINE_SYS}/${dll}"
            else
                echo "[entrypoint] WARNING: ${dll} not found in ${sdk_path}" >&2
            fi
        done
        sdk_found=1
        break
    fi
done

if (( sdk_found == 0 )); then
    echo "[entrypoint] WARNING: Steam SDK DLLs not found — SteamGameServer_Init may fail" >&2
    echo "[entrypoint] Searched: ${STEAM_SDK_SEARCH[*]}" >&2
    echo "[entrypoint] Contents of /opt/steam-sdk-win/:" >&2
    find /opt/steam-sdk-win -name "*.dll" 2>/dev/null | head -20 || true
fi

copy_server_config "${CONFIG_DEST}"
rm -f "${SERVER_DIR}/config.cfg"

if [[ "${AUTO_LOAD_LATEST_SAVE:-1}" == "1" ]]; then
  inject_latest_save "${CONFIG_DEST}"
fi

if ! grep -q 'set app_mode "server"' "${CONFIG_DEST}" 2>/dev/null; then
  echo "[entrypoint] WARNING: set app_mode \"server\" not found in ${CONFIG_DEST}" >&2
fi

if grep -E '^\s*set\s+disable_steam\s+"1"' "${CONFIG_DEST}" >/dev/null 2>&1; then
  STEAM_MODE=0
else
  STEAM_MODE=1
fi

if (( STEAM_MODE == 0 )); then
  rm -f "${SERVER_DIR}/steam_appid.txt" "${INSTALL_DIR}/steam_appid.txt" 2>/dev/null || true
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=},steamclient=n,b,steam_api64=n,b"
  unset SteamAppId SteamGameId STEAMAPPID LD_LIBRARY_PATH 2>/dev/null || true
  echo "[entrypoint] LAN mode (disable_steam \"1\") — STEAMAPPID cleared for game process"
else
  echo "${STEAM_GAME_APPID}" > "${SERVER_DIR}/steam_appid.txt"
  echo "${STEAM_GAME_APPID}" > "${INSTALL_DIR}/steam_appid.txt"
  export STEAMAPPID="${STEAM_GAME_APPID}"
  export SteamAppId="${STEAM_GAME_APPID}"
  export SteamGameId="${STEAM_GAME_APPID}"
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
  echo "[entrypoint] Steam mode — app id ${STEAM_GAME_APPID}; server should appear in the in-game server browser"
fi

cd "${SERVER_DIR}"

start_log_watchers
watch_server_port

echo "[entrypoint] Active config at ${CONFIG_DEST}:"
grep -vE '^\s*//' "${CONFIG_DEST}" | grep -vE '^\s*$' || true

watch_server_startup &

echo "[entrypoint] Deployed config: ${CONFIG_DEST}"
echo "[entrypoint] Starting: DedicatedServer.exe cli=1 config=config.cfg (cwd=${SERVER_DIR})"

rm -f /tmp/.X99-lock 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x16 &
sleep 2
export DISPLAY=:99.0

if (( STEAM_MODE == 0 )); then
  exec env -u SteamAppId -u SteamGameId -u STEAMAPPID -u LD_LIBRARY_PATH \
    env DISPLAY=:99.0 "${WINE}" DedicatedServer.exe cli=1 config=config.cfg 2>&1
else
  exec env DISPLAY=:99.0 "${WINE}" DedicatedServer.exe cli=1 config=config.cfg 2>&1
fi
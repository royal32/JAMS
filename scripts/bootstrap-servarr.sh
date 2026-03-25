#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  source "${ROOT_DIR}/.env"
  set +a
fi

if [[ -f "${ROOT_DIR}/bootstrap.env" ]]; then
  set -a
  source "${ROOT_DIR}/bootstrap.env"
  set +a
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

log() {
  printf '[bootstrap] %s\n' "$*"
}

fail() {
  printf '[bootstrap] %s\n' "$*" >&2
  exit 1
}

require_cmd curl
require_cmd jq

BOOTSTRAP_TIMEOUT_SECONDS="${BOOTSTRAP_TIMEOUT_SECONDS:-180}"
BOOTSTRAP_MEDIA_DIR_MODE="${BOOTSTRAP_MEDIA_DIR_MODE:-0777}"
MEDIA_ROOT="${MEDIA_ROOT:-/mnt/ssd/jellyfin/media}"
DOWNLOADS_ROOT="${DOWNLOADS_ROOT:-/mnt/ssd/jellyfin/media/downloads}"

QBIT_URL="${QBIT_URL:-http://127.0.0.1:8080}"
QBIT_USERNAME="${QBIT_USERNAME:-}"
QBIT_PASSWORD="${QBIT_PASSWORD:-}"

RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"

RADARR_QBIT_HOST="${RADARR_QBIT_HOST:-host.docker.internal}"
SONARR_QBIT_HOST="${SONARR_QBIT_HOST:-host.docker.internal}"
RADARR_QBIT_PORT="${RADARR_QBIT_PORT:-8080}"
SONARR_QBIT_PORT="${SONARR_QBIT_PORT:-8080}"

RADARR_DOWNLOAD_CLIENT_NAME="${RADARR_DOWNLOAD_CLIENT_NAME:-qBittorrent}"
SONARR_DOWNLOAD_CLIENT_NAME="${SONARR_DOWNLOAD_CLIENT_NAME:-qBittorrent}"

RADARR_ROOT_FOLDER="${RADARR_ROOT_FOLDER:-/media/Movies}"
SONARR_ROOT_FOLDER="${SONARR_ROOT_FOLDER:-/media/tv}"
RADARR_REMOTE_PATH="${RADARR_REMOTE_PATH:-$DOWNLOADS_ROOT}"
SONARR_REMOTE_PATH="${SONARR_REMOTE_PATH:-$DOWNLOADS_ROOT}"
RADARR_LOCAL_PATH="${RADARR_LOCAL_PATH:-/downloads}"
SONARR_LOCAL_PATH="${SONARR_LOCAL_PATH:-/downloads}"

RADARR_CONFIG_PATH="${RADARR_CONFIG_PATH:-${ROOT_DIR}/radarr/config.xml}"
SONARR_CONFIG_PATH="${SONARR_CONFIG_PATH:-${ROOT_DIR}/sonarr/config.xml}"

[[ -n "$QBIT_USERNAME" ]] || fail "Set QBIT_USERNAME in bootstrap.env"
[[ -n "$QBIT_PASSWORD" ]] || fail "Set QBIT_PASSWORD in bootstrap.env"

extract_api_key() {
  local config_path="$1"

  [[ -f "$config_path" ]] || return 1
  perl -ne 'print "$1\n" and exit if /<ApiKey>([^<]+)/' "$config_path"
}

wait_for_file() {
  local label="$1"
  local path="$2"
  local started_at
  started_at="$(date +%s)"

  until [[ -s "$path" ]]; do
    if (( "$(date +%s)" - started_at >= BOOTSTRAP_TIMEOUT_SECONDS )); then
      fail "Timed out waiting for ${label} at ${path}"
    fi
    sleep 2
  done
}

wait_for_servarr() {
  local label="$1"
  local base_url="$2"
  local api_key="$3"
  local started_at
  started_at="$(date +%s)"

  until curl -fsS \
    -H "X-Api-Key: ${api_key}" \
    "${base_url}/api/v3/system/status" >/dev/null 2>&1; do
    if (( "$(date +%s)" - started_at >= BOOTSTRAP_TIMEOUT_SECONDS )); then
      fail "Timed out waiting for ${label} at ${base_url}"
    fi
    sleep 2
  done
}

qbit_cookie_jar=""

qbit_login() {
  local cookie_jar="$1"
  local response

  response="$(
    curl -fsS \
      -c "$cookie_jar" \
      -b "$cookie_jar" \
      -H "Referer: ${QBIT_URL}" \
      -H "Origin: ${QBIT_URL}" \
      --data-urlencode "username=${QBIT_USERNAME}" \
      --data-urlencode "password=${QBIT_PASSWORD}" \
      "${QBIT_URL}/api/v2/auth/login"
  )" || return 1

  [[ "$response" == "Ok." ]]
}

wait_for_qbit() {
  local cookie_jar="$1"
  local started_at
  started_at="$(date +%s)"

  until qbit_login "$cookie_jar" >/dev/null 2>&1; do
    if (( "$(date +%s)" - started_at >= BOOTSTRAP_TIMEOUT_SECONDS )); then
      fail "Timed out waiting for qBittorrent at ${QBIT_URL}"
    fi
    sleep 2
  done
}

qbit_post_form() {
  local path="$1"
  shift

  curl -fsS \
    -b "$qbit_cookie_jar" \
    -H "Referer: ${QBIT_URL}" \
    -H "Origin: ${QBIT_URL}" \
    "$@" \
    "${QBIT_URL}${path}"
}

servarr_api() {
  local method="$1"
  local base_url="$2"
  local api_key="$3"
  local path="$4"
  local body="${5:-}"
  local response_file
  local response_code
  local response_body

  response_file="$(mktemp)"

  if [[ -n "$body" ]]; then
    response_code="$(
      curl -sS \
        -o "$response_file" \
        -w '%{http_code}' \
        -X "$method" \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "${base_url}${path}"
    )"
  else
    response_code="$(
      curl -sS \
        -o "$response_file" \
        -w '%{http_code}' \
        -X "$method" \
        -H "X-Api-Key: ${api_key}" \
        "${base_url}${path}"
    )"
  fi

  response_body="$(cat "$response_file")"
  rm -f "$response_file"

  if [[ ! "$response_code" =~ ^2 ]]; then
    fail "Servarr API ${method} ${path} failed (${response_code}): ${response_body}"
  fi

  printf '%s' "$response_body"
}

ensure_directory_mode() {
  local path="$1"

  [[ -e "$path" ]] || return
  chmod "$BOOTSTRAP_MEDIA_DIR_MODE" "$path"
}

mount_type_for_path() {
  local path="$1"
  local mount_point

  mount_point="$(df "$path" 2>/dev/null | awk 'END {print $NF}')"
  [[ -n "$mount_point" ]] || return 1

  mount | sed -nE "s#^.* on ${mount_point//\//\\/} \\(([^,]+).*\$#\\1#p" | head -n 1
}

ensure_root_folder() {
  local label="$1"
  local base_url="$2"
  local api_key="$3"
  local folder_path="$4"
  local folders

  folders="$(servarr_api GET "$base_url" "$api_key" "/api/v3/rootfolder")"
  if jq -e --arg folder_path "$folder_path" '.[] | select(.path == $folder_path)' <<<"$folders" >/dev/null; then
    log "${label}: root folder already present at ${folder_path}"
    return
  fi

  servarr_api POST "$base_url" "$api_key" "/api/v3/rootfolder" \
    "$(jq -n --arg folder_path "$folder_path" '{path: $folder_path}')" >/dev/null
  log "${label}: added root folder ${folder_path}"
}

ensure_remote_path_mapping() {
  local label="$1"
  local base_url="$2"
  local api_key="$3"
  local host="$4"
  local remote_path="$5"
  local local_path="$6"
  local mappings

  mappings="$(servarr_api GET "$base_url" "$api_key" "/api/v3/remotepathmapping")"
  if jq -e \
    --arg host "$host" \
    --arg remote_path "$remote_path" \
    --arg local_path "$local_path" \
    '.[] | select(.host == $host and .remotePath == $remote_path and .localPath == $local_path)' \
    <<<"$mappings" >/dev/null; then
    log "${label}: remote path mapping already present"
    return
  fi

  servarr_api POST "$base_url" "$api_key" "/api/v3/remotepathmapping" \
    "$(jq -n \
      --arg host "$host" \
      --arg remote_path "$remote_path" \
      --arg local_path "$local_path" \
      '{host: $host, remotePath: $remote_path, localPath: $local_path}')" >/dev/null
  log "${label}: added remote path mapping ${remote_path} -> ${local_path}"
}

ensure_qbit_download_client() {
  local label="$1"
  local base_url="$2"
  local api_key="$3"
  local client_name="$4"
  local qbit_host="$5"
  local qbit_port="$6"
  local download_clients
  local existing_client
  local payload
  local method

  download_clients="$(servarr_api GET "$base_url" "$api_key" "/api/v3/downloadclient")"
  existing_client="$(
    jq -c \
      --arg client_name "$client_name" \
      'map(
        select(
          (.implementation // "") == "QBittorrent" or
          (.implementationName // "") == "qBittorrent" or
          .name == $client_name
        )
      ) | first // empty' <<<"$download_clients"
  )"

  if [[ -n "$existing_client" ]]; then
    payload="$existing_client"
    method="PUT"
  else
    payload="$(
      servarr_api GET "$base_url" "$api_key" "/api/v3/downloadclient/schema" |
        jq -c 'map(
          select(
            (.implementation // "") == "QBittorrent" or
            (.implementationName // "") == "qBittorrent"
          )
        ) | first // empty'
    )"
    [[ -n "$payload" ]] || fail "${label}: could not find qBittorrent schema in download client API"
    method="POST"
  fi

  payload="$(
    jq -c \
      --arg client_name "$client_name" \
      --arg qbit_host "$qbit_host" \
      --argjson qbit_port "$qbit_port" \
      --arg username "$QBIT_USERNAME" \
      --arg password "$QBIT_PASSWORD" \
      '
      def upsert_field($name; $value):
        .fields = (.fields // [])
        | if ([.fields[]? | select(.name == $name)] | length) > 0 then
            .fields |= map(if .name == $name then .value = $value else . end)
          else
            .fields += [{"name": $name, "value": $value}]
          end;

      .
      | .enable = true
      | .name = $client_name
      | .priority = (.priority // 1)
      | upsert_field("host"; $qbit_host)
      | upsert_field("port"; $qbit_port)
      | upsert_field("useSsl"; false)
      | upsert_field("urlBase"; "")
      | upsert_field("username"; $username)
      | upsert_field("password"; $password)
      ' <<<"$payload"
  )"

  servarr_api "$method" "$base_url" "$api_key" "/api/v3/downloadclient" "$payload" >/dev/null
  log "${label}: ensured qBittorrent download client ${client_name}"
}

log "Creating shared media folders"
mkdir -p "${MEDIA_ROOT}" "${MEDIA_ROOT}/Movies" "${MEDIA_ROOT}/tv" "$DOWNLOADS_ROOT"
ensure_directory_mode "${MEDIA_ROOT}"
ensure_directory_mode "${MEDIA_ROOT}/Movies"
ensure_directory_mode "${MEDIA_ROOT}/tv"
ensure_directory_mode "$DOWNLOADS_ROOT"
log "Set media directory mode to ${BOOTSTRAP_MEDIA_DIR_MODE}"

MEDIA_ROOT_MOUNT_TYPE="$(mount_type_for_path "${MEDIA_ROOT}" || true)"
if [[ "$MEDIA_ROOT_MOUNT_TYPE" == "smbfs" ]]; then
  fail "MEDIA_ROOT (${MEDIA_ROOT}) is on an smbfs mount. In this setup, Radarr and Sonarr reject smbfs-backed root folders during validation even when shell writes succeed. Use a local path on the Mac or mount the SMB share directly inside Docker with a CIFS volume instead of bind-mounting /Volumes."
fi

wait_for_file "Radarr config" "$RADARR_CONFIG_PATH"
wait_for_file "Sonarr config" "$SONARR_CONFIG_PATH"

RADARR_API_KEY="$(extract_api_key "$RADARR_CONFIG_PATH")"
SONARR_API_KEY="$(extract_api_key "$SONARR_CONFIG_PATH")"

[[ -n "$RADARR_API_KEY" ]] || fail "Could not extract Radarr API key from ${RADARR_CONFIG_PATH}"
[[ -n "$SONARR_API_KEY" ]] || fail "Could not extract Sonarr API key from ${SONARR_CONFIG_PATH}"

log "Waiting for Radarr and Sonarr APIs"
wait_for_servarr "Radarr" "$RADARR_URL" "$RADARR_API_KEY"
wait_for_servarr "Sonarr" "$SONARR_URL" "$SONARR_API_KEY"

qbit_cookie_jar="$(mktemp)"
trap 'rm -f "$qbit_cookie_jar"' EXIT

log "Waiting for qBittorrent Web UI"
wait_for_qbit "$qbit_cookie_jar"
qbit_login "$qbit_cookie_jar" || fail "qBittorrent login failed"

log "Configuring qBittorrent default save path"
qbit_post_form "/api/v2/app/setPreferences" \
  --data-urlencode "json=$(jq -cn --arg save_path "$DOWNLOADS_ROOT" '{save_path: $save_path}')" >/dev/null

log "Configuring Radarr"
ensure_root_folder "Radarr" "$RADARR_URL" "$RADARR_API_KEY" "$RADARR_ROOT_FOLDER"
ensure_remote_path_mapping "Radarr" "$RADARR_URL" "$RADARR_API_KEY" "$RADARR_QBIT_HOST" "$RADARR_REMOTE_PATH" "$RADARR_LOCAL_PATH"
ensure_qbit_download_client "Radarr" "$RADARR_URL" "$RADARR_API_KEY" "$RADARR_DOWNLOAD_CLIENT_NAME" "$RADARR_QBIT_HOST" "$RADARR_QBIT_PORT"

log "Configuring Sonarr"
ensure_root_folder "Sonarr" "$SONARR_URL" "$SONARR_API_KEY" "$SONARR_ROOT_FOLDER"
ensure_remote_path_mapping "Sonarr" "$SONARR_URL" "$SONARR_API_KEY" "$SONARR_QBIT_HOST" "$SONARR_REMOTE_PATH" "$SONARR_LOCAL_PATH"
ensure_qbit_download_client "Sonarr" "$SONARR_URL" "$SONARR_API_KEY" "$SONARR_DOWNLOAD_CLIENT_NAME" "$SONARR_QBIT_HOST" "$SONARR_QBIT_PORT"

log "Bootstrap complete"

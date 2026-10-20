#!/bin/bash

# Exit script on failure
set -e

# Globals
STEAM_UPDATE_CHECK_INTERVAL_SECONDS=1800
PUBLIC_BUILD_ID=""
export RSDW_LAUNCH="${STEAMAPPDIR}/RSDragonwildsServer.sh"
export RSDW_CONFIG="${STEAMAPPDIR}/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"

# Functions

function split_quoted_args() {
  local input="$1"
  local parsed_file=""

  parsed_file=$(mktemp "${TMPDIR:-/tmp}/rsdw-quoted-args.XXXXXX") || {
    echo "Error: failed to create temp file for quoted arguments" >&2
    return 1
  }

  if [[ -n "$input" ]]; then
    if ! printf '%s\n' "$input" | xargs -n1 printf '%s\n' > "$parsed_file"; then
      echo "Error: failed to parse quoted arguments: ${input}" >&2
      rm -f "$parsed_file"
      return 1
    fi
  fi

  printf '%s\n' "$parsed_file"
}

function get_installed_build_id() {
  local manifest="${STEAMAPPDIR}/steamapps/appmanifest_${STEAMAPPID}.acf"

  if [[ ! -f "${manifest}" ]]; then
    echo "Warning: app manifest is unavailable at ${manifest}" >&2
    return 1
  fi

  jq -Rrn --rawfile acf "${manifest}" '
    $acf
    | capture("\"buildid\"\\s+\"(?<buildid>[0-9]+)\"").buildid
  ' 2>/dev/null
}

function parse_public_build_id() {
  local app_info_file="$1"

  # app_info_print uses Valve's KeyValues format. Track the enclosing keys so
  # build IDs for other branches or depots cannot be mistaken for `public`.
  awk -v app_id="${STEAMAPPID}" '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)

      if (line == "{") {
        depth++
        stack[depth] = pending
        pending = ""
        next
      }

      if (line == "}") {
        delete stack[depth]
        depth--
        pending = ""
        next
      }

      if (line ~ /^"buildid"[[:space:]]+"[0-9]+"$/ \
          && stack[depth] == "public" \
          && stack[depth - 1] == "branches" \
          && stack[depth - 2] == "depots" \
          && stack[depth - 3] == app_id) {
        sub(/^"buildid"[[:space:]]+"/, "", line)
        sub(/"$/, "", line)
        if (!found) {
          build_id = line
          found = 1
        } else if (line != build_id) {
          conflicting = 1
        }
        next
      }

      if (line ~ /^"[^"]+"$/) {
        sub(/^"/, "", line)
        sub(/"$/, "", line)
        pending = line
      } else {
        pending = ""
      }
    }

    END {
      if (!found || conflicting) {
        exit 1
      }
      print build_id
    }
  ' "${app_info_file}"
}

function get_public_build_id() {
  local steam_user_home="${1:-${HOME}}"
  local max_attempts=3
  local attempt=0
  local app_info_file=""
  local -a parsed_build_ids=()
  local steamcmd_rc=0
  local -a app_info_cache_files=(
    "${STEAMCMDDIR}/appcache/appinfo.vdf"
    "${steam_user_home}/Steam/appcache/appinfo.vdf"
    "${steam_user_home}/.local/share/Steam/appcache/appinfo.vdf"
  )

  PUBLIC_BUILD_ID=""
  app_info_file=$(mktemp "${TMPDIR:-/tmp}/rsdw-app-info.XXXXXX") || {
    echo "Warning: failed to create temporary file for Steam app info." >&2
    return 1
  }

  while (( attempt < max_attempts )); do
    if [[ "${shutdown_requested:-false}" == "true" ]]; then
      rm -f "${app_info_file}"
      return 1
    fi

    attempt=$((attempt + 1))

    # Force SteamCMD to request fresh app metadata instead of accepting a stale
    # app-info cache. These paths cover the SteamCMD and Steam client layouts.
    if ! rm -f "${app_info_cache_files[@]}"; then
      echo "Warning: failed to clear the Steam app-info cache (attempt ${attempt}/${max_attempts})." >&2
      continue
    fi

    if [[ "${shutdown_requested:-false}" == "true" ]]; then
      rm -f "${app_info_file}"
      return 1
    fi

    : > "${app_info_file}"
    timeout --signal=TERM --kill-after=10s 60s \
      bash "${STEAMCMDDIR}/steamcmd.sh" \
      +login anonymous \
      +app_info_update 1 \
      +app_info_print "${STEAMAPPID}" \
      +quit > "${app_info_file}" 2>&1 &
    update_check_pid=$!

    if wait "${update_check_pid}"; then
      steamcmd_rc=0
    else
      steamcmd_rc=$?
    fi
    update_check_pid=""

    if [[ "${shutdown_requested:-false}" == "true" ]]; then
      rm -f "${app_info_file}"
      return 1
    fi

    if (( steamcmd_rc != 0 )); then
      echo "Warning: SteamCMD app-info lookup failed with exit code ${steamcmd_rc} (attempt ${attempt}/${max_attempts})." >&2
      continue
    fi

    parsed_build_ids=()
    mapfile -t parsed_build_ids < <(parse_public_build_id "${app_info_file}")
    if (( ${#parsed_build_ids[@]} == 1 )) \
      && [[ "${parsed_build_ids[0]}" =~ ^[0-9]+$ ]]; then
      PUBLIC_BUILD_ID="${parsed_build_ids[0]}"
      rm -f "${app_info_file}"
      return 0
    fi

    echo "Warning: SteamCMD returned no unique, valid public build ID (attempt ${attempt}/${max_attempts})." >&2
  done

  rm -f "${app_info_file}"
  return 1
}

function download() {

  # Create App Dir
  mkdir -p "${STEAMAPPDIR}"

  # Download Game Server
  if [[ -n "$DEVBUILD_PRESIGNED_URL" ]]; then
    # Dev Builds can not be auto updated
    AUTO_UPDATE="false"

    # Download Dev build (zip archive) if URL provided
    curl -o build.zip "${DEVBUILD_PRESIGNED_URL}"
    unzip -o build.zip -d "${STEAMAPPDIR}"
  else
    # Dev Builds can not be auto updated
    AUTO_UPDATE="true"

    # Else, download live build from Steam
    if [[ "$STEAMAPPVALIDATE" -eq 1 ]]; then
        VALIDATE="validate"
    else
        VALIDATE=""
    fi

    ## SteamCMD can fail to download
    ## Retry logic
    MAX_ATTEMPTS=3
    steamcmd_rc=1
    attempt=0
    while (( steamcmd_rc != 0 && attempt < MAX_ATTEMPTS )); do
        ((attempt+=1))
        if [[ $attempt -gt 1 ]]; then
            echo "Retrying SteamCMD, attempt ${attempt}"
            # Stale appmanifest data can lead for HTTP 401 errors when requesting old
            # files from SteamPipe CDN
            echo "Removing steamapps (appmanifest data)..."
            rm -rf "${STEAMAPPDIR}/steamapps"
        fi
        local steamcmd_cmd=(bash "${STEAMCMDDIR}/steamcmd.sh")
        local steamcmd_spew=()
        if [[ -n "${STEAMCMD_SPEW:-}" ]]; then
            local steamcmd_spew_file=""
            if ! steamcmd_spew_file="$(split_quoted_args "${STEAMCMD_SPEW}")"; then
                return 1
            fi
            while IFS= read -r line || [[ -n "$line" ]]; do
                steamcmd_spew+=("$line")
            done < "${steamcmd_spew_file}"
            rm -f "${steamcmd_spew_file}"
            steamcmd_cmd+=("${steamcmd_spew[@]}")
        fi
        steamcmd_cmd+=(
            +force_install_dir "${STEAMAPPDIR}"
            +@bClientTryRequestManifestWithoutCode 1
            +login anonymous
            +app_update "${STEAMAPPID}"
        )
        if [[ -n "${VALIDATE}" ]]; then
            steamcmd_cmd+=("${VALIDATE}")
        fi
        steamcmd_cmd+=(+quit)
        if "${steamcmd_cmd[@]}"; then
            steamcmd_rc=0
        else
            steamcmd_rc=$?
        fi
    done

    ## Exit if steamcmd fails
    if [[ $steamcmd_rc != 0 ]]; then
        exit $steamcmd_rc
    fi

    if STEAMPIPE_BUILD_ID="$(get_installed_build_id)"; then
        echo "Installed Steam build ID: ${STEAMPIPE_BUILD_ID}"
    else
        echo "Warning: installed BuildID is unavailable; auto-update will be disabled for this run."
        AUTO_UPDATE="false"
    fi
  fi
}

function start() {
  # Server start wrapper function
  # When AUTO_UPDATE is "true" this function attempts to detect updates to the SteamPipe depot
  # and will stop the server when a new version is available.
  # Users are expected to couple this container with an orchestrator such as Systemd/Podman, EKS,
  # or K8S, which will resurrect/restart the container automatically on exit.
  local server_pid=""
  local sleep_pid=""
  local update_check_pid=""
  local shutdown_requested="false"

  cleanup() {
    shutdown_requested="true"
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
      kill -TERM "$server_pid" 2>/dev/null || true
    fi
    if [[ -n "$sleep_pid" ]] && kill -0 "$sleep_pid" 2>/dev/null; then
      kill -TERM "$sleep_pid" 2>/dev/null || true
    fi
    if [[ -n "$update_check_pid" ]] && kill -0 "$update_check_pid" 2>/dev/null; then
      kill -TERM "$update_check_pid" 2>/dev/null || true
    fi
  }

  trap cleanup SIGINT SIGTERM

  echo "Launching RSDragonwildsServer.sh"

  local server_cmd=(
    bash "${RSDW_LAUNCH}"
    -Port="${RSDW_PORT}"
    -BeaconPort="${RSDW_BEACON_PORT}"
  )
  local additional_args=()

  if [[ "$GAMELIFT" == "true" ]] ; then
    server_cmd=(
      "${HOME}/gamelift-wrapper"
    )
  else
    if [[ -n "${RSDW_ADDITIONAL_ARGS:-}" ]]; then
      local additional_args_file=""
      if ! additional_args_file="$(split_quoted_args "${RSDW_ADDITIONAL_ARGS}")"; then
        exit 1
      fi
      while IFS= read -r line || [[ -n "$line" ]]; do
        additional_args+=("$line")
      done < "${additional_args_file}"
      rm -f "${additional_args_file}"
      server_cmd+=("${additional_args[@]}")
    fi

    # Line-buffer the server's stdout so each log line reaches the container log immediately.
    # -FORCELOGFLUSH also does that, but by fdatasyncing the log file per line on the game thread,
    # which stalls the server whenever it logs in bursts.
    if [[ "$RSDW_LINE_BUFFERED_LOGS" == "true" ]]; then
      local stdbuf_lib="/usr/libexec/coreutils/libstdbuf.so"
      if [[ -f "$stdbuf_lib" ]]; then
        server_cmd=(env _STDBUF_O=L "LD_PRELOAD=${stdbuf_lib}${LD_PRELOAD:+:${LD_PRELOAD}}" "${server_cmd[@]}")
      else
        echo "Warning: ${stdbuf_lib} not found; server logs will be block-buffered."
      fi
    fi
  fi

  if [[ "$AUTO_UPDATE" == "true" ]]; then
    "${server_cmd[@]}" &
    server_pid=$!

    while kill -0 "$server_pid" 2>/dev/null; do
      sleep "${STEAM_UPDATE_CHECK_INTERVAL_SECONDS}" &
      sleep_pid=$!
      # Wake when either the server or the update interval ends. This prevents
      # a crashed server from leaving the container alive until the timer
      # completes.
      wait -n "$server_pid" "$sleep_pid" 2>/dev/null || true

      if [[ "${shutdown_requested}" == "true" ]]; then
        if kill -0 "$sleep_pid" 2>/dev/null; then
          kill -TERM "$sleep_pid" 2>/dev/null || true
        fi
        wait "$sleep_pid" 2>/dev/null || true
        sleep_pid=""
        break
      fi

      # If the server exited first, stop and reap the outstanding timer so the
      # entrypoint can return immediately.
      if ! kill -0 "$server_pid" 2>/dev/null; then
        if kill -0 "$sleep_pid" 2>/dev/null; then
          kill -TERM "$sleep_pid" 2>/dev/null || true
        fi
        wait "$sleep_pid" 2>/dev/null || true
        sleep_pid=""
        break
      fi
      sleep_pid=""

      # Compare the locally installed build against the current public branch.
      local required_version=""
      if get_public_build_id; then
        if [[ "${shutdown_requested}" == "true" ]]; then
          break
        fi
        required_version="${PUBLIC_BUILD_ID}"
        if [[ "${required_version}" != "${STEAMPIPE_BUILD_ID}" ]]; then
          # Stopping on update is opt-in; restart behavior belongs to the container runtime or orchestrator.
          if [[ "$RSDW_AUTO_STOP_ON_UPDATE" == "true" ]]; then
            echo "New Steam version is available (installed=${STEAMPIPE_BUILD_ID}, required=${required_version}), stopping server."
            kill -TERM "$server_pid" 2>/dev/null || true
            break
          else
            echo "New Steam version is available (installed=${STEAMPIPE_BUILD_ID}, required=${required_version}), but RSDW_AUTO_STOP_ON_UPDATE is disabled; continuing to run current server."
          fi
        fi
      else
        if [[ "${shutdown_requested}" == "true" ]]; then
          break
        fi
        echo "Warning: failed to determine the current public Steam build ID; continuing with current server process." >&2
      fi
    done

    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  else
    "${server_cmd[@]}"
  fi
}

# MAIN

# Debug handling

## Steamcmd debugging
DEBUG="${DEBUG:-0}"
STEAMAPPVALIDATE="${STEAMAPPVALIDATE:-0}"
RSDW_AUTO_STOP_ON_UPDATE="${RSDW_AUTO_STOP_ON_UPDATE:-false}"
RSDW_LINE_BUFFERED_LOGS="${RSDW_LINE_BUFFERED_LOGS:-true}"

if [[ "$DEBUG" -eq 1 ]] || [[ "$DEBUG" -eq 3 ]]; then
    STEAMCMD_SPEW="+set_spew_level 4 4"
fi
## RSDW server debugging
if [[ "$DEBUG" -eq 2 ]] || [[ "$DEBUG" -eq 3 ]]; then
    export RSDW_LOG="on"
fi

# FIX: steamclient.so fix
mkdir -p ~/.steam/sdk64
ln -sfT "${STEAMCMDDIR}/linux64/steamclient.so" ~/.steam/sdk64/steamclient.so

# Parse Environment Variables

## Bridge legacy additional arguments env var to canonical name
if [[ -z "${RSDW_ADDITIONAL_ARGS:-}" && -n "${RSDW_ADDITIONAL_ARGUMENTS:-}" ]]; then
  export RSDW_ADDITIONAL_ARGS="${RSDW_ADDITIONAL_ARGUMENTS}"
fi

# Ensure an Owner ID is set, as this is required
if [[ -z "$RSDW_OWNER_ID" ]]; then
  echo "Error: RSDW_OWNER_ID environment variable is not set."
  echo "Please set RSDW_OWNER_ID to the EOS ID of the user who will own the server. You can find this ingame under 'Settings'"
  echo "See: https://dragonwilds.runescape.wiki/w/Dedicated_Servers"
  exit 1
else
  echo "RSDW_OWNER_ID set to: ${RSDW_OWNER_ID}"
fi

## Generate random passwords, if required
if [[ "$GAMELIFT" == "false" ]] ; then
  if [[ "$RSDW_PASSWORD" == "random" ]]; then
    export RSDW_PASSWORD="$(pwgen -AB 12 1)"
    echo "RSDW_PASSWORD set to: ${RSDW_PASSWORD}"
  fi

  if [[ "$RSDW_ADMIN_PASSWORD" == "random" ]]; then
    export RSDW_ADMIN_PASSWORD="$(pwgen -AB 12 1)"
    echo "RSDW_ADMIN_PASSWORD set to: ${RSDW_ADMIN_PASSWORD}"
  fi

  ## Check that World name is set
  if [[ -z "${RSDW_WORLD_NAME}" ]]; then
    export RSDW_WORLD_NAME="$(shuf -n 1 /etc/default/DedicatedServer.names)"
    echo "RSDW_WORLD_NAME set to: ${RSDW_WORLD_NAME}"
  fi
fi

# Download Dedicated Server
download

# Template configuration files
mkdir -p "${STEAMAPPDIR}/RSDragonwilds/Saved/Config/LinuxServer/"
envsubst < /etc/default/DedicatedServer.ini > "${RSDW_CONFIG}"
envsubst < /etc/default/gamelift_config.yaml > "${HOME}/config.yaml"

# Switch to server directory
cd "${STEAMAPPDIR}/RSDragonwilds/"

# Fix file permissions for Crash_handler
/bin/chmod +x "${STEAMAPPDIR}/RSDragonwilds/Plugins/Developer/Sentry/Binaries/Linux/crashpad_handler"

# Start Server
start

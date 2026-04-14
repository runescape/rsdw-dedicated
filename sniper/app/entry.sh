#!/bin/bash

# Exit script on failure
set -e

# Globals
STEAM_UPTODATECHECK_API="https://api.steampowered.com/ISteamApps/UpToDateCheck/v1/"
STEAM_UPDATE_CHECK_INTERVAL_SECONDS=1800

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

  jq -Rn --rawfile acf "${manifest}" '
    $acf
    | capture("\"buildid\"\\s+\"(?<buildid>[0-9]+)\"").buildid
  ' 2>/dev/null
}

# This flow intentionally targets the current `public` branch behavior only.
# `UpToDateCheck` has no beta/branch selector.
# `steamcmd +app_info_print` is intentionally avoided due to Valve issues:
# https://github.com/ValveSoftware/steam-for-linux/issues/9683
# https://github.com/ValveSoftware/steam-for-linux/issues/11521
# Use Valve's documented `UpToDateCheck` API instead.
function get_up_to_date_check() {
  local installed_build_id="$1"

  curl -fsS \
    --get "${STEAM_UPTODATECHECK_API}" \
    --data-urlencode "appid=${STEAMAPPID}" \
    --data-urlencode "version=${installed_build_id}" \
    --data-urlencode "format=json"
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

  cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
      kill -TERM "$server_pid" 2>/dev/null || true
    fi
    if [[ -n "$sleep_pid" ]] && kill -0 "$sleep_pid" 2>/dev/null; then
      kill -TERM "$sleep_pid" 2>/dev/null || true
    fi
  }

  trap cleanup SIGINT SIGTERM

  echo "Launching RSDragonwildsServer.sh"

  local server_cmd=(
    bash "${STEAMAPPDIR}/RSDragonwildsServer.sh"
    -Port "${RSDW_PORT}"
  )
  local additional_args=()

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

  if [[ "$AUTO_UPDATE" == "true" ]]; then
    "${server_cmd[@]}" &
    server_pid=$!

    while kill -0 "$server_pid" 2>/dev/null; do
      sleep "${STEAM_UPDATE_CHECK_INTERVAL_SECONDS}" &
      sleep_pid=$!
      wait "$sleep_pid" 2>/dev/null || true
      # Compare the locally installed public-branch build against Valve's current required version.
      local up_to_date_check_response=""
      if up_to_date_check_response="$(get_up_to_date_check "${STEAMPIPE_BUILD_ID}")"; then
        local success=""
        local up_to_date=""
        local required_version=""
        if ! success="$(jq -r '.response.success // empty' <<<"${up_to_date_check_response}")" \
          || ! up_to_date="$(jq -r '.response.up_to_date // empty' <<<"${up_to_date_check_response}")" \
          || ! required_version="$(jq -r '.response.required_version // empty' <<<"${up_to_date_check_response}")"; then
          echo "Warning: failed to parse Steam UpToDateCheck response; continuing with current server process."
        elif [[ "${success}" == "true" && "${up_to_date}" == "false" ]]; then
          # Stopping on update is opt-in; restart behavior belongs to the container runtime or orchestrator.
          if [[ "$RSDW_AUTO_STOP_ON_UPDATE" == "true" ]]; then
            echo "New Steam version is available (installed=${STEAMPIPE_BUILD_ID}, required=${required_version}), stopping server."
            kill -TERM "$server_pid"
            break
          else
            echo "New Steam version is available (installed=${STEAMPIPE_BUILD_ID}, required=${required_version}), but RSDW_AUTO_STOP_ON_UPDATE is disabled; continuing to run current server."
          fi
        fi
      else
        echo "Warning: failed to query Steam UpToDateCheck; continuing with current server process."
      fi
      sleep_pid=""
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

# Download Dedicated Server
download

# Template configuration file
envsubst < /etc/default/DedicatedServer.ini > "${STEAMAPPDIR}/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"

# Switch to server directory
cd "${STEAMAPPDIR}/RSDragonwilds/"

# Fix file permissions for Crash_handler
/bin/chmod +x "${STEAMAPPDIR}/RSDragonwilds/Plugins/Developer/Sentry/Binaries/Linux/crashpad_handler"

# Start Server
start

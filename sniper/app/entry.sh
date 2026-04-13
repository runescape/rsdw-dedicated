#!/bin/bash

# Exit script on failure
set -e

# Globals
STEAMCMD_API="https://api.steamcmd.net/v1/info"
STEAM_DEPOT_BRANCH="public"

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

    # Get current buildid
    local baseline_build_id=""
    if baseline_build_id="$(curl -s "${STEAMCMD_API}/${STEAMAPPID}" | jq -r ".data[\"${STEAMAPPID}\"]?.depots.branches.${STEAM_DEPOT_BRANCH}.buildid")"; then
        if [[ -n "$baseline_build_id" && "$baseline_build_id" != "null" ]]; then
            STEAMPIPE_BUILD_ID="${baseline_build_id}"
        else
            echo "Warning: baseline BuildID is unavailable; auto-update will be disabled for this run."
            AUTO_UPDATE="false"
        fi
    else
        echo "Warning: failed to fetch baseline BuildID; auto-update will be disabled for this run."
        AUTO_UPDATE="false"
    fi

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
      sleep 1800 &
      sleep_pid=$!
      wait "$sleep_pid" 2>/dev/null || true
      local current_build_id=""
      if current_build_id="$(curl -s "${STEAMCMD_API}/${STEAMAPPID}" | jq -r ".data[\"${STEAMAPPID}\"]?.depots.branches.${STEAM_DEPOT_BRANCH}.buildid")"; then
        if [[ -n "$current_build_id" && "$current_build_id" != "null" && "$current_build_id" != "${STEAMPIPE_BUILD_ID}" ]]; then
          echo "New BuildID is available, stopping server."
          kill -TERM "$server_pid"
          break
        fi
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

#!/bin/bash

# Exit script on failure
set -e

# Globals
STEAMCMD_API="https://api.steamcmd.net/v1/info"
STEAM_DEPOT_BRANCH="public"

# Functions

function download() {

  # Create App Dir
  mkdir -p "${STEAMAPPDIR}" || true

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
    STEAMPIPE_BUILD_ID=$(curl -s ${STEAMCMD_API}/${STEAMAPPID} | jq -r ".data[\"${STEAMAPPID}\"]?.depots.branches.${STEAM_DEPOT_BRANCH}.buildid")

    # Else, download live build from Steam
    if [[ "$STEAMAPPVALIDATE" -eq 1 ]]; then
        VALIDATE="validate"
    else
        VALIDATE=""
    fi

    ## SteamCMD can fail to download
    ## Retry logic
    MAX_ATTEMPTS=3
    attempt=0
    while [[ $steamcmd_rc != 0 ]] && [[ $attempt -lt $MAX_ATTEMPTS ]]; do
        ((attempt+=1))
        if [[ $attempt -gt 1 ]]; then
            echo "Retrying SteamCMD, attempt ${attempt}"
            # Stale appmanifest data can lead for HTTP 401 errors when requesting old
            # files from SteamPipe CDN
            echo "Removing steamapps (appmanifest data)..."
            rm -rf "${STEAMAPPDIR}/steamapps"
        fi
        eval bash "${STEAMCMDDIR}/steamcmd.sh" "${STEAMCMD_SPEW}"\
                                    +force_install_dir "${STEAMAPPDIR}" \
                                    +@bClientTryRequestManifestWithoutCode 1 \
                                    +login anonymous \
                                    +app_update "${STEAMAPPID}" "${VALIDATE}"\
                                    +quit
        steamcmd_rc=$?
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

  if [[ "$AUTO_UPDATE" == "true" ]]; then
    eval bash ${STEAMAPPDIR}/RSDragonwildsServer.sh -Port ${RSDW_PORT} ${RSDW_ADDITIONAL_ARGUMENTS} &
    server_pid=$!

    while kill -0 "$server_pid" 2>/dev/null; do
      sleep 1800 &
      sleep_pid=$!
      wait "$sleep_pid" 2>/dev/null || true
      if [[ $(curl -s ${STEAMCMD_API}/${STEAMAPPID} | jq -r ".data[\"${STEAMAPPID}\"]?.depots.branches.${STEAM_DEPOT_BRANCH}.buildid") == "${STEAMPIPE_BUILD_ID}" ]]; then
        echo "New BuildID is available, stopping server."
        kill -TERM "$server_pid"
        break
      fi
      sleep_pid=""
    done

    wait "$sever_pid" 2>/dev/null || true
    server_pid=""
  else
    eval bash ${STEAMAPPDIR}/RSDragonwildsServer.sh -Port ${RSDW_PORT} ${RSDW_ADDITIONAL_ARGUMENTS}
  fi
}

# MAIN

# Debug handling

## Steamcmd debugging
if [[ $DEBUG -eq 1 ]] || [[ $DEBUG -eq 3 ]]; then
    STEAMCMD_SPEW="+set_spew_level 4 4"
fi
## RSDW server debugging
if [[ $DEBUG -eq 2 ]] || [[ $DEBUG -eq 3 ]]; then
    RSDW_LOG="on"
fi

# FIX: steamclient.so fix
mkdir -p ~/.steam/sdk64
ln -sfT ${STEAMCMDDIR}/linux64/steamclient.so ~/.steam/sdk64/steamclient.so

# Parse Environment Variables

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
  export RSDW_PASSWORD=$(pwgen -AB 12 1)
  echo "RSDW_PASSWORD set to: ${RSDW_PASSWORD}"
fi
if [[ "$RSDW_ADMIN_PASSWORD" == "random" ]]; then
  export RSDW_ADMIN_PASSWORD=$(pwgen -AB 12 1)
  echo "RSDW_ADMIN_PASSWORD set to: ${RSDW_ADMIN_PASSWORD}"
fi

## Check that World name is set
if [[ -z $RSDW_WORLD_NAME ]]; then
  export RSDW_WORLD_NAME=$(shuf -n 1 /etc/default/DedicatedServer.names)
  echo "RSDW_WORLD_NAME set to: ${RSDW_WORLD_NAME}"
fi

# Download Dedicated Server
download

# Template configuration file
envsubst < /etc/default/DedicatedServer.ini > ${STEAMAPPDIR}/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini

# Switch to server directory
cd "${STEAMAPPDIR}/RSDragonwilds/"

# Fix file permissions for Crash_handler
/bin/chmod +x "${STEAMAPPDIR}/RSDragonwilds/Plugins/Developer/Sentry/Binaries/Linux/crashpad_handler"

# Start Server
start

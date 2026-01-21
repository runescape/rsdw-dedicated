#!/bin/bash

# Debug

## Steamcmd debugging
if [[ $DEBUG -eq 1 ]] || [[ $DEBUG -eq 3 ]]; then
    STEAMCMD_SPEW="+set_spew_level 4 4"
fi
## RSDW server debugging
if [[ $DEBUG -eq 2 ]] || [[ $DEBUG -eq 3 ]]; then
    RSDW_LOG="on"
fi

# Create App Dir
mkdir -p "${STEAMAPPDIR}" || true

# Download Updates
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

# FIX: steamclient.so fix
mkdir -p ~/.steam/sdk64
ln -sfT ${STEAMCMDDIR}/linux64/steamclient.so ~/.steam/sdk64/steamclient.so

# Switch to server directory
cd "${STEAMAPPDIR}/game/"

# Start Server

ls -l

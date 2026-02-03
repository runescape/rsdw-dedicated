# -----------------------------------------------------------------------------
# Copyright (c) 2025 JAGEX LIMITED.  
# All rights reserved.
#
# This Dockerfile and the accompanying source code are licensed under the
# terms specified in the project's LICENSE files. Unauthorized copying,
# modification, distribution, or use of this file is strictly prohibited.
#
# steamcmd is redistributed as part of this project under the terms of
# LICENSE.steamcmd
#
# Description: Container image for RuneScape Dragonwilds dedicated server
# -----------------------------------------------------------------------------

# Global ARGs

ARG PUID=1000
ARG PGID=1000
ARG USER=steam
ARG HOMEDIR="/home/steam"
ARG STEAMCMDDIR="${HOMEDIR}/steamcmd"

# SteamCMD Stage

FROM registry.gitlab.steamos.cloud/steamrt/sniper/platform as steamcmd

LABEL maintainer="Spudworks"

ARG PUID
ARG PGID
ARG USER
ARG HOMEDIR
ARG STEAMCMDDIR

RUN set -x \
        # Install SteamCMD
        && useradd -u "${PUID}" -m "${USER}" \
	&& mkdir -p "${STEAMCMDDIR}" \
	&& chown -R "${PUID}:${PGID}" "${HOMEDIR}" \
        && su "${USER}" -c \
                "curl -fsSL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' | tar xvzf - -C \"${STEAMCMDDIR}\" \
                && \"./${STEAMCMDDIR}/steamcmd.sh\" +quit "

# RSWD

FROM steamcmd AS RSDW

ARG PUID
ARG PGID
ARG USER
ARG HOMEDIR
ARG STEAMCMDDIR

ENV STEAMAPPID=4019830
ENV STEAMAPP=rsdw
ENV STEAMCMDDIR="${STEAMCMDDIR}"
ENV STEAMAPPDIR="${HOMEDIR}/${STEAMAPP}-dedicated"
ENV STEAMAPPVALIDATE=0

COPY app/entry.sh "/entry.sh"
COPY etc/DedicatedServer.ini /etc/default/DedicatedServer.ini
COPY etc/places /etc/default/DedicatedServer.names

ENV DEVBUILD_PRESIGNED_URL=""
ENV RSDW_SERVER_NAME="rsdw-container" \
    RSDW_WORLD_NAME="" \
    RSDW_PASSWORD="random" \
    RSDW_ADMINS="" \
    RSDW_ADMIN_PASSWORD="random" \
    RSDW_ADDITIONAL_ARGS=""

# Set permissions on STEAMAPPDIR
#   Permissions may need to be reset if persistent volume mounted
RUN set -x \
        && apt-get install unzip gettext-base pwgen\
	&& mkdir -p "${STEAMAPPDIR}" \
	&& chmod +x "/entry.sh" \
        && chown -R "${PUID}:${PGID}" "${STEAMAPPDIR}" \
        && chmod 0777 "${STEAMAPPDIR}"

# Switch to user
USER ${PUID}:${PGID}

# Launch entry script
WORKDIR ${HOMEDIR}
ENTRYPOINT exec /entry.sh

# Expose ports
EXPOSE 7777/udp

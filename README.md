[![CI](https://github.com/runescape/rsdw-dedicated/actions/workflows/docker-image.yml/badge.svg?branch=main)](https://github.com/runescape/rsdw-dedicated/actions/workflows/docker-image.yml) [![Build and Publish](https://github.com/runescape/rsdw-dedicated/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/runescape/rsdw-dedicated/actions/workflows/docker-publish.yml)

# RuneScape: Dragonwilds Dedicated Server

This image provides a convenient [RuneScape: Dragonwilds Server](https://store.steampowered.com/app/1374490/RuneScape_Dragonwilds/), which will automatically download the latest stable version at launch.

<img src="https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1374490/6f6bba2ddccb49f3a0abb831684ca085e453c721/header_alt_assets_3.jpg?t=1788340069" alt="logo" width="300"/></img>

# How to use this image

## Available Container Image Repositories

* GitHub: `ghcr.io/runescape/rsdw-dedicated`

## Hosting a simple game server

Running using Docker. Publish both UDP ports. The host port and the container port must be the same number:

```console
docker run -d \
  --name=rsdw-dedicated \
  -p 7777:7777/udp \
  -p 8888:8888/udp \
  --env RSDW_OWNER_ID=<userid_from_gameclient> \
  --env RSDW_WORLD_NAME=MyWorld \
  --env RSDW_PASSWORD= \
  --env RSDW_ADMIN_PASSWORD=<admin_password> \
  ghcr.io/runescape/rsdw-dedicated
```

`--env RSDW_PASSWORD=` sets an empty join password. Omitting `RSDW_PASSWORD` does not. The image default is `random`, so a new password is generated on every start. Set `RSDW_WORLD_NAME` and `RSDW_ADMIN_PASSWORD` as well, or those are regenerated too.

The same settings are in [`compose.yaml`](compose.yaml).

## System Requirements

Minimum system requirements are:

* 1 CPU cores
* 4 GiB RAM
* 20 GB of disk space

## Data Persistence

Running with data persistence using Docker:

```console
# Create a Docker Volume
docker volume create rsdw-dedicated
```

```console
# Run with volume attached
docker run -d \
  --name=rsdw-dedicated \
  -p 7777:7777/udp \
  -p 8888:8888/udp \
  -v rsdw-dedicated:/home/steam/rsdw-dedicated \
  --env RSDW_OWNER_ID=<userid_from_gameclient> \
  --env RSDW_WORLD_NAME=MyWorld \
  --env RSDW_PASSWORD= \
  --env RSDW_ADMIN_PASSWORD=<admin_password> \
  ghcr.io/runescape/rsdw-dedicated
```

# Configuration

## Environment Variables
Feel free to overwrite these environment variables, using -e (--env):

### Server Configuration

| Variable             | Type   | Default        | Description    |
| -------------------- | ------ | -------------- | -------------- |
| RSDW_OWNER_ID        | string |                | The EOS Online ID of the owner of the server (REQUIRED).|
| RSDW_PORT            | number | 7777           | UDP port for the server process to bind to. |
| RSDW_SERVER_NAME     | string | rsdw-container | Name of server | 
| RSDW_WORLD_NAME      | string | random         | Visible name of server in the Worlds browser |
| RSDW_PASSWORD        | string | random         | Server password. Explicitly set to an empty string if no password is desired. |
| RSDW_ADMINS          | string |                | Comma separated list of user ids |
| RSDW_ADMIN_PASSWORD  | string | random         | Server admin password. |
| RSDW_ADDITIONAL_ARGS | string |                | Additional CLI arguments to be passed into RSDragonwildsServer.sh |
| RSDW_AUTO_STOP_ON_UPDATE | boolean | false | Set to lowercase `true` to stop the server when a new Steam build is detected. Restart behavior depends on your container runtime or orchestrator. |

> [!NOTE]
> - `RSDW_OWNER_ID` is **required** for server visibility/functionality  
> - Environment variables with `random` default values are regenerated as random strings each time the container starts  
> - Check the container’s standard output for the generated values  
> - Explicitly setting these environment variables disables this behavior
> - Leaving `RSDW_PASSWORD` unset does not make an open world. The image sets it to `random` unless you pass an empty string

The container can detect the availability of newer builds on Steam while the server is running. By default, it only logs that an update is available; set `RSDW_AUTO_STOP_ON_UPDATE=true` to stop the server and rely on your runtime restart policy or orchestrator to restart it. SteamCMD updates the server each time the container starts.

## Ports

`RSDW_PORT` is the game port (UDP 7777 by default). The process also binds a beacon on that port plus 1111. With the default game port, the log line is:

```text
LogDomGameMode: World settings beacon listening on port 8888
```

Publish `7777/udp` and `8888/udp`. If you change `RSDW_PORT`, publish `RSDW_PORT` and `RSDW_PORT + 1111`, and keep each host port equal to the container port. A mismatched game port sends players back to the title screen.

## Joining from the same network

The Worlds list connects to the server's public address. If UDP 7777 and the beacon port are not forwarded, the world can still appear in that list and then fail with "connection lost". Players on the same LAN should Direct connect to the host's LAN address on the game port. That is the same failure as a server which is listed but not joinable because port forwarding did not work.

## Debug Logging

If you want to increase the verbosity of log output set the `DEBUG` environment variable:

```dockerfile
DEBUG=0                    (0=none, 1=steamcmd, 2=rsdw, 3=all)
```

## Validating Game Files

If you break the game through your customisations and want steamcmd to validate and redownload then set the `STEAMAPPVALIDATE` environment variable to `1`:

```dockerfile
STEAMAPPVALIDATE=0          (0=skip validation, 1=validate game files)
```

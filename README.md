[![CI](https://github.com/runescape/rsdw-dedicated/actions/workflows/docker-image.yml/badge.svg?branch=main)](https://github.com/runescape/rsdw-dedicated/actions/workflows/docker-image.yml) [![Build and Publish](https://github.com/runescape/rsdw-dedicated/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/runescape/rsdw-dedicated/actions/workflows/docker-publish.yml)

# RuneScape: Dragonwilds Dedicated Server

This image provides a convenient [RuneScape: Dragonwilds Server](https://store.steampowered.com/app/1374490/RuneScape_Dragonwilds/), which will automatically download the latest stable version at launch.

<img src="https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1374490/a3e75918e979b6c5f51264be694efb0597e99879/header.jpg?t=1765818039" alt="logo" width="300"/></img>

# How to use this image

## Available Container Image Repositories

* GitHub: `ghcr.io/runescape/rsdw-dedicated`

## Hosting a simple game server

Running using Docker:
```console
docker run -d --name=rsdw-dedicataed ghcr.io/runescape/rsdw-dedicated
```

## System Requirements

Minimum system requirements are:

* 2 CPU cores
* 2GiB RAM
* 8GiB of disk space

# Configuration

## Environment Variables
Feel free to overwrite these environment variables, using -e (--env):

### Server Configuration

| Variable             | Type   | Default        | Description    |
| -------------------- | ------ | -------------- | -------------- |
| RSDW_SERVER_NAME     | string | rsdw-container | Name of server | 
| RSDW_WORLD_NAME      | string | random         | Visible name of server in the Worlds browser |
| RSDW_PASSWORD        | string | random         | Server password. Explicitly set to an empty string if no password is desierd. |
| RSDW_ADMINS          | string |                | Comma separated list of user ids |
| RSDW_ADMIN_PASSWORD  | string | random         | Server admin password. |
| RSDW_ADDITIONAL_ARGS | string |                | Additional CLI arguments to be passed into RSDragonwildsServer.sh |

> [!NOTE]
> Environment variables with `random` default values are set to random strings each time the container starts.
> See the container's standard output for the randomly generated value.
> Explicitly setting these environment variables will disable this behaviour.

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

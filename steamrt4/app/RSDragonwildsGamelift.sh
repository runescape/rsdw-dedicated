#!/bin/bash

set -euo pipefail

usage_error() {
  echo "error: $*" >&2
  exit 2
}

# Translate the supported long options before parsing them with getopts. Keeping
# the public names explicit makes the GameLift wrapper configuration readable,
# while getopts supplies the usual short-option validation semantics here.
short_args=()
while (( $# > 0 )); do
  case "$1" in
    --rsdw-launch)
      (( $# >= 2 )) || usage_error "missing value for --rsdw-launch"
      [[ -n "$2" && "$2" != --* ]] || usage_error "missing value for --rsdw-launch"
      short_args+=(-l "$2")
      shift 2
      ;;
    --rsdw-config-file)
      (( $# >= 2 )) || usage_error "missing value for --rsdw-config-file"
      [[ -n "$2" && "$2" != --* ]] || usage_error "missing value for --rsdw-config-file"
      short_args+=(-c "$2")
      shift 2
      ;;
    --rsdw-owner-id)
      (( $# >= 2 )) || usage_error "missing value for --rsdw-owner-id"
      [[ -n "$2" && "$2" != --* ]] || usage_error "missing value for --rsdw-owner-id"
      short_args+=(-o "$2")
      shift 2
      ;;
    --rsdw-port)
      (( $# >= 2 )) || usage_error "missing value for --rsdw-port"
      [[ -n "$2" && "$2" != --* ]] || usage_error "missing value for --rsdw-port"
      short_args+=(-p "$2")
      shift 2
      ;;
    --rsdw-game-properties-json)
      (( $# >= 2 )) || usage_error "missing value for --rsdw-game-properties-json"
      [[ -n "$2" && "$2" != --* ]] || usage_error "missing value for --rsdw-game-properties-json"
      short_args+=(-g "$2")
      shift 2
      ;;
    --*)
      usage_error "unknown option: $1"
      ;;
    *)
      usage_error "unexpected positional argument: $1"
      ;;
  esac
done

set -- "${short_args[@]}"

have_launch=false
have_config_file=false
have_owner_id=false
have_port=false
have_game_properties_json=false

OPTIND=1
while getopts ":l:c:o:p:g:" option; do
  case "$option" in
    l)
      [[ "$have_launch" == false ]] || usage_error "duplicate option: --rsdw-launch"
      RSDW_LAUNCH="$OPTARG"
      have_launch=true
      ;;
    c)
      [[ "$have_config_file" == false ]] || usage_error "duplicate option: --rsdw-config-file"
      RSDW_CONFIG_FILE="$OPTARG"
      have_config_file=true
      ;;
    o)
      [[ "$have_owner_id" == false ]] || usage_error "duplicate option: --rsdw-owner-id"
      RSDW_OWNER_ID="$OPTARG"
      have_owner_id=true
      ;;
    p)
      [[ "$have_port" == false ]] || usage_error "duplicate option: --rsdw-port"
      RSDW_PORT="$OPTARG"
      have_port=true
      ;;
    g)
      [[ "$have_game_properties_json" == false ]] || usage_error "duplicate option: --rsdw-game-properties-json"
      RSDW_GAME_PROPERTIES_JSON="$OPTARG"
      have_game_properties_json=true
      ;;
    :)
      usage_error "missing value for option: -$OPTARG"
      ;;
    \?)
      usage_error "unknown option: -$OPTARG"
      ;;
  esac
done
shift $((OPTIND - 1))

(( $# == 0 )) || usage_error "unexpected positional argument: $1"
[[ "$have_launch" == true ]] || usage_error "missing required option: --rsdw-launch"
[[ "$have_config_file" == true ]] || usage_error "missing required option: --rsdw-config-file"
[[ "$have_owner_id" == true ]] || usage_error "missing required option: --rsdw-owner-id"
[[ "$have_port" == true ]] || usage_error "missing required option: --rsdw-port"
[[ "$have_game_properties_json" == true ]] || usage_error "missing required option: --rsdw-game-properties-json"

echo "RSDW Gamelift wrapper invoked with named arguments."

# Parse GameProperties JSON into variables

get_gp() {
  local key="$1"
  jq -r --arg key "$key" '
    if type == "array" then
      map(select(.Key == $key) | .Value) | .[0] // empty
    elif type == "object" then
      .[$key] // empty
    else
      empty
    end
  ' <<< "$RSDW_GAME_PROPERTIES_JSON"
}

RSDW_SERVER_NAME="$(get_gp ServerName)"
RSDW_WORLD_NAME="$(get_gp WorldName)"
RSDW_PASSWORD="$(get_gp Password)"
RSDW_ADMIN_PASSWORD="$(get_gp AdminPassword)"
RSDW_ADMINS="$(get_gp Admins)"

export RSDW_LAUNCH
export RSDW_CONFIG_FILE
export RSDW_OWNER_ID
export RSDW_PORT
export RSDW_SERVER_NAME
export RSDW_WORLD_NAME
export RSDW_PASSWORD
export RSDW_ADMIN_PASSWORD
export RSDW_ADMINS

# Fix the config substitution target if you meant RSDW_CONFIG_FILE
envsubst < /etc/default/DedicatedServer.ini > "${RSDW_CONFIG_FILE}"

exec "${RSDW_LAUNCH}" -Port "${RSDW_PORT}"

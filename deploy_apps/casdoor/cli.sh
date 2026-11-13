#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

CONF_FILE=""
NAME_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        ls) [ "$COMMAND" = network ] || { echo "[ERROR] Unknown option: $1" >&2; exit 2; }; shift ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_casdoor.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
IMAGE="casbin/casdoor:latest"
DOCKER_NETWORK=""
DB_PORT="5432"
DB_SSLMODE="disable"
APP_CONF_HASH=""
source "$SCRIPT_DIR/hooks.sh"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Casdoor] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    export IMAGE DOCKER_NETWORK DB_PORT DB_SSLMODE APP_CONF_HASH
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
}

validate_settings() {
    local key
    for key in CASDOOR_PORT DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE; do
        if [ -z "${!key:-}" ]; then
            echo "[ERROR] Fill $key in $CONF_FILE. The database and dedicated account must already exist." >&2
            return 1
        fi
        if [[ "${!key}" == *$'\n'* || "${!key}" == *$'\r'* ]]; then
            echo "[ERROR] $key must be a single-line value for Casdoor app.conf." >&2
            return 1
        fi
    done
    if [[ ! "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo "[ERROR] DB_NAME must contain letters, digits and underscores, beginning with a letter or underscore." >&2
        return 1
    fi
}

compose() {
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local container labels
    container="$(docker container ls -a --filter "name=^/$INSTANCE_NAME$" --format '{{.Names}}')"
    [ -n "$container" ] || return 0
    labels="$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$INSTANCE_NAME")"
    if [ "$labels" != "$INSTANCE_NAME/casdoor" ]; then
        echo "[ERROR] '$INSTANCE_NAME' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() (
    umask 077
    local name="$NAME_OVERRIDE" port ts
    port=$(random_port)
    if [ -z "$name" ]; then
        ts=$(date +%s)
        name="casdoor_${ts: -4}"
    fi
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] Invalid instance name: $name" >&2
        return 1
    fi
    sed -e "s/{{INSTANCE_NAME}}/$name/g" \
        -e "s/{{CASDOOR_PORT}}/$port/g" \
        "$TPL_DIR/settings_casdoor.conf.tpl" > "$CONF_FILE"
)

generate_compose() {
    cat "$TPL_DIR/compose.yaml.tpl" > "$COMPOSE_FILE"
    if [ -n "$DOCKER_NETWORK" ]; then
        cat >> "$COMPOSE_FILE" <<'YAML'
networks:
  default:
    external: true
    name: "${DOCKER_NETWORK}"
YAML
    fi
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    [ -f "$CONF_FILE" ] || generate_settings
    load_settings
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    hr
    echo "[SUCCESS] [Casdoor] Settings and Compose YAML are ready; existing settings were preserved."
    echo "Fill DB_* in $CONF_FILE, prepare the database/account and shared network, then run 'bash cli.sh start'."
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl for persistent changes)."
    hr
}

do_start() {
    load_settings
    validate_settings
    require_managed_container
    render_app_conf
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    compose up -d
    echo "[INFO] [Casdoor] Container started: http://<SERVER_IP>:$CASDOOR_PORT; inspect logs for readiness."
}

do_update() {
    load_settings
    validate_settings
    require_managed_container
    render_app_conf
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    compose pull
    compose up -d
    echo "[SUCCESS] [Casdoor] Image updated; settings, data and external dependencies were preserved."
}

do_stop() {
    load_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    compose stop
}

do_rm() {
    load_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    compose down
}

do_purge() {
    do_rm
    local data_dir="$CONF_DIR/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi
    echo "[SUCCESS] [Casdoor] Local app data purged; app.conf, settings and external database were preserved."
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE" "$CONF_DIR/data/${INSTANCE_NAME}_config/app.conf"
    echo "[SUCCESS] [Casdoor] This app's settings and generated files removed; external services were preserved."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network} [--conf PATH] [--name NAME]"
    echo "  init       : Generate missing settings, then Compose YAML; do not start containers"
    echo "  start      : Render app.conf and Compose YAML, then run compose up -d"
    echo "  up         : init + start (requires completed database configuration)"
    echo "  update     : Pull the configured app image and run compose up -d"
    echo "  stop       : Stop only Casdoor"
    echo "  rm         : Remove only this Compose project; preserve settings and bind mounts"
    echo "  purge      : DANGER - rm and delete only data/<INSTANCE_NAME>_data"
    echo "  reset      : DANGER - purge and delete this app's settings, YAML and app.conf"
    echo "  network ls : Inspect the configured network without modifying it"
    echo "  --conf PATH: Settings path; YAML and data live relative to its directory"
    echo "  --name NAME: Instance name written only when generating new settings"
}

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    init)    do_init ;;
    start)   do_start ;;
    up)      do_init; do_start ;;
    update)  do_update ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    purge)   do_purge ;;
    reset)   do_reset ;;
    network) do_network ;;
    *)       do_help ;;
esac

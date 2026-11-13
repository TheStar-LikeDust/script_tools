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
        *) echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_redis.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
IMAGE="redis:7-alpine"
DOCKER_NETWORK=""
REDIS_PUBLISH_PORT=true

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Redis] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
    # Read CRLF files without rewriting existing settings.
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    export IMAGE DOCKER_NETWORK REDIS_PUBLISH_PORT
    if [[ ! "$INSTANCE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        exit 1
    fi
}

compose() {
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local container labels
    container="$(docker container ls -a --filter "name=^/${INSTANCE_NAME}$" --format '{{.Names}}')"
    [ -n "$container" ] || return 0
    labels="$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$INSTANCE_NAME")"
    if [ "$labels" != "$INSTANCE_NAME/redis" ]; then
        echo "[ERROR] '$INSTANCE_NAME' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() (
    umask 077
    local port
    port=$(random_port)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="redis_${ts: -4}"
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{REDIS_PORT}}/${port}/g" \
        "$TPL_DIR/settings_redis.conf.tpl" > "$CONF_FILE"
)

generate_compose() {
    cat "$TPL_DIR/compose.yaml.tpl" > "$COMPOSE_FILE"
    if [ "$REDIS_PUBLISH_PORT" = true ]; then
        cat >> "$COMPOSE_FILE" <<'YAML'
    ports:
      - "${REDIS_PORT:?REDIS_PORT is required}:6379"
YAML
    fi
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
    hr
    echo "[INFO] [Redis] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    load_settings
    generate_compose

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [Redis] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review $CONF_FILE (port / instance name / network)"
    echo "  2. Run 'bash cli.sh start' to refresh YAML and start with Docker Compose"
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl instead)"
    hr
}

do_start() {
    load_settings
    require_managed_container
    generate_compose
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [Redis] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    compose up -d
    hr
    echo "[SUCCESS] [Redis] Container started; check Docker health status for readiness."
    if [ "$REDIS_PUBLISH_PORT" = true ]; then
        echo "Connection: redis://<SERVER_IP>:${REDIS_PORT}"
        echo "Local: redis-cli -p ${REDIS_PORT}"
    fi
    echo "Docker network address: ${INSTANCE_NAME}:6379 (same network only)"
    hr
}

do_update() {
    load_settings
    require_managed_container
    generate_compose
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [Redis] Pulling image and recreating the service if needed..."
    hr
    compose pull
    compose up -d
    hr
    echo "[SUCCESS] [Redis] Image update completed; settings and data were preserved."
    hr
}

do_stop() {
    load_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [Redis] Stopping service..."
    hr
    compose stop
}

do_rm() {
    load_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [Redis] Removing container..."
    hr
    compose down
}

do_purge() {
    do_rm
    hr
    echo "[WARN] WARNING: Preparing to completely destroy Redis data!"
    hr

    # Clean up local data directory but preserve configs
    local data_dir="${CONF_DIR}/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        # Data is bind-mounted and often written as root inside the container;
        # delete via a throwaway root container to avoid host permission errors.
        docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi

    hr
    echo "[SUCCESS] [Redis] Data has been purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] [Redis] Removing this instance's settings and generated YAML..."
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    hr
    echo "[SUCCESS] [Redis] Reset complete (restored to pristine source files)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset} [--conf PATH] [--name NAME]"
    echo "  init    : Generate settings if absent, then Compose YAML and data dir; do not start"
    echo "  start   : Refresh Compose YAML and run docker compose up -d"
    echo "  update  : Pull the configured image and recreate the service if needed"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings_redis.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings_redis.conf)"
    echo "  reset   : DANGER - purge AND delete only this config and its generated YAML"
    echo ""
    echo "Options:"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings_redis.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/<INSTANCE_NAME>_data."
    echo "  --name NAME : Full instance name to write at init (default: auto 'redis_<ts>')."
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
    *)       do_help ;;
esac

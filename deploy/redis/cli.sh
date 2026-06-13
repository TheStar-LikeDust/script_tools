#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

CONF_FILE=""
NAME_OVERRIDE=""
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
IMAGE="redis:7-alpine"
HOOK_RUN_ARGS=()

[ -f "$SCRIPT_DIR/hooks.sh" ] && source "$SCRIPT_DIR/hooks.sh"
hook() { if declare -F "$1" >/dev/null; then "$1"; fi; }

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Redis] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() {
    local port=$(random_port)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="redis_${ts: -4}"
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{REDIS_PORT}}/${port}/g" \
        "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [Redis] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    source "$CONF_FILE"
    hook on_init

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [Redis] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review settings.conf (port / instance name)"
    echo "  2. Run 'bash cli.sh start' to bring up the service"
    echo "Note: managed via plain 'docker run'; settings.conf is the single config source."
    hr
}

do_start() {
    require_conf
    # Export all settings so 'docker run -e VAR' passes them through cleanly
    set -a; source "$CONF_FILE"; set +a
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hook on_start

    hr
    echo "[INFO] [Redis] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            -p "${REDIS_PORT}:6379" \
            -v "${CONF_DIR}/data/${INSTANCE_NAME}_data:/data" \
            --health-cmd "redis-cli ping" \
            --health-interval 5s \
            --health-timeout 3s \
            --health-retries 5 \
            --restart unless-stopped \
            "$IMAGE" \
            redis-server --save 60 1000 --appendonly yes >/dev/null
    fi
    hr
    echo "[SUCCESS] [Redis] Service is up and running!"
    echo "Connection: redis://<SERVER_IP>:${REDIS_PORT}"
    echo "Local: redis-cli -p ${REDIS_PORT}"
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [Redis] Stopping service..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    hook on_stop
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [Redis] Removing container..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy Redis data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true

    # Clean up local data directory but preserve configs
    local data_dir="${CONF_DIR}/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        # Data is bind-mounted and often written as root inside the container;
        # delete via a throwaway root container to avoid host permission errors.
        docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi

    hook on_purge

    hr
    echo "[SUCCESS] [Redis] Data has been purged (configs preserved)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge} [--conf PATH] [--name NAME]"
    echo "  init    : Generate settings.conf and create data dir, without starting"
    echo "  start   : Start the container (run if absent, otherwise just start it)"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings.conf)"
    echo ""
    echo "Options (for embedding as a sub-service under another app):"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/<INSTANCE_NAME>_data."
    echo "  --name NAME : Full instance name to write at init (default: auto 'redis_<ts>')."
}

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    init)    do_init ;;
    start)   do_start ;;
    up)      do_init && do_start ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    purge)   do_purge ;;
    network) if declare -F on_network >/dev/null; then require_conf; source "$CONF_FILE"; on_network "${EXTRA_ARGS[@]}"; else do_help; fi ;;
    *)       do_help ;;
esac

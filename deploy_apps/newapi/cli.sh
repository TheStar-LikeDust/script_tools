#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Cascade args (--conf/--name) plus any command-specific extras
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

# Anchor paths to this script's own location (cwd-independent, move-safe)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
IMAGE="calciumion/new-api:latest"
HOOK_RUN_ARGS=()   # filled by hooks.sh on_start; injected into docker run

# Optional service-specific operations (bundled deps, networking).
# Absent for simple services; present here because new-api is composite.
[ -f "$SCRIPT_DIR/hooks.sh" ] && source "$SCRIPT_DIR/hooks.sh"
hook() { if declare -F "$1" >/dev/null; then "$1"; fi; }

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32; }

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [NewAPI] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() {
    local port=$(random_port)
    local secret=$(random_secret)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="newapi_${ts: -4}"
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{NEWAPI_PORT}}/${port}/g" \
        -e "s/{{CRYPTO_SECRET}}/${secret}/g" \
        "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [NewAPI] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    source "$CONF_FILE"

    # Bundled paradedb + redis init happens in hooks.sh (on_init)
    hook on_init

    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [NewAPI] Initialization completed!"
    hr
    echo "[INFO] Bundled paradedb config: settings_paradedb.conf (managed by deploy/paradedb)"
    echo "[INFO] Bundled redis config:    settings_redis.conf (managed by deploy/redis)"
    echo "[INFO] Run 'bash cli.sh start' to bring up DB + Redis + New API."
    hr
}

do_start() {
    require_conf
    set -a; source "$CONF_FILE"; set +a

    # Bundled deps + networking happen in hooks.sh (on_start), which also fills
    # SQL_DSN / REDIS_CONN_STRING and HOOK_RUN_ARGS (--network) for the run below
    hook on_start

    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [NewAPI] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            -p "${NEWAPI_PORT}:3000" \
            -e SQL_DSN="$SQL_DSN" \
            -e REDIS_CONN_STRING="$REDIS_CONN_STRING" \
            -e TZ="$TZ" \
            -e ERROR_LOG_ENABLED="$ERROR_LOG_ENABLED" \
            -e CRYPTO_SECRET="$CRYPTO_SECRET" \
            -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/data" \
            --health-cmd "wget -qO- http://localhost:3000/api/status >/dev/null || exit 1" \
            --health-interval 30s \
            --health-timeout 10s \
            --health-retries 3 \
            --restart unless-stopped \
            "$IMAGE" >/dev/null
    fi
    hr
    echo "[SUCCESS] [NewAPI] Service is up! Web UI: http://<SERVER_IP>:${NEWAPI_PORT}"
    echo "[INFO] First visit guides through the admin account setup."
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [NewAPI] Stopping service..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    hook on_stop
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [NewAPI] Removing containers..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy New API (and bundled deps) data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true

    local data_dir="$CONF_DIR/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        # Data is bind-mounted and often written as root inside the container;
        # delete via a throwaway root container to avoid host permission errors.
        docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi

    hook on_purge

    hr
    echo "[SUCCESS] [NewAPI] Data purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] [NewAPI] Removing all generated settings under this service..."
    rm -f "$CONF_DIR"/settings*.conf
    hr
    echo "[SUCCESS] [NewAPI] Reset complete (restored to pristine source files)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|reset} [--conf PATH] [--name NAME]"
    echo "  init        : Generate settings.conf (+ bundled paradedb/redis configs), without starting"
    echo "  start       : Start bundled DB + Redis, then the New API container"
    echo "  up          : init + start"
    echo "  stop        : Stop New API (and bundled deps)"
    echo "  rm          : Remove containers (Preserves data and configs)"
    echo "  purge       : DANGER - Remove containers AND delete data (Preserves configs)"
    echo "  reset       : DANGER - purge AND delete ALL settings (back to pristine source files)"
    echo "  network ls  : Show the app network and attached containers"
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
    reset)   do_reset ;;
    network) if declare -F on_network >/dev/null; then require_conf; source "$CONF_FILE"; on_network "${EXTRA_ARGS[@]}"; else do_help; fi ;;
    *)       do_help ;;
esac

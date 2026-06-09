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
IMAGE="rustfs/rustfs:latest"
HOOK_RUN_ARGS=()

[ -f "$SCRIPT_DIR/hooks.sh" ] && source "$SCRIPT_DIR/hooks.sh"
hook() { if declare -F "$1" >/dev/null; then "$1"; fi; }

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20; }

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [RustFS] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Special / Business Functions
# -----------------------------------------------------------------------------
generate_settings() {
    local port=$(random_port)
    local admin_port=$(random_port)
    local access_key=$(random_secret)
    local secret_key=$(random_secret)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="rustfs_${ts: -4}"
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{RUSTFS_PORT}}/${port}/g" \
        -e "s/{{RUSTFS_ADMIN_PORT}}/${admin_port}/g" \
        -e "s/{{RUSTFS_ACCESS_KEY}}/${access_key}/g" \
        -e "s/{{RUSTFS_SECRET_KEY}}/${secret_key}/g" \
        "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [RustFS] Initializing configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then
        generate_settings
    fi

    source "$CONF_FILE"
    hook on_init

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [RustFS] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review settings.conf (ports / access key / secret key)"
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
    echo "[INFO] [RustFS] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            -p "${RUSTFS_PORT}:9000" \
            -p "${RUSTFS_ADMIN_PORT}:9001" \
            -v "${CONF_DIR}/data/${INSTANCE_NAME}_data:/data" \
            -e RUSTFS_CONSOLE_ENABLE="true" \
            -e RUSTFS_ACCESS_KEY \
            -e RUSTFS_SECRET_KEY \
            --health-cmd "wget -qO- http://localhost:9000/health >/dev/null 2>&1 || exit 1" \
            --health-interval 5s \
            --health-timeout 3s \
            --health-retries 30 \
            --restart unless-stopped \
            "$IMAGE" \
            --access-key "$RUSTFS_ACCESS_KEY" --secret-key "$RUSTFS_SECRET_KEY" /data >/dev/null
    fi
    hr
    echo "[SUCCESS] [RustFS] Service is up and running!"
    echo "S3 API:  http://<SERVER_IP>:${RUSTFS_PORT}"
    echo "Console: http://<SERVER_IP>:${RUSTFS_ADMIN_PORT} (local: http://localhost:${RUSTFS_ADMIN_PORT})"
    echo "Access Key: ${RUSTFS_ACCESS_KEY}"
    echo "Secret Key: ${RUSTFS_SECRET_KEY}"
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [RustFS] Stopping service..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    hook on_stop
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [RustFS] Removing container..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy RustFS data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true

    # Clean up local data directory but preserve configs
    local data_dir="${CONF_DIR}/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        rm -rf "$data_dir" 2>/dev/null || true
    fi

    hook on_purge

    hr
    echo "[SUCCESS] [RustFS] Data has been purged (configs preserved)."
    hr
}

do_status() {
    require_conf
    source "$CONF_FILE"
    docker ps -a --filter "name=^${INSTANCE_NAME}$"
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
    echo "  --name NAME : Full instance name to write at init (default: auto 'rustfs_<ts>')."
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

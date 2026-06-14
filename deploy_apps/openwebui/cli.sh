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
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_openwebui.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
IMAGE="ghcr.io/open-webui/open-webui:main"
HOOK_RUN_ARGS=()

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
        echo "[ERROR] [Open WebUI] $CONF_FILE not found. Run 'bash cli.sh init' first."
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
        name="openwebui_${ts: -4}"
    fi

    local admin_suffix=$(openssl rand -hex 2)
    local admin_name="admin_${admin_suffix}"
    local admin_email="${admin_name}@example.com"
    local admin_pass=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{OPENWEBUI_PORT}}/${port}/g" \
        -e "s/{{WEBUI_SECRET_KEY}}/${secret}/g" \
        -e "s/{{WEBUI_ADMIN_EMAIL}}/${admin_email}/g" \
        -e "s/{{WEBUI_ADMIN_PASSWORD}}/${admin_pass}/g" \
        -e "s/{{WEBUI_ADMIN_NAME}}/${admin_name}/g" \
        "$TPL_DIR/settings_openwebui.conf.tpl" > "$CONF_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [Open WebUI] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    source "$CONF_FILE"
    hook on_init

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] Open WebUI initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review settings_openwebui.conf (set OPENAI_API_KEY / OLLAMA_BASE_URL etc. here)"
    echo "  2. Run 'bash cli.sh start' to bring up the service"
    echo "Note: managed via plain 'docker run'; settings_openwebui.conf is the single config source."
    hr
}

do_start() {
    require_conf
    # Export all settings so 'docker run -e VAR' passes them through cleanly
    # (bash strips quotes / keeps spaces correctly, e.g. USER_AGENT)
    set -a; source "$CONF_FILE"; set +a
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hook on_start

    hr
    echo "[INFO] Starting Open WebUI..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            -p "${OPENWEBUI_PORT}:8080" \
            -v "${CONF_DIR}/data/${INSTANCE_NAME}_data:/app/backend/data" \
            -e WEBUI_SECRET_KEY \
            -e OLLAMA_BASE_URL \
            -e OPENAI_API_BASE_URL \
            -e OPENAI_API_KEY \
            -e OPENAI_API_BASE_URLS \
            -e OPENAI_API_KEYS \
            -e WEBUI_ADMIN_EMAIL \
            -e WEBUI_ADMIN_PASSWORD \
            -e WEBUI_ADMIN_NAME \
            -e HF_TOKEN \
            -e CORS_ALLOW_ORIGIN \
            -e USER_AGENT \
            --add-host "host.docker.internal:host-gateway" \
            --restart always \
            "$IMAGE" >/dev/null
    fi
    hr
    echo "[SUCCESS] Open WebUI is up and running!"
    echo "Access URL: http://<SERVER_IP>:${OPENWEBUI_PORT} (local: http://localhost:${OPENWEBUI_PORT})"
    echo "Note: The first registered account will automatically get Administrator privileges."
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] Stopping Open WebUI..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    hook on_stop
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] Removing Open WebUI container..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy Open WebUI data!"
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
    echo "[SUCCESS] Open WebUI data has been purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] Removing all generated settings under this service..."
    rm -f "$CONF_DIR"/settings*.conf
    hr
    echo "[SUCCESS] Open WebUI reset complete (restored to pristine source files)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|reset} [--conf PATH] [--name NAME]"
    echo "  init    : Generate settings_openwebui.conf and create data dir, without starting"
    echo "  start   : Start the container (run if absent, otherwise just start it)"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings_openwebui.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings_openwebui.conf)"
    echo "  reset   : DANGER - purge AND delete ALL settings (back to pristine source files)"
    echo ""
    echo "Options (for embedding as a sub-service under another app):"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings_openwebui.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/<INSTANCE_NAME>_data."
    echo "  --name NAME : Full instance name to write at init (default: auto 'openwebui_<ts>')."
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

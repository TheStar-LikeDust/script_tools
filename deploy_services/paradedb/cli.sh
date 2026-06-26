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

# Anchor paths to this script's own location so it works from any cwd and survives moves
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_paradedb.conf}"
# Config + data live together; data dir is derived from the config file's directory at runtime
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
IMAGE="paradedb/paradedb:latest-pg17"
HOOK_RUN_ARGS=()   # filled by hooks.sh on_start if present; injected into docker run

# Optional service-specific operations (none for this base service: no hooks.sh)
[ -f "$SCRIPT_DIR/hooks.sh" ] && source "$SCRIPT_DIR/hooks.sh"
hook() { if declare -F "$1" >/dev/null; then "$1"; fi; }

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_password() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32; }

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [ParadeDB] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() {
    local port=$(random_port)
    local pass=$(random_password)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="paradedb_${ts: -4}"
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{DB_PORT}}/${port}/g" \
        -e "s/{{DB_PASSWORD}}/${pass}/g" \
        -e "s/{{DB_USER}}/postgres/g" \
        -e "s/{{DB_NAME}}/postgres/g" \
        "$TPL_DIR/settings_paradedb.conf.tpl" > "$CONF_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [ParadeDB] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    source "$CONF_FILE"

    hook on_init

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [ParadeDB] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review settings_paradedb.conf (port / credentials / db name)"
    echo "  2. Run 'bash cli.sh start' to bring up the database"
    echo "Note: managed via plain 'docker run'; settings_paradedb.conf is the single config source."
    hr
}

do_start() {
    require_conf
    # Source settings, then map DB_* to the container's POSTGRES_* via explicit -e values
    set -a; source "$CONF_FILE"; set +a

    hook on_start

    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [ParadeDB] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            -p "${DB_PORT}:5432" \
            -v "${CONF_DIR}/data/${INSTANCE_NAME}_data:/var/lib/postgresql/data" \
            -e POSTGRES_USER="$DB_USER" \
            -e POSTGRES_PASSWORD="$DB_PASSWORD" \
            -e POSTGRES_DB="$DB_NAME" \
            --health-cmd "pg_isready -U ${DB_USER}" \
            --health-interval 5s \
            --health-timeout 5s \
            --health-retries 5 \
            --restart unless-stopped \
            "$IMAGE" >/dev/null
    fi
    hr
    echo "[SUCCESS] [ParadeDB] Service is up and running!"
    echo "Connection: postgresql://${DB_USER}:${DB_PASSWORD}@<SERVER_IP>:${DB_PORT}/${DB_NAME}"
    echo "Local: psql -h localhost -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME}"
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [ParadeDB] Stopping service..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    hook on_stop
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [ParadeDB] Removing container..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy ParadeDB data!"
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
    echo "[SUCCESS] [ParadeDB] Data has been purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] [ParadeDB] Removing all generated settings under this service..."
    rm -f "$CONF_DIR"/settings*.conf
    hr
    echo "[SUCCESS] [ParadeDB] Reset complete (restored to pristine source files)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|reset} [--conf PATH] [--name NAME]"
    echo "  init    : Generate settings_paradedb.conf and create data dir, without starting"
    echo "  start   : Start the container (run if absent, otherwise just start it)"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings_paradedb.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings_paradedb.conf)"
    echo "  reset   : DANGER - purge AND delete ALL settings (back to pristine source files)"
    echo ""
    echo "Options (for embedding as a sub-service under another app):"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings_paradedb.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/<INSTANCE_NAME>_data."
    echo "  --name NAME : Full instance name to write at init (default: auto 'paradedb_<ts>')."
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

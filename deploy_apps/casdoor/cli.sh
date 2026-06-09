#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Cascade args (--conf/--name) plus any command-specific extras (e.g. --external)
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
IMAGE="casbin/casdoor:latest"
HOOK_RUN_ARGS=()   # filled by hooks.sh on_start; injected into docker run

# Optional service-specific operations (bundled deps, app.conf, networking).
# Absent for simple services; present here because casdoor is composite.
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
        echo "[ERROR] [Casdoor] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() {
    # --external is an init-only flag; it just records WITH_BUNDLED_DB in settings.conf
    local with_db="true"
    for a in "${EXTRA_ARGS[@]}"; do [ "$a" = "--external" ] && with_db="false"; done

    local port=$(random_port)
    local ts=$(date +%s)
    sed -e "s/{{INSTANCE_NAME}}/casdoor_${ts: -4}/g" \
        -e "s/{{CASDOOR_PORT}}/${port}/g" \
        -e "s/{{WITH_BUNDLED_DB}}/${with_db}/g" \
        "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [Casdoor] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    source "$CONF_FILE"

    # Bundled DB init + app.conf rendering happen in hooks.sh (on_init)
    hook on_init

    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [Casdoor] Initialization completed!"
    hr
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        echo "[INFO] Bundled paradedb config: settings_paradedb.conf (managed by deploy/paradedb)"
        echo "[INFO] Run 'bash cli.sh start' to bring up DB + Casdoor."
    else
        echo "[IMPORTANT] External DB mode: fill EXT_DB_* in settings.conf, then 'bash cli.sh start'."
    fi
    hr
}

do_start() {
    require_conf
    set -a; source "$CONF_FILE"; set +a

    # Bundled DB + networking + app.conf re-render happen in hooks.sh (on_start),
    # which also fills HOOK_RUN_ARGS (e.g. --network) for the docker run below
    hook on_start

    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [Casdoor] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            -p "${CASDOOR_PORT}:8000" \
            -e RUNNING_IN_DOCKER=true \
            -v "$(app_conf_path):/conf/app.conf" \
            -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/data" \
            --restart unless-stopped \
            "$IMAGE" >/dev/null
    fi
    hr
    echo "[SUCCESS] [Casdoor] Service is up! Web UI: http://<SERVER_IP>:${CASDOOR_PORT}"
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [Casdoor] Stopping service..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    hook on_stop
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [Casdoor] Removing containers..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy Casdoor (and bundled DB) data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true

    local data_dir="$CONF_DIR/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        rm -rf "$data_dir" 2>/dev/null || true
    fi

    hook on_purge

    hr
    echo "[SUCCESS] [Casdoor] Data purged (configs preserved)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge} [--external] [--conf PATH] [--name NAME]"
    echo "  init        : Generate settings.conf (+ bundled paradedb) and render app.conf, without starting"
    echo "  start       : Start bundled DB (if any) then the Casdoor container"
    echo "  up          : init + start"
    echo "  stop        : Stop Casdoor (and bundled DB)"
    echo "  rm          : Remove containers (Preserves data and configs)"
    echo "  purge       : DANGER - Remove containers AND delete data (Preserves configs)"
    echo "  network ls  : Show the app network and attached containers"
    echo ""
    echo "  --external  : (init/up only) Do NOT bundle paradedb; connect to an external DB"
    echo "                configured via EXT_DB_* in settings.conf."
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

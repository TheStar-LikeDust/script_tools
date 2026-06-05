#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
shift || true

# Optional flag (only meaningful for init/up): use an external DB instead of bundling paradedb
MODE_EXTERNAL="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --external) MODE_EXTERNAL="true"; shift ;;
        *) echo "[ERROR] [Casdoor] Unknown argument: $1"; exit 1 ;;
    esac
done

# Anchor paths to this script's own location (cwd-independent, move-safe)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="$SCRIPT_DIR/settings.conf"
APP_CONF="$SCRIPT_DIR/config/app.conf"
IMAGE="casbin/casdoor:latest"

# Bundled DB is delegated to deploy/paradedb's cli.sh like a function call;
# its config + data live under THIS directory via --conf.
PARADEDB_CLI="$SCRIPT_DIR/../../deploy/paradedb/cli.sh"
PG_CONF="$SCRIPT_DIR/casdoor_paradedb.conf"
deploy_paradedb() { local sub="$1"; shift; bash "$PARADEDB_CLI" "$sub" --conf "$PG_CONF" "$@"; }

hr() { echo "======================================================================"; }
random_port() { shuf -i 30000-40000 -n 1; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Casdoor] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

# Read one value from the bundled paradedb config without clobbering casdoor's own vars
pg_val() {
    ( . "$PG_CONF"; case "$1" in
        port)      echo "$DB_PORT" ;;
        user)      echo "$DB_USER" ;;
        pass)      echo "$DB_PASSWORD" ;;
        bootstrap) echo "$DB_NAME" ;;
        container) echo "$INSTANCE_NAME" ;;
    esac )
}

# Render config/app.conf from current settings.conf (+ bundled DB config when applicable)
render_app_conf() {
    source "$CONF_FILE"
    local db_host db_port db_user db_pass db_bootstrap
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        db_host="host.docker.internal"
        db_port="$(pg_val port)"
        db_user="$(pg_val user)"
        db_pass="$(pg_val pass)"
        db_bootstrap="$(pg_val bootstrap)"
    else
        db_host="$EXT_DB_HOST"
        db_port="$EXT_DB_PORT"
        db_user="$EXT_DB_USER"
        db_pass="$EXT_DB_PASSWORD"
        db_bootstrap="$EXT_DB_NAME"
    fi

    mkdir -p "$SCRIPT_DIR/config"
    sed -e "s#{{CASDOOR_DB_USER}}#${db_user}#g" \
        -e "s#{{CASDOOR_DB_PASSWORD}}#${db_pass}#g" \
        -e "s#{{CASDOOR_DB_HOST}}#${db_host}#g" \
        -e "s#{{CASDOOR_DB_PORT}}#${db_port}#g" \
        -e "s#{{CASDOOR_DB_BOOTSTRAP}}#${db_bootstrap}#g" \
        -e "s#{{CASDOOR_DB_NAME}}#${CASDOOR_DB_NAME}#g" \
        "$TPL_DIR/app.conf.tpl" > "$APP_CONF"
}

# Wait until the bundled DB container reports healthy (best effort)
wait_pg() {
    local name="$1"
    echo "[INFO] [Casdoor] Waiting for bundled DB ($name) to become healthy..."
    for _ in $(seq 1 30); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = "healthy" ]; then
            return 0
        fi
        sleep 2
    done
    echo "[WARN] [Casdoor] DB not healthy after ~60s; continuing anyway."
}

do_init() {
    hr
    echo "[INFO] [Casdoor] Initializing configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then
        local port=$(random_port)
        local ts=$(date +%s)
        local suffix=${ts: -4}
        local with_db="true"
        if [ "$MODE_EXTERNAL" = "true" ]; then with_db="false"; fi

        sed -e "s/{{INSTANCE_NAME}}/casdoor_${suffix}/g" \
            -e "s/{{CASDOOR_PORT}}/${port}/g" \
            -e "s/{{WITH_BUNDLED_DB}}/${with_db}/g" \
            "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"
    fi

    source "$CONF_FILE"

    # Bundled DB: delegate to deploy/paradedb (creates casdoor_paradedb.conf + data here)
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        deploy_paradedb init --name "paradedb_${INSTANCE_NAME}"
    fi

    # Render casdoor's app.conf from the resolved DB connection
    render_app_conf

    # Pre-create casdoor's own data dir
    mkdir -p "$SCRIPT_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [Casdoor] Initialization completed!"
    hr
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        echo "[INFO] Bundled paradedb config: casdoor_paradedb.conf (managed by deploy/paradedb)"
        echo "[INFO] Run 'bash cli.sh start' to bring up DB + Casdoor."
    else
        echo "[IMPORTANT] External DB mode: fill EXT_DB_* in settings.conf, then 'bash cli.sh start'."
    fi
    hr
}

do_start() {
    require_conf
    source "$CONF_FILE"

    # Always re-render app.conf so edits to settings.conf take effect on start
    render_app_conf

    # Bring up bundled DB first and wait until healthy
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        deploy_paradedb start
        wait_pg "$(pg_val container)"
    fi

    mkdir -p "$SCRIPT_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [Casdoor] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            -p "${CASDOOR_PORT}:8000" \
            --add-host host.docker.internal:host-gateway \
            -e RUNNING_IN_DOCKER=true \
            -v "$APP_CONF:/conf/app.conf" \
            -v "$SCRIPT_DIR/data/${INSTANCE_NAME}_data:/data" \
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
    [ "$WITH_BUNDLED_DB" = "true" ] && deploy_paradedb stop || true
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [Casdoor] Removing containers..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    [ "$WITH_BUNDLED_DB" = "true" ] && deploy_paradedb rm || true
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy Casdoor (and bundled DB) data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true

    local data_dir="$SCRIPT_DIR/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        rm -rf "$data_dir" 2>/dev/null || true
    fi

    [ "$WITH_BUNDLED_DB" = "true" ] && deploy_paradedb purge || true

    hr
    echo "[SUCCESS] [Casdoor] Data purged (configs preserved)."
    hr
}

do_status() {
    require_conf
    source "$CONF_FILE"
    docker ps -a --filter "name=^${INSTANCE_NAME}$"
    [ "$WITH_BUNDLED_DB" = "true" ] && deploy_paradedb status || true
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|status} [--external]"
    echo "  init        : Generate settings.conf (+ bundled paradedb) and render app.conf, without starting"
    echo "  start       : Start bundled DB (if any) then the Casdoor container"
    echo "  up          : init + start"
    echo "  stop        : Stop Casdoor (and bundled DB)"
    echo "  rm          : Remove containers (Preserves data and configs)"
    echo "  purge       : DANGER - Remove containers AND delete data (Preserves configs)"
    echo "  status      : Show container status"
    echo ""
    echo "  --external  : (init/up only) Do NOT bundle paradedb; connect to an external DB"
    echo "                configured via EXT_DB_* in settings.conf."
}

case "$COMMAND" in
    init)   do_init ;;
    start)  do_start ;;
    up)     do_init && do_start ;;
    stop)   do_stop ;;
    rm)     do_rm ;;
    purge)  do_purge ;;
    status) do_status ;;
    *)      do_help ;;
esac

#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
CONF_FILE="settings.conf"
IMAGE="paradedb/paradedb:latest-pg17"

hr() { echo "======================================================================"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_password() { openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [ParadeDB] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

do_init() {
    hr
    echo "[INFO] [ParadeDB] Initializing configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then
        local port=$(random_port)
        local pass=$(random_password)
        local ts=$(date +%s)
        local suffix=${ts: -4}
        local default_name="paradedb_${suffix}"
        [ -n "${APP_PREFIX:-}" ] && default_name="paradedb_${APP_PREFIX}_${suffix}"

        sed -e "s/{{INSTANCE_NAME}}/${default_name}/g" \
            -e "s/{{DB_PORT}}/${port}/g" \
            -e "s/{{DB_PASSWORD}}/${pass}/g" \
            -e "s/{{DB_USER}}/postgres/g" \
            -e "s/{{DB_NAME}}/postgres/g" \
            templates/settings.conf.tpl > "$CONF_FILE"
    fi

    source "$CONF_FILE"

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "./data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [ParadeDB] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review settings.conf (port / credentials / db name)"
    echo "  2. Run 'bash cli.sh start' to bring up the database"
    echo "Note: managed via plain 'docker run'; settings.conf is the single config source."
    hr
}

do_start() {
    require_conf
    # Source settings, then map DB_* to the container's POSTGRES_* via explicit -e values
    set -a; source "$CONF_FILE"; set +a
    mkdir -p "./data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [ParadeDB] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            -p "${DB_PORT}:5432" \
            -v "$(pwd)/data/${INSTANCE_NAME}_data:/var/lib/postgresql/data" \
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
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [ParadeDB] Removing container..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
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
    local data_dir="./data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        rm -rf "$data_dir" 2>/dev/null || true
    fi

    hr
    echo "[SUCCESS] [ParadeDB] Data has been purged (configs preserved)."
    hr
}

do_status() {
    require_conf
    source "$CONF_FILE"
    docker ps -a --filter "name=^${INSTANCE_NAME}$"
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|status}"
    echo "  init    : Generate settings.conf and create data dir, without starting"
    echo "  start   : Start the container (run if absent, otherwise just start it)"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings.conf)"
    echo "  status  : Show container running status"
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

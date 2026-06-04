#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
CONF_FILE="settings.conf"
IMAGE="rustfs/rustfs:latest"

hr() { echo "======================================================================"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [RustFS] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

do_init() {
    hr
    echo "[INFO] [RustFS] Initializing configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then
        local port=$(random_port)
        local admin_port=$(random_port)
        local access_key=$(random_secret)
        local secret_key=$(random_secret)
        local ts=$(date +%s)
        local suffix=${ts: -4}
        local default_name="rustfs_${suffix}"
        [ -n "${APP_PREFIX:-}" ] && default_name="rustfs_${APP_PREFIX}_${suffix}"

        sed -e "s/{{INSTANCE_NAME}}/${default_name}/g" \
            -e "s/{{RUSTFS_PORT}}/${port}/g" \
            -e "s/{{RUSTFS_ADMIN_PORT}}/${admin_port}/g" \
            -e "s/{{RUSTFS_ACCESS_KEY}}/${access_key}/g" \
            -e "s/{{RUSTFS_SECRET_KEY}}/${secret_key}/g" \
            templates/settings.conf.tpl > "$CONF_FILE"
    fi

    source "$CONF_FILE"

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "./data/${INSTANCE_NAME}_data"

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
    mkdir -p "./data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [RustFS] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            -p "${RUSTFS_PORT}:9000" \
            -p "${RUSTFS_ADMIN_PORT}:9001" \
            -v "$(pwd)/data/${INSTANCE_NAME}_data:/data" \
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
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [RustFS] Removing container..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
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
    local data_dir="./data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        rm -rf "$data_dir" 2>/dev/null || true
    fi

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

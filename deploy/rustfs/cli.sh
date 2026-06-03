#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
CONF_FILE="settings.conf"
COMPOSE_FILE="compose.yml"

random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20; }

init_config() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "======================================================================"
        echo "[INFO] [RustFS] First run detected, generating default configuration: $CONF_FILE"
        echo "======================================================================"
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
    export NETWORK_NAME=${NETWORK_NAME:-${INSTANCE_NAME}_network}
    
    sed -e "s/{{INSTANCE_NAME}}/${INSTANCE_NAME}/g" \
        -e "s/{{RUSTFS_PORT}}/${RUSTFS_PORT}/g" \
        -e "s/{{RUSTFS_ADMIN_PORT}}/${RUSTFS_ADMIN_PORT}/g" \
        -e "s/{{RUSTFS_ACCESS_KEY}}/${RUSTFS_ACCESS_KEY}/g" \
        -e "s/{{RUSTFS_SECRET_KEY}}/${RUSTFS_SECRET_KEY}/g" \
        -e "s/{{RUSTFS_INIT_BUCKET}}/${RUSTFS_INIT_BUCKET}/g" \
        -e "s/{{NETWORK_NAME}}/${NETWORK_NAME}/g" \
        templates/compose.yml.tpl > "$COMPOSE_FILE"
    
    echo "======================================================================"
    echo "[INFO] [RustFS] Configuration initialized and template rendered successfully!"
    echo "======================================================================"
}

start_service() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo "[ERROR] [RustFS] $COMPOSE_FILE not found. Please run '$0 init' first!"
        exit 1
    fi
    
    source "$CONF_FILE"
    local proj_name="${INSTANCE_NAME}_proj"
    
    # Fix directory permissions to prevent rustfs startup errors
    mkdir -p "./data/${INSTANCE_NAME}_data"
    
    echo "======================================================================"
    echo "[INFO] [RustFS] Starting service (Container: ${INSTANCE_NAME})..."
    echo "======================================================================"
    docker compose -p "$proj_name" -f "$COMPOSE_FILE" up -d
    echo "======================================================================"
    echo "[SUCCESS] [RustFS] Service started successfully!"
    echo "          API Port: ${RUSTFS_PORT}"
    echo "          Admin Port: ${RUSTFS_ADMIN_PORT}"
    echo "======================================================================"
}

stop_service() { [ -f "$COMPOSE_FILE" ] && source "$CONF_FILE" && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" stop; }
remove_service() { [ -f "$COMPOSE_FILE" ] && source "$CONF_FILE" && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" down; }

purge_data() {
    echo "======================================================================"
    echo "[WARN] [RustFS] Preparing to completely destroy the container and persistent data!"
    echo "======================================================================"
    [ -f "$COMPOSE_FILE" ] && source "$CONF_FILE" && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" down -v
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
        local data_dir="./data/${INSTANCE_NAME}_data"
        if [ -d "$data_dir" ] || [ -d "./data" ]; then
            echo "Removing local data directory..."
            rm -rf "$data_dir" 2>/dev/null || true
            rm -rf "./data" 2>/dev/null || true
            echo "======================================================================"
            echo "[SUCCESS] [RustFS] Cleared data volumes"
            echo "======================================================================"
        fi
        echo "[INFO] Configuration file $CONF_FILE has been preserved."
    fi
}

print_usage() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|status}"
    echo "  init    : Generate configurations (settings.conf & compose.yml) without starting"
    echo "  start   : Start the service containers"
    echo "  up      : Initialize configs and start containers instantly"
    echo "  stop    : Stop running containers"
    echo "  rm      : Remove containers (Preserves ./data and configs)"
    echo "  purge   : DANGER - Remove containers AND permanently delete ./data (Preserves configs)"
    echo "  status  : Show container running status"
}

case "$COMMAND" in
    init)   init_config ;;
    start)  start_service ;;
    up)     init_config && start_service ;;
    stop)   stop_service ;;
    rm)     remove_service ;;
    purge)  purge_data ;;
    status) [ -f "$CONF_FILE" ] && source "$CONF_FILE" && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" ps ;;
    *) print_usage ;;
esac

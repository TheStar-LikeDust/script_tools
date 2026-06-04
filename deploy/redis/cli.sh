#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
CONF_FILE="settings.conf"
COMPOSE_FILE="compose.yml"

random_port() { shuf -i 30000-40000 -n 1; }

init_config() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "======================================================================"
        echo "[INFO] [Redis] First run detected, generating default configuration: $CONF_FILE"
        echo "======================================================================"
        local port=$(random_port)
        local ts=$(date +%s)
        local suffix=${ts: -4}
        local default_name="redis_${suffix}"
        [ -n "${APP_PREFIX:-}" ] && default_name="redis_${APP_PREFIX}_${suffix}"
        
        sed -e "s/{{INSTANCE_NAME}}/${default_name}/g" \
            -e "s/{{REDIS_PORT}}/${port}/g" \
            templates/settings.conf.tpl > "$CONF_FILE"
    fi

    source "$CONF_FILE"
    export NETWORK_NAME=${NETWORK_NAME:-${INSTANCE_NAME}_network}
    
    sed -e "s/{{INSTANCE_NAME}}/${INSTANCE_NAME}/g" \
        -e "s/{{REDIS_PORT}}/${REDIS_PORT}/g" \
        -e "s/{{NETWORK_NAME}}/${NETWORK_NAME}/g" \
        templates/compose.yml.tpl > "$COMPOSE_FILE"
    
    echo "======================================================================"
    echo "[INFO] [Redis] Configuration initialized and template rendered successfully!"
    echo "======================================================================"
}

start_service() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo "[ERROR] [Redis] $COMPOSE_FILE not found. Please run '$0 init' first!"
        exit 1
    fi
    
    source "$CONF_FILE"
    local proj_name="${INSTANCE_NAME}_proj"
    
    echo "======================================================================"
    echo "[INFO] [Redis] Starting service (Container: ${INSTANCE_NAME})..."
    echo "======================================================================"
    docker compose -p "$proj_name" -f "$COMPOSE_FILE" up -d
    echo "======================================================================"
    echo "[SUCCESS] [Redis] Service started successfully! Port: ${REDIS_PORT}"
    echo "======================================================================"
}

stop_service() { [ -f "$COMPOSE_FILE" ] && source "$CONF_FILE" && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" stop; }
remove_service() { [ -f "$COMPOSE_FILE" ] && source "$CONF_FILE" && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" down; }

purge_data() {
    echo "======================================================================"
    echo "[WARN] [Redis] Preparing to completely destroy the container and persistent data!"
    echo "======================================================================"
    [ -f "$COMPOSE_FILE" ] && source "$CONF_FILE" && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" down -v
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
        local data_dir="./data/${INSTANCE_NAME}_data"
        if [ -d "$data_dir" ]; then
            echo "Removing local data directory..."
            rm -rf "$data_dir" 2>/dev/null || true
            echo "======================================================================"
            echo "[SUCCESS] [Redis] Cleared data volumes"
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

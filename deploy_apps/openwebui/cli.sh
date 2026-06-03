#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
CONF_FILE="settings.conf"
COMPOSE_FILE="compose.yml"

random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 40; }

init_config() {
    echo "======================================================================"
    echo "[INFO] [Open WebUI] Initializing configuration..."
    echo "======================================================================"
    
    if [ ! -f "$CONF_FILE" ]; then
        local port=$(random_port)
        local secret=$(random_secret)
        local ts=$(date +%s)
        local suffix=${ts: -4}
        local default_name="openwebui_${suffix}"
        [ -n "${APP_PREFIX:-}" ] && default_name="openwebui_${APP_PREFIX}_${suffix}"
        
        sed -e "s/{{INSTANCE_NAME}}/${default_name}/g" \
            -e "s/{{OPENWEBUI_PORT}}/${port}/g" \
            -e "s/{{WEBUI_SECRET_KEY}}/${secret}/g" \
            templates/settings.conf.tpl > "$CONF_FILE"
    fi
    
    source "$CONF_FILE"
    
    sed -e "s/{{INSTANCE_NAME}}/${INSTANCE_NAME}/g" \
        -e "s/{{OPENWEBUI_PORT}}/${OPENWEBUI_PORT}/g" \
        -e "s/{{WEBUI_SECRET_KEY}}/${WEBUI_SECRET_KEY}/g" \
        -e "s|{{OLLAMA_BASE_URL}}|${OLLAMA_BASE_URL:-}|g" \
        -e "s|{{OPENAI_API_BASE_URL}}|${OPENAI_API_BASE_URL:-}|g" \
        -e "s/{{OPENAI_API_KEY}}/${OPENAI_API_KEY:-}/g" \
        -e "s/{{HF_TOKEN}}/${HF_TOKEN:-}/g" \
        -e "s/{{CORS_ALLOW_ORIGIN}}/${CORS_ALLOW_ORIGIN:-*}/g" \
        templates/compose.yml.tpl > "$COMPOSE_FILE"
        
    echo "======================================================================"
    echo "[SUCCESS] Open WebUI initialization completed!"
    echo "======================================================================"
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review settings.conf (you can set OPENAI_API_KEY and other env vars here)"
    echo "  2. Run 'bash cli.sh start' to bring up the service"
    echo "======================================================================"
}

start_stack() {
    source "$CONF_FILE"
    export USER_AGENT="${USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36}"
    
    echo "======================================================================"
    echo "[INFO] Starting Open WebUI..."
    echo "======================================================================"
    # USER_AGENT is evaluated at runtime during compose up if it contains spaces
    USER_AGENT="${USER_AGENT}" docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" up -d
    echo "======================================================================"
    echo "[SUCCESS] Open WebUI is up and running!"
    echo "Access URL: http://<SERVER_IP>:$OPENWEBUI_PORT"
    echo "Note: The first registered account will automatically get Administrator privileges."
    echo "======================================================================"
}

stop_stack() {
    source "$CONF_FILE"
    echo "======================================================================"
    echo "[INFO] Stopping Open WebUI..."
    echo "======================================================================"
    [ -f "$COMPOSE_FILE" ] && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" stop
}

rm_stack() {
    source "$CONF_FILE"
    echo "======================================================================"
    echo "[INFO] Removing Open WebUI containers..."
    echo "======================================================================"
    [ -f "$COMPOSE_FILE" ] && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" down
}

purge_stack() {
    source "$CONF_FILE"
    echo "======================================================================"
    echo "[WARN] WARNING: Preparing to completely destroy Open WebUI data!"
    echo "======================================================================"
    [ -f "$COMPOSE_FILE" ] && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" down -v
    
    # Clean up local data directory but preserve configs
    local data_dir="./data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ] || [ -d "./data" ]; then
        echo "Removing local data directory..."
        rm -rf "$data_dir" 2>/dev/null || true
        rm -rf "./data" 2>/dev/null || true
    fi
    
    echo "======================================================================"
    echo "[SUCCESS] Open WebUI data has been purged (configs preserved)."
    echo "======================================================================"
}

status_stack() {
    source "$CONF_FILE"
    [ -f "$COMPOSE_FILE" ] && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" ps
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
    init)  init_config ;;
    start) start_stack ;;
    up)    init_config && start_stack ;;
    stop)  stop_stack ;;
    rm)    rm_stack ;;
    purge) purge_stack ;;
    status) status_stack ;;
    *) print_usage ;;
esac

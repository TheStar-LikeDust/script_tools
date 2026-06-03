#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
SERVICES_DIR="../../deploy"
CONF_FILE="settings.conf"
COMPOSE_FILE="compose.yml"

random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20; }

init_config() {
    echo "======================================================================"
    echo "[INFO] [LobeChat Stack] Initializing full-stack configuration..."
    echo "======================================================================"
    
    if [ ! -f "$CONF_FILE" ]; then
        local port=$(random_port)
        local vault_sec=$(random_secret)
        local auth_sec=$(random_secret)
        local ts=$(date +%s)
        local suffix=${ts: -4}
        local default_name="lobechat_${suffix}"
        
        sed -e "s/{{INSTANCE_NAME}}/${default_name}/g" \
            -e "s/{{NETWORK_NAME}}/${NETWORK_NAME:-lobechat_network}/g" \
            -e "s/{{LOBECHAT_PORT}}/${port}/g" \
            -e "s/{{KEY_VAULTS_SECRET}}/${vault_sec}/g" \
            -e "s/{{AUTH_SECRET}}/${auth_sec}/g" \
            templates/settings.conf.tpl > "$CONF_FILE"
    fi
    source "$CONF_FILE"
    export NETWORK_NAME
    
    local db_host db_port db_user db_pass db_name
    local redis_url
    local s3_endpoint s3_bucket s3_ak s3_sk
    local casdoor_issuer casdoor_id casdoor_secret
    
    # --- 1. Database (ParadeDB) ---
    if [ "$USE_INTERNAL_DB" = "true" ]; then
        export APP_PREFIX="${INSTANCE_NAME}"
        (cd "${SERVICES_DIR}/paradedb" && ./cli.sh init >/dev/null)
        source "${SERVICES_DIR}/paradedb/settings.conf"
        
        db_host="${INSTANCE_NAME}"
        db_port="5432"
        db_user=$DB_USER
        db_pass=$DB_PASSWORD
        db_name=$DB_NAME
        source "$CONF_FILE"
    else
        db_host=$EXTERNAL_DB_HOST
        db_port=$EXTERNAL_DB_PORT
        db_user=$EXTERNAL_DB_USER
        db_pass=$EXTERNAL_DB_PASSWORD
        db_name=$EXTERNAL_DB_NAME
    fi
    
    # --- 2. Redis ---
    if [ "$USE_INTERNAL_REDIS" = "true" ]; then
        export APP_PREFIX="${INSTANCE_NAME}"
        (cd "${SERVICES_DIR}/redis" && ./cli.sh init >/dev/null)
        source "${SERVICES_DIR}/redis/settings.conf"
        
        redis_url="redis://${INSTANCE_NAME}:6379"
        source "$CONF_FILE"
    else
        redis_url=$EXTERNAL_REDIS_URL
    fi
    
    # --- 3. RustFS (S3) ---
    if [ "$USE_INTERNAL_S3" = "true" ]; then
        export APP_PREFIX="${INSTANCE_NAME}"
        (cd "${SERVICES_DIR}/rustfs" && ./cli.sh init >/dev/null)
        source "${SERVICES_DIR}/rustfs/settings.conf"
        
        s3_endpoint="http://${INSTANCE_NAME}:9000"
        s3_bucket=$RUSTFS_INIT_BUCKET
        s3_ak=$RUSTFS_ACCESS_KEY
        s3_sk=$RUSTFS_SECRET_KEY
        source "$CONF_FILE"
    else
        s3_endpoint=$EXTERNAL_S3_ENDPOINT
        s3_bucket=$EXTERNAL_S3_BUCKET
        s3_ak=$EXTERNAL_S3_ACCESS_KEY
        s3_sk=$EXTERNAL_S3_SECRET_KEY
    fi
    
    # --- 4. Casdoor ---
    if [ "$USE_INTERNAL_CASDOOR" = "true" ]; then
        export APP_PREFIX="${INSTANCE_NAME}"
        export CASDOOR_DB_HOST="${db_host}"
        export CASDOOR_DB_USER="${db_user}"
        export CASDOOR_DB_PASSWORD="${db_pass}"
        export CASDOOR_DB_NAME="casdoor"
        (cd "${SERVICES_DIR}/casdoor" && ./cli.sh init >/dev/null)
        source "${SERVICES_DIR}/casdoor/settings.conf"
        
        casdoor_issuer="http://<SERVER_IP>:${CASDOOR_PORT}"
        casdoor_id="<UPDATE_ME_AFTER_CASDOOR_START>"
        casdoor_secret="<UPDATE_ME_AFTER_CASDOOR_START>"
        source "$CONF_FILE"
    else
        casdoor_issuer=$EXTERNAL_CASDOOR_ISSUER
        casdoor_id=$EXTERNAL_CASDOOR_ID
        casdoor_secret=$EXTERNAL_CASDOOR_SECRET
    fi
    
    sed -e "s/{{INSTANCE_NAME}}/${INSTANCE_NAME}/g" \
        -e "s/{{NETWORK_NAME}}/${NETWORK_NAME}/g" \
        -e "s/{{LOBECHAT_PORT}}/${LOBECHAT_PORT}/g" \
        -e "s/{{KEY_VAULTS_SECRET}}/${KEY_VAULTS_SECRET}/g" \
        -e "s/{{AUTH_SECRET}}/${AUTH_SECRET}/g" \
        -e "s|{{DB_HOST}}|${db_host}|g" \
        -e "s/{{DB_PORT}}/${db_port}/g" \
        -e "s/{{DB_USER}}/${db_user}/g" \
        -e "s/{{DB_PASSWORD}}/${db_pass}/g" \
        -e "s/{{DB_NAME}}/${db_name}/g" \
        -e "s|{{REDIS_URL}}|${redis_url}|g" \
        -e "s|{{S3_ENDPOINT}}|${s3_endpoint}|g" \
        -e "s/{{S3_BUCKET}}/${s3_bucket}/g" \
        -e "s/{{S3_ACCESS_KEY}}/${s3_ak}/g" \
        -e "s/{{S3_SECRET_KEY}}/${s3_sk}/g" \
        -e "s|{{CASDOOR_ISSUER}}|${casdoor_issuer}|g" \
        -e "s/{{CASDOOR_ID}}/${casdoor_id}/g" \
        -e "s/{{CASDOOR_SECRET}}/${casdoor_secret}/g" \
        templates/compose.yml.tpl > "$COMPOSE_FILE"
        
    echo "======================================================================"
    echo "[SUCCESS] LobeChat Stack initialization completed!"
    echo "======================================================================"
    echo "[IMPORTANT] Since SSO is enabled, LobeChat needs Casdoor Client ID."
    echo "Recommended next steps:"
    echo "  1. Review settings.conf"
    echo "  2. Run './cli.sh start' to bring up all services"
    echo "  3. LobeChat might report an auth error initially - this is normal"
    echo "  4. Login to Casdoor Admin UI, create an application for LobeChat"
    echo "  5. Replace <UPDATE_ME...> in $COMPOSE_FILE with your new Client ID & Secret"
    echo "  6. Run 'docker compose restart lobechat' to apply auth changes"
    echo "======================================================================"
}

start_stack() {
    source "$CONF_FILE"
    echo "======================================================================"
    echo "[INFO] Starting all base services sequentially..."
    echo "======================================================================"
    [ "$USE_INTERNAL_DB" = "true" ] && (cd "${SERVICES_DIR}/paradedb" && ./cli.sh start)
    [ "$USE_INTERNAL_REDIS" = "true" ] && (cd "${SERVICES_DIR}/redis" && ./cli.sh start)
    [ "$USE_INTERNAL_S3" = "true" ] && (cd "${SERVICES_DIR}/rustfs" && ./cli.sh start)
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && (cd "${SERVICES_DIR}/casdoor" && ./cli.sh start)
    
    echo "======================================================================"
    echo "[INFO] Starting LobeChat core application..."
    echo "======================================================================"
    docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" up -d
    echo "======================================================================"
    echo "[SUCCESS] LobeChat Stack is up and running! Port: $LOBECHAT_PORT"
    echo "======================================================================"
}

purge_stack() {
    source "$CONF_FILE"
    echo "======================================================================"
    echo "[WARN] WARNING: Preparing to completely destroy LobeChat Stack data!"
    echo "======================================================================"
    [ -f "$COMPOSE_FILE" ] && docker compose -p "${INSTANCE_NAME}_proj" -f "$COMPOSE_FILE" down -v
    
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && (cd "${SERVICES_DIR}/casdoor" && ./cli.sh purge)
    [ "$USE_INTERNAL_S3" = "true" ] && (cd "${SERVICES_DIR}/rustfs" && ./cli.sh purge)
    [ "$USE_INTERNAL_REDIS" = "true" ] && (cd "${SERVICES_DIR}/redis" && ./cli.sh purge)
    [ "$USE_INTERNAL_DB" = "true" ] && (cd "${SERVICES_DIR}/paradedb" && ./cli.sh purge)
    
    echo "======================================================================"
    echo "[SUCCESS] LobeChat Stack data has been purged (configs preserved)."
    echo "======================================================================"
}

case "$COMMAND" in
    init)  init_config ;;
    start) start_stack ;;
    up)    init_config && start_stack ;;
    purge) purge_stack ;;
    *) echo "Usage: $0 [init|start|up|purge]" ;;
esac

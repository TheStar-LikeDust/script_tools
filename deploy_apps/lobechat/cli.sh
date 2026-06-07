#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Anchor paths to this script's own location (cwd-independent, move-safe)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="$SCRIPT_DIR/settings.conf"
IMAGE="lobehub/lobehub:latest"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20; }

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [LobeChat] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# Same user-defined network so the lobechat container and all bundled base services
# talk by container name (avoids host-gateway / host firewall issues).
ensure_network() { docker network inspect "$1" >/dev/null 2>&1 || docker network create "$1" >/dev/null; }

# Read one value from a delegated service's config without clobbering our own vars
conf_val() { ( . "$1" >/dev/null 2>&1; printf '%s' "${!2:-}" ); }

# -----------------------------------------------------------------------------
# 3. Special / Business Functions
# -----------------------------------------------------------------------------
# Bundled base services are delegated to their own cli.sh; their config + data
# live under THIS app's directory via --conf. Casdoor is a sibling app that
# self-bundles its own DB and keeps config in its own directory.
PARADEDB_CLI="$SCRIPT_DIR/../../deploy/paradedb/cli.sh"
REDIS_CLI="$SCRIPT_DIR/../../deploy/redis/cli.sh"
RUSTFS_CLI="$SCRIPT_DIR/../../deploy/rustfs/cli.sh"
CASDOOR_CLI="$SCRIPT_DIR/../casdoor/cli.sh"

PG_CONF="$SCRIPT_DIR/settings_paradedb.conf"
REDIS_CONF="$SCRIPT_DIR/settings_redis.conf"
RUSTFS_CONF="$SCRIPT_DIR/settings_rustfs.conf"
CASDOOR_CONF="$SCRIPT_DIR/../casdoor/settings.conf"

deploy_paradedb() { local sub="$1"; shift; bash "$PARADEDB_CLI" "$sub" --conf "$PG_CONF" "$@"; }
deploy_redis()    { local sub="$1"; shift; bash "$REDIS_CLI" "$sub" --conf "$REDIS_CONF" "$@"; }
deploy_rustfs()   { local sub="$1"; shift; bash "$RUSTFS_CLI" "$sub" --conf "$RUSTFS_CONF" "$@"; }
deploy_casdoor()  { local sub="$1"; shift; bash "$CASDOOR_CLI" "$sub" "$@"; }

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [LobeChat Stack] Initializing full-stack configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then
        local port=$(random_port)
        local vault_sec=$(random_secret)
        local auth_sec=$(random_secret)
        local ts=$(date +%s)
        local default_name="lobechat_${ts: -4}"

        sed -e "s/{{INSTANCE_NAME}}/${default_name}/g" \
            -e "s/{{LOBECHAT_PORT}}/${port}/g" \
            -e "s/{{KEY_VAULTS_SECRET}}/${vault_sec}/g" \
            -e "s/{{AUTH_SECRET}}/${auth_sec}/g" \
            "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"
    fi
    source "$CONF_FILE"

    # Initialize bundled base services so their configs (settings_*.conf) exist here.
    # Connection values are resolved at start time from these configs (no compose, pure docker).
    if [ "$USE_INTERNAL_DB" = "true" ]; then deploy_paradedb init --name "paradedb_${INSTANCE_NAME}" >/dev/null; fi
    if [ "$USE_INTERNAL_REDIS" = "true" ]; then deploy_redis init --name "redis_${INSTANCE_NAME}" >/dev/null; fi
    if [ "$USE_INTERNAL_S3" = "true" ]; then deploy_rustfs init --name "rustfs_${INSTANCE_NAME}" >/dev/null; fi
    if [ "$USE_INTERNAL_CASDOOR" = "true" ]; then deploy_casdoor init >/dev/null; fi

    hr
    echo "[SUCCESS] LobeChat Stack initialization completed!"
    hr
    echo "[IMPORTANT] Since SSO is enabled, LobeChat needs Casdoor Client ID."
    echo "Recommended next steps:"
    echo "  1. Review settings.conf"
    echo "  2. Run 'bash cli.sh start' to bring up all services"
    echo "  3. LobeChat might report an auth error initially - this is normal"
    echo "  4. Login to Casdoor Admin UI, create an application for LobeChat"
    echo "  5. Set CASDOOR_CLIENT_ID / CASDOOR_CLIENT_SECRET in settings.conf"
    echo "  6. Recreate the app to apply auth: 'bash cli.sh rm && bash cli.sh start'"
    hr
}

do_start() {
    require_conf
    source "$CONF_FILE"

    local net="${INSTANCE_NAME}_net"
    ensure_network "$net"

    hr
    echo "[INFO] Starting bundled base services and attaching to ${net}..."
    hr
    if [ "$USE_INTERNAL_DB" = "true" ]; then
        deploy_paradedb start
        docker network connect "$net" "paradedb_${INSTANCE_NAME}" 2>/dev/null || true
    fi
    if [ "$USE_INTERNAL_REDIS" = "true" ]; then
        deploy_redis start
        docker network connect "$net" "redis_${INSTANCE_NAME}" 2>/dev/null || true
    fi
    if [ "$USE_INTERNAL_S3" = "true" ]; then
        deploy_rustfs start
        docker network connect "$net" "rustfs_${INSTANCE_NAME}" 2>/dev/null || true
    fi
    if [ "$USE_INTERNAL_CASDOOR" = "true" ]; then
        deploy_casdoor start
        docker network connect "$net" "$(conf_val "$CASDOOR_CONF" INSTANCE_NAME)" 2>/dev/null || true
    fi

    # Resolve connection settings: internal => reach bundled containers by name on $net
    local db_url redis_url s3_endpoint s3_bucket s3_ak s3_sk casdoor_issuer casdoor_id casdoor_secret
    if [ "$USE_INTERNAL_DB" = "true" ]; then
        db_url="postgresql://$(conf_val "$PG_CONF" DB_USER):$(conf_val "$PG_CONF" DB_PASSWORD)@paradedb_${INSTANCE_NAME}:5432/$(conf_val "$PG_CONF" DB_NAME)"
    else
        db_url="postgresql://${EXTERNAL_DB_USER}:${EXTERNAL_DB_PASSWORD}@${EXTERNAL_DB_HOST}:${EXTERNAL_DB_PORT}/${EXTERNAL_DB_NAME}"
    fi
    if [ "$USE_INTERNAL_REDIS" = "true" ]; then
        redis_url="redis://redis_${INSTANCE_NAME}:6379"
    else
        redis_url="$EXTERNAL_REDIS_URL"
    fi
    if [ "$USE_INTERNAL_S3" = "true" ]; then
        s3_endpoint="http://rustfs_${INSTANCE_NAME}:9000"
        s3_bucket="$S3_BUCKET"
        s3_ak="$(conf_val "$RUSTFS_CONF" RUSTFS_ACCESS_KEY)"
        s3_sk="$(conf_val "$RUSTFS_CONF" RUSTFS_SECRET_KEY)"
    else
        s3_endpoint="$EXTERNAL_S3_ENDPOINT"; s3_bucket="$EXTERNAL_S3_BUCKET"
        s3_ak="$EXTERNAL_S3_ACCESS_KEY"; s3_sk="$EXTERNAL_S3_SECRET_KEY"
    fi
    if [ "$USE_INTERNAL_CASDOOR" = "true" ]; then
        casdoor_issuer="http://${CASDOOR_PUBLIC_HOST}:$(conf_val "$CASDOOR_CONF" CASDOOR_PORT)"
        casdoor_id="$CASDOOR_CLIENT_ID"
        casdoor_secret="$CASDOOR_CLIENT_SECRET"
    else
        casdoor_issuer="$EXTERNAL_CASDOOR_ISSUER"
        casdoor_id="$EXTERNAL_CASDOOR_ID"
        casdoor_secret="$EXTERNAL_CASDOOR_SECRET"
    fi

    mkdir -p "$SCRIPT_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] Starting LobeChat core application (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            --network "$net" \
            -p "${LOBECHAT_PORT}:3210" \
            -v "$SCRIPT_DIR/data/${INSTANCE_NAME}_data:/app/data" \
            -e "DATABASE_URL=${db_url}" \
            -e "INTERNAL_APP_URL=http://localhost:3210" \
            -e "KEY_VAULTS_SECRET=${KEY_VAULTS_SECRET}" \
            -e "AUTH_SECRET=${AUTH_SECRET}" \
            -e "S3_ENDPOINT=${s3_endpoint}" \
            -e "S3_BUCKET=${s3_bucket}" \
            -e "S3_ACCESS_KEY_ID=${s3_ak}" \
            -e "S3_SECRET_ACCESS_KEY=${s3_sk}" \
            -e "S3_ENABLE_PATH_STYLE=1" \
            -e "LLM_VISION_IMAGE_USE_BASE64=1" \
            -e "REDIS_URL=${redis_url}" \
            -e "REDIS_PREFIX=${INSTANCE_NAME}" \
            -e "NEXT_AUTH_SSO_PROVIDERS=casdoor" \
            -e "AUTH_CASDOOR_ISSUER=${casdoor_issuer}" \
            -e "AUTH_CASDOOR_ID=${casdoor_id}" \
            -e "AUTH_CASDOOR_SECRET=${casdoor_secret}" \
            --restart unless-stopped \
            "$IMAGE" >/dev/null
    fi
    hr
    echo "[SUCCESS] LobeChat Stack is up and running! Port: $LOBECHAT_PORT"
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] Stopping LobeChat Stack..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && deploy_casdoor stop || true
    [ "$USE_INTERNAL_S3" = "true" ] && deploy_rustfs stop || true
    [ "$USE_INTERNAL_REDIS" = "true" ] && deploy_redis stop || true
    [ "$USE_INTERNAL_DB" = "true" ] && deploy_paradedb stop || true
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] Removing LobeChat Stack containers..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && deploy_casdoor rm || true
    [ "$USE_INTERNAL_S3" = "true" ] && deploy_rustfs rm || true
    [ "$USE_INTERNAL_REDIS" = "true" ] && deploy_redis rm || true
    [ "$USE_INTERNAL_DB" = "true" ] && deploy_paradedb rm || true
    docker network rm "${INSTANCE_NAME}_net" 2>/dev/null || true
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy LobeChat Stack data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    local data_dir="$SCRIPT_DIR/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        rm -rf "$data_dir" 2>/dev/null || true
    fi
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && deploy_casdoor purge || true
    [ "$USE_INTERNAL_S3" = "true" ] && deploy_rustfs purge || true
    [ "$USE_INTERNAL_REDIS" = "true" ] && deploy_redis purge || true
    [ "$USE_INTERNAL_DB" = "true" ] && deploy_paradedb purge || true
    docker network rm "${INSTANCE_NAME}_net" 2>/dev/null || true
    hr
    echo "[SUCCESS] LobeChat Stack data has been purged (configs preserved)."
    hr
}

do_status() {
    require_conf
    source "$CONF_FILE"
    docker ps -a --filter "name=^${INSTANCE_NAME}$"
    [ "$USE_INTERNAL_DB" = "true" ] && deploy_paradedb status || true
    [ "$USE_INTERNAL_REDIS" = "true" ] && deploy_redis status || true
    [ "$USE_INTERNAL_S3" = "true" ] && deploy_rustfs status || true
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && deploy_casdoor status || true
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|status}"
    echo "  init    : Generate settings.conf and initialize bundled dependencies, without starting"
    echo "  start   : Start dependencies then the LobeChat container (pure docker run, no compose)"
    echo "  up      : Initialize configs and start containers instantly"
    echo "  stop    : Stop running containers"
    echo "  rm      : Remove containers (Preserves ./data and configs)"
    echo "  purge   : DANGER - Remove containers AND permanently delete ./data (Preserves configs)"
    echo "  status  : Show container running status"
    echo ""
    echo "Internal vs external dependencies are toggled by USE_INTERNAL_* in settings.conf."
    echo "Bundled paradedb/redis/rustfs are delegated via --conf (settings_*.conf live here);"
    echo "casdoor is a sibling app that self-bundles its own DB and keeps config in its own dir."
}

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
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

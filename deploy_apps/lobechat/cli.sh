#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
IMAGE="lobehub/lobehub:latest"
HOOK_RUN_ARGS=()

[ -f "$SCRIPT_DIR/hooks.sh" ] && source "$SCRIPT_DIR/hooks.sh"
hook() { if declare -F "$1" >/dev/null; then "$1"; fi; }

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

# Read one value from a delegated service's config without clobbering our own vars
conf_val() { ( . "$1" >/dev/null 2>&1; printf '%s' "${!2:-}" ); }

# -----------------------------------------------------------------------------
# 3. Special / Business Functions
# -----------------------------------------------------------------------------
generate_settings() {
    local port=$(random_port)
    local vault_sec=$(random_secret)
    local auth_sec=$(random_secret)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="lobechat_${ts: -4}"
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{LOBECHAT_PORT}}/${port}/g" \
        -e "s/{{KEY_VAULTS_SECRET}}/${vault_sec}/g" \
        -e "s/{{AUTH_SECRET}}/${auth_sec}/g" \
        "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [LobeChat Stack] Initializing full-stack configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then
        generate_settings
    fi
    source "$CONF_FILE"
    hook on_init

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
    set -a; source "$CONF_FILE"; set +a

    hook on_start

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

    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] Starting LobeChat core application (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            -p "${LOBECHAT_PORT}:3210" \
            -v "${CONF_DIR}/data/${INSTANCE_NAME}_data:/app/data" \
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
    hook on_stop
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] Removing LobeChat Stack containers..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy LobeChat Stack data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    local data_dir="${CONF_DIR}/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        rm -rf "$data_dir" 2>/dev/null || true
    fi
    hook on_purge
    hr
    echo "[SUCCESS] LobeChat Stack data has been purged (configs preserved)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge} [--conf PATH] [--name NAME]"
    echo "  init    : Generate settings.conf and initialize bundled dependencies, without starting"
    echo "  start   : Start dependencies then the LobeChat container (pure docker run, no compose)"
    echo "  up      : Initialize configs and start containers instantly"
    echo "  stop    : Stop running containers"
    echo "  rm      : Remove containers (Preserves ./data and configs)"
    echo "  purge   : DANGER - Remove containers AND permanently delete ./data (Preserves configs)"
    echo ""
    echo "Internal vs external dependencies are toggled by USE_INTERNAL_* in settings.conf."
    echo "Bundled paradedb/redis/rustfs are delegated via --conf (settings_*.conf live here);"
    echo "casdoor is a sibling app that self-bundles its own DB and keeps config in its own dir."
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

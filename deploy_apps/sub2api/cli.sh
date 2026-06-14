#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Cascade args (--conf/--name) plus any command-specific extras
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
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_sub2api.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
IMAGE="weishaw/sub2api:latest"
HOOK_RUN_ARGS=()   # filled by hooks.sh on_start; injected into docker run

# Optional service-specific operations (bundled deps, networking).
# Absent for simple services; present here because sub2api is composite.
[ -f "$SCRIPT_DIR/hooks.sh" ] && source "$SCRIPT_DIR/hooks.sh"
hook() { if declare -F "$1" >/dev/null; then "$1"; fi; }

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_password() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 24; }
random_key() { openssl rand -hex 32; }

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Sub2API] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() {
    local port=$(random_port)
    local admin_pass=$(random_password)
    local jwt_secret=$(random_key)
    local totp_key=$(random_key)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="sub2api_${ts: -4}"
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{SUB2API_PORT}}/${port}/g" \
        -e "s/{{ADMIN_PASSWORD}}/${admin_pass}/g" \
        -e "s/{{JWT_SECRET}}/${jwt_secret}/g" \
        -e "s/{{TOTP_ENCRYPTION_KEY}}/${totp_key}/g" \
        "$TPL_DIR/settings_sub2api.conf.tpl" > "$CONF_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [Sub2API] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    source "$CONF_FILE"

    # Bundled paradedb + redis init happens in hooks.sh (on_init)
    hook on_init

    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [Sub2API] Initialization completed!"
    hr
    echo "[INFO] Bundled paradedb config: settings_paradedb.conf (managed by deploy/paradedb)"
    echo "[INFO] Bundled redis config:    settings_redis.conf (managed by deploy/redis)"
    echo "[INFO] Run 'bash cli.sh start' to bring up DB + Redis + Sub2API."
    hr
}

do_start() {
    require_conf
    set -a; source "$CONF_FILE"; set +a

    # Bundled deps + networking happen in hooks.sh (on_start), which also fills
    # DB_* / REDIS_HOST connection values and HOOK_RUN_ARGS (--network) below
    hook on_start

    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [Sub2API] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    if container_exists; then
        echo "[INFO] Container '${INSTANCE_NAME}' already exists, starting it..."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            --ulimit nofile=100000:100000 \
            -p "${SUB2API_PORT}:8080" \
            -v "$CONF_DIR/data/${INSTANCE_NAME}_data:/app/data" \
            -e AUTO_SETUP="true" \
            -e SERVER_HOST="0.0.0.0" \
            -e SERVER_PORT="8080" \
            -e SERVER_MODE \
            -e RUN_MODE \
            -e DATABASE_HOST="$SUB2API_DB_HOST" \
            -e DATABASE_PORT="5432" \
            -e DATABASE_USER="$SUB2API_DB_USER" \
            -e DATABASE_PASSWORD="$SUB2API_DB_PASSWORD" \
            -e DATABASE_DBNAME="$SUB2API_DB_NAME" \
            -e DATABASE_SSLMODE="disable" \
            -e DATABASE_MAX_OPEN_CONNS \
            -e DATABASE_MAX_IDLE_CONNS \
            -e DATABASE_CONN_MAX_LIFETIME_MINUTES \
            -e DATABASE_CONN_MAX_IDLE_TIME_MINUTES \
            -e REDIS_HOST="$SUB2API_REDIS_HOST" \
            -e REDIS_PORT="6379" \
            -e REDIS_PASSWORD \
            -e REDIS_DB \
            -e REDIS_POOL_SIZE \
            -e REDIS_MIN_IDLE_CONNS \
            -e REDIS_ENABLE_TLS \
            -e ADMIN_EMAIL \
            -e ADMIN_PASSWORD \
            -e JWT_SECRET \
            -e JWT_EXPIRE_HOUR \
            -e TOTP_ENCRYPTION_KEY \
            -e TZ \
            -e GEMINI_OAUTH_CLIENT_ID \
            -e GEMINI_OAUTH_CLIENT_SECRET \
            -e GEMINI_OAUTH_SCOPES \
            -e GEMINI_QUOTA_POLICY \
            -e GEMINI_CLI_OAUTH_CLIENT_SECRET \
            -e ANTIGRAVITY_OAUTH_CLIENT_SECRET \
            -e ANTIGRAVITY_USER_AGENT_VERSION \
            -e SECURITY_URL_ALLOWLIST_ENABLED \
            -e SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP \
            -e SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS \
            -e SECURITY_URL_ALLOWLIST_UPSTREAM_HOSTS \
            -e UPDATE_PROXY_URL \
            -e GATEWAY_OPENAI_RESPONSE_HEADER_TIMEOUT \
            -e GATEWAY_OPENAI_HTTP2_ENABLED \
            -e GATEWAY_OPENAI_HTTP2_ALLOW_PROXY_FALLBACK_TO_HTTP1 \
            -e GATEWAY_OPENAI_HTTP2_FALLBACK_ERROR_THRESHOLD \
            -e GATEWAY_OPENAI_HTTP2_FALLBACK_WINDOW_SECONDS \
            -e GATEWAY_OPENAI_HTTP2_FALLBACK_TTL_SECONDS \
            -e GATEWAY_IMAGE_STREAM_DATA_INTERVAL_TIMEOUT \
            -e GATEWAY_IMAGE_STREAM_KEEPALIVE_INTERVAL \
            -e GATEWAY_IMAGE_CONCURRENCY_ENABLED \
            -e GATEWAY_IMAGE_CONCURRENCY_MAX_CONCURRENT_REQUESTS \
            -e GATEWAY_IMAGE_CONCURRENCY_OVERFLOW_MODE \
            -e GATEWAY_IMAGE_CONCURRENCY_WAIT_TIMEOUT_SECONDS \
            -e GATEWAY_IMAGE_CONCURRENCY_MAX_WAITING_REQUESTS \
            --health-cmd "wget -q -T 5 -O /dev/null http://localhost:8080/health || exit 1" \
            --health-interval 30s \
            --health-timeout 10s \
            --health-retries 3 \
            --health-start-period 30s \
            --restart unless-stopped \
            "$IMAGE" >/dev/null
    fi
    hr
    echo "[SUCCESS] [Sub2API] Service is up! Web UI: http://<SERVER_IP>:${SUB2API_PORT}"
    echo "[INFO] Admin account: ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}"
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [Sub2API] Stopping service..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    hook on_stop
}

do_rm() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [Sub2API] Removing containers..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy Sub2API (and bundled deps) data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true

    local data_dir="$CONF_DIR/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        # Data is bind-mounted and often written as root inside the container;
        # delete via a throwaway root container to avoid host permission errors.
        docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi

    hook on_purge

    hr
    echo "[SUCCESS] [Sub2API] Data purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] [Sub2API] Removing all generated settings under this service..."
    rm -f "$CONF_DIR"/settings*.conf
    hr
    echo "[SUCCESS] [Sub2API] Reset complete (restored to pristine source files)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|reset} [--conf PATH] [--name NAME]"
    echo "  init        : Generate settings_sub2api.conf (+ bundled paradedb/redis configs), without starting"
    echo "  start       : Start bundled DB + Redis, then the Sub2API container"
    echo "  up          : init + start"
    echo "  stop        : Stop Sub2API (and bundled deps)"
    echo "  rm          : Remove containers (Preserves data and configs)"
    echo "  purge       : DANGER - Remove containers AND delete data (Preserves configs)"
    echo "  reset       : DANGER - purge AND delete ALL settings (back to pristine source files)"
    echo "  network ls  : Show the app network and attached containers"
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
    reset)   do_reset ;;
    network) if declare -F on_network >/dev/null; then require_conf; source "$CONF_FILE"; on_network "${EXTRA_ARGS[@]}"; else do_help; fi ;;
    *)       do_help ;;
esac

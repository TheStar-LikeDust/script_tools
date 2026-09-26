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
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_lobechat.conf}"
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
random_secret() { openssl rand -base64 32; }

generate_jwks() {
    if command -v node >/dev/null 2>&1; then
        node "$SCRIPT_DIR/generate-jwks.cjs"
    else
        # Reuse the app image for a one-off key generator; no extra service/image.
        docker run --rm -i --network none --entrypoint node "$IMAGE" - < "$SCRIPT_DIR/generate-jwks.cjs"
    fi
}

load_conf() {
    require_conf
    source "$CONF_FILE"
    if [ "${USE_INTERNAL_DB+x}" = x ] || [ "${USE_INTERNAL_CASDOOR+x}" = x ]; then
        echo "[ERROR] Legacy full-stack config detected. Use a new directory with --conf for the minimal deployment; see docs/deploy_apps/lobechat.md." >&2
        return 1
    fi
}

container_exists() { docker container inspect "$INSTANCE_NAME" >/dev/null 2>&1; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [LobeChat] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() {
    local port vault_sec auth_sec jwks name
    port=$(random_port)
    vault_sec=$(random_secret)
    auth_sec=$(random_secret)
    jwks=$(generate_jwks)
    name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts
        ts=$(date +%s)
        name="lobechat_${ts: -4}"
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[ERROR] Invalid container name: $name" >&2
        return 1
    fi

    # Base64 secrets contain '/', so use '|' as the sed delimiter.
    ( umask 077
      sed -e "s|{{INSTANCE_NAME}}|${name}|g" \
          -e "s|{{LOBECHAT_PORT}}|${port}|g" \
          -e "s|{{KEY_VAULTS_SECRET}}|${vault_sec}|g" \
          -e "s|{{AUTH_SECRET}}|${auth_sec}|g" \
          -e "s|{{JWKS_KEY}}|${jwks}|g" \
          "$TPL_DIR/settings_lobechat.conf.tpl" > "$CONF_FILE"
    )
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
    load_conf
    hook on_init
    echo "[SUCCESS] Minimal LobeHub configuration is ready."
    echo "Set APP_URL in $CONF_FILE to your browser-facing URL, then run 'bash cli.sh start'."
    echo "Register with email/password on the login page. No Casdoor or SMTP is required."
}

do_start() {
    load_conf
    if [ -z "${APP_URL:-}" ] || [ -z "${JWKS_KEY:-}" ] || [ -z "${KEY_VAULTS_SECRET:-}" ] || [ -z "${AUTH_SECRET:-}" ]; then
        echo "[ERROR] APP_URL, JWKS_KEY, KEY_VAULTS_SECRET and AUTH_SECRET are required." >&2
        return 1
    fi
    hook on_start

    local db_url
    db_url="postgresql://$(conf_val "$PG_CONF" DB_USER):$(conf_val "$PG_CONF" DB_PASSWORD)@$(conf_val "$PG_CONF" INSTANCE_NAME):5432/$(conf_val "$PG_CONF" DB_NAME)"

    if container_exists; then
        echo "[INFO] Starting existing container '$INSTANCE_NAME' (configuration unchanged)."
        docker start "$INSTANCE_NAME" >/dev/null
    else
        docker run -d \
            --name "$INSTANCE_NAME" \
            "${HOOK_RUN_ARGS[@]}" \
            -p "${LOBECHAT_PORT}:3210" \
            -e "DATABASE_URL=${db_url}" \
            -e "DATABASE_DRIVER=node" \
            -e "APP_URL=${APP_URL}" \
            -e "INTERNAL_APP_URL=http://localhost:3210" \
            -e "KEY_VAULTS_SECRET=${KEY_VAULTS_SECRET}" \
            -e "AUTH_SECRET=${AUTH_SECRET}" \
            -e "JWKS_KEY=${JWKS_KEY}" \
            -e "AUTH_SSO_PROVIDERS=" \
            -e "AUTH_DISABLE_EMAIL_PASSWORD=0" \
            -e "AUTH_EMAIL_VERIFICATION=0" \
            -e "AUTH_ALLOWED_EMAILS=${AUTH_ALLOWED_EMAILS:-}" \
            --restart unless-stopped \
            "$IMAGE" >/dev/null
    fi
    echo "[INFO] LobeHub container started: $APP_URL"
    echo "Check database migration and readiness: docker logs -f $INSTANCE_NAME"
    echo "Text chat only: file uploads and knowledge-base attachments require S3."
}

do_stop() {
    load_conf
    hr
    echo "[INFO] Stopping LobeChat Stack..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    hook on_stop
}

do_rm() {
    load_conf
    hr
    echo "[INFO] Removing LobeChat Stack containers..."
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    hook on_rm
}

do_purge() {
    load_conf
    hr
    echo "[WARN] WARNING: Preparing to completely destroy LobeChat Stack data!"
    hr
    docker stop "$INSTANCE_NAME" 2>/dev/null || true
    docker rm "$INSTANCE_NAME" 2>/dev/null || true
    local data_dir="${CONF_DIR}/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        # Data is bind-mounted and often written as root inside the container;
        # delete via a throwaway root container to avoid host permission errors.
        docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi
    hook on_purge
    hr
    echo "[SUCCESS] LobeChat Stack data has been purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] Removing app and bundled DB settings..."
    rm -f "$CONF_FILE" "$PG_CONF"
    hr
    echo "[SUCCESS] LobeChat Stack reset complete (restored to pristine source files)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge|reset} [--conf PATH] [--name NAME]"
    echo "  init    : Generate app/DB settings and keys (Node.js, or one-off app container)"
    echo "  start   : Start bundled Postgres and LobeHub (two containers, no compose)"
    echo "  up      : Initialize configs and start containers instantly"
    echo "  stop    : Stop running containers"
    echo "  rm      : Remove containers (Preserves ./data and configs)"
    echo "  purge   : DANGER - Remove containers AND permanently delete ./data (Preserves configs)"
    echo "  reset   : DANGER - purge AND delete app/DB settings"
    echo ""
    echo "Minimal Server DB deployment: bundled ParadeDB + built-in email/password login."
    echo "No external DB, Casdoor, Redis, RustFS or S3 configuration."
    echo "With Node.js installed, init needs no Docker; otherwise it uses the app image once."
}

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    init)    do_init ;;
    start)   do_start ;;
    up)      do_init; do_start ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    purge)   do_purge ;;
    reset)   do_reset ;;
    network) if declare -F on_network >/dev/null; then load_conf; on_network "${EXTRA_ARGS[@]}"; else do_help; fi ;;
    *)       do_help ;;
esac

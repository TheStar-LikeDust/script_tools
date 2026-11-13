#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

CONF_FILE=""
NAME_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        ls) [ "$COMMAND" = network ] || { echo "[ERROR] Unknown option: $1" >&2; exit 2; }; shift ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_lobechat.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
IMAGE="lobehub/lobehub:latest"
DOCKER_NETWORK=""
DB_HOST=""
DB_PORT=5432
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_SSLMODE=disable
APP_URL=""
KEY_VAULTS_SECRET=""
AUTH_SECRET=""
JWKS_KEY=""
AUTH_ALLOWED_EMAILS=""
COMPOSIO_API_KEY=""
AUTH_SSO_PROVIDERS=""
AUTH_CASDOOR_ID=""
AUTH_CASDOOR_SECRET=""
AUTH_CASDOOR_ISSUER=""
ENABLED_OPENAI=1
OPENAI_API_KEY=""
OPENAI_PROXY_URL=""
OPENAI_MODEL_LIST=""
REDIS_URL=""
REDIS_DATABASE=0
REDIS_PREFIX=lobechat
S3_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY_ID=""
S3_SECRET_ACCESS_KEY=""

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 32; }
random_initial_email() { printf 'lobe-%s@example.invalid' "$(openssl rand -hex 8)"; }

generate_jwks() {
    local -a node_cmd
    if command -v node >/dev/null 2>&1; then
        node_cmd=(node)
    else
        # Reuse the app image for a one-off key generator.
        node_cmd=(docker run --rm -i --network none --entrypoint node "$IMAGE")
    fi
    "${node_cmd[@]}" --input-type=commonjs - <<'JS'
const { generateKeyPairSync, randomUUID } = require('node:crypto');
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const key = {
  ...privateKey.export({ format: 'jwk' }),
  alg: 'RS256',
  use: 'sig',
  kid: randomUUID(),
};
process.stdout.write(JSON.stringify({ keys: [key] }));
JS
}

urlencode() {
    local LC_ALL=C value="$1" char index
    for ((index = 0; index < ${#value}; index++)); do
        char="${value:index:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
            *) printf '%%%02X' "'$char" ;;
        esac
    done
}

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [LobeHub] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    if [[ ! "$INSTANCE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
    if [ -n "$DOCKER_NETWORK" ] && [[ ! "$DOCKER_NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[ERROR] DOCKER_NETWORK contains unsupported characters." >&2
        return 1
    fi

    local db_host="$DB_HOST"
    if [[ "$db_host" == *:* && "$db_host" != \[*\] ]]; then
        db_host="[$db_host]"
    fi
    DATABASE_URL="postgresql://$(urlencode "$DB_USER"):$(urlencode "$DB_PASSWORD")@${db_host}:${DB_PORT}/$(urlencode "$DB_NAME")?sslmode=$(urlencode "$DB_SSLMODE")"
    export IMAGE DOCKER_NETWORK DATABASE_URL
}

require_connections() {
    local key
    for key in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE REDIS_URL S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY APP_URL JWKS_KEY KEY_VAULTS_SECRET AUTH_SECRET; do
        if [ -z "${!key:-}" ]; then
            echo "[ERROR] Set $key in $CONF_FILE before starting. Provision external dependencies first; see docs/deploy_apps/lobechat.md." >&2
            return 1
        fi
    done
}

compose() {
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local container labels
    container="$(docker container ls -a --filter "name=^/${INSTANCE_NAME}$" --format '{{.Names}}')"
    [ -n "$container" ] || return 0
    labels="$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$INSTANCE_NAME")"
    if [ "$labels" != "$INSTANCE_NAME/lobechat" ]; then
        echo "[ERROR] '$INSTANCE_NAME' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() (
    umask 077
    local port vault_sec auth_sec jwks initial_email name
    port=$(random_port)
    vault_sec=$(random_secret)
    auth_sec=$(random_secret)
    jwks=$(generate_jwks)
    initial_email=$(random_initial_email)
    name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts
        ts=$(date +%s)
        name="lobechat_${ts: -4}"
    fi
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi

    # Generated base64 secrets contain '/', so use '|' as the sed delimiter.
    sed -e "s|{{INSTANCE_NAME}}|${name}|g" \
        -e "s|{{LOBECHAT_PORT}}|${port}|g" \
        -e "s|{{KEY_VAULTS_SECRET}}|${vault_sec}|g" \
        -e "s|{{AUTH_SECRET}}|${auth_sec}|g" \
        -e "s|{{JWKS_KEY}}|${jwks}|g" \
        -e "s|{{AUTH_ALLOWED_EMAILS}}|${initial_email}|g" \
        "$TPL_DIR/settings_lobechat.conf.tpl" > "$CONF_FILE"
)

generate_compose() {
    cat "$TPL_DIR/compose.yaml.tpl" > "$COMPOSE_FILE"
    if [ -n "$DOCKER_NETWORK" ]; then
        cat >> "$COMPOSE_FILE" <<'YAML'
networks:
  default:
    external: true
    name: "${DOCKER_NETWORK}"
YAML
    fi
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
    load_settings
    generate_compose
    echo "[SUCCESS] LobeHub settings and Compose YAML are ready."
    echo "Configure DB_*, Redis, S3 and APP_URL in $CONF_FILE, then run 'bash cli.sh start'."
    echo "Keep the generated keys; replace AUTH_ALLOWED_EMAILS with a real email or domain."
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl instead)"
    hr
}

do_start() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    hr
    compose up -d
    echo "[INFO] LobeHub container started: $APP_URL"
    echo "Check database migration and readiness: docker logs -f $INSTANCE_NAME"
    hr
}

do_update() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    hr
    compose pull
    compose up -d
    echo "[SUCCESS] LobeHub image updated; settings, keys and external data were preserved."
    hr
}

do_stop() {
    load_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    compose stop
}

do_rm() {
    load_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    compose down
}

do_purge() {
    do_rm
    echo "[INFO] LobeHub has no application-owned bind mount to purge. External PostgreSQL, Redis and S3 data were preserved."
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    echo "[SUCCESS] Removed only this app's settings and generated YAML. Keep a backup of the keys for the external database."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network [ls]} [--conf PATH] [--name NAME]"
    echo "  init    : Generate missing app settings and keys, then Compose YAML; do not start"
    echo "  start   : Refresh YAML and start only LobeHub with Docker Compose"
    echo "  up      : init + start (external connections must already be configured)"
    echo "  update  : Pull the configured image and recreate the app if needed"
    echo "  stop    : Stop only LobeHub"
    echo "  rm      : Remove only this Compose project; preserve settings and external data"
    echo "  purge   : Same as rm; this app has no local bind mount to delete"
    echo "  reset   : DANGER - purge, then delete only this settings file and generated YAML"
    echo "  network : Inspect the configured Docker network; never create or remove it"
    echo "  --conf PATH : Config location; Compose YAML stays beside it"
    echo "  --name NAME : Instance name written only when generating new settings"
    echo "With Node.js installed, init needs no Docker; otherwise it uses the app image once for JWKS."
}

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    init)    do_init ;;
    start)   do_start ;;
    up)      do_init; do_start ;;
    update)  do_update ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    purge)   do_purge ;;
    reset)   do_reset ;;
    network) do_network ;;
    *)       do_help ;;
esac

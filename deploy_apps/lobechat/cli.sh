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
LOBECHAT_PORT=""
POSTGRES_IMAGE=""
REDIS_IMAGE=""
RUSTFS_IMAGE=""
RUSTFS_INIT_IMAGE=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_SSLMODE=""
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
REDIS_DATABASE=""
REDIS_PREFIX=""
RUSTFS_PORT=""
RUSTFS_ADMIN_PORT=""
S3_ENDPOINT=""
S3_INTERNAL_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY_ID=""
S3_SECRET_ACCESS_KEY=""

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 32; }

save_setting() (
    umask 077
    local key="$1" value="$2" line found=false temp_file
    temp_file="$(mktemp "${CONF_FILE}.tmp.XXXXXX")"
    trap 'rm -f -- "$temp_file"' EXIT
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}= ]]; then
            if [ "$found" = false ]; then
                printf '%s=%q\n' "$key" "$value"
                found=true
            fi
        else
            printf '%s\n' "$line"
        fi
    done < "$CONF_FILE" > "$temp_file"
    if [ "$found" = false ]; then
        printf '%s=%q\n' "$key" "$value" >> "$temp_file"
    fi
    mv -- "$temp_file" "$CONF_FILE"
)

complete_settings() {
    local key value
    for key in LOBECHAT_PORT POSTGRES_IMAGE REDIS_IMAGE RUSTFS_IMAGE RUSTFS_INIT_IMAGE \
        DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE \
        REDIS_DATABASE REDIS_PREFIX REDIS_URL RUSTFS_PORT RUSTFS_ADMIN_PORT \
        S3_INTERNAL_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
        [ -z "${!key:-}" ] || continue
        case "$key" in
            LOBECHAT_PORT) value="$(random_port)" ;;
            POSTGRES_IMAGE) value="paradedb/paradedb:latest-pg17" ;;
            REDIS_IMAGE) value="redis:7-alpine" ;;
            RUSTFS_IMAGE) value="rustfs/rustfs:latest" ;;
            RUSTFS_INIT_IMAGE) value="rustfs/rc:latest" ;;
            DB_HOST) value="${INSTANCE_NAME}_postgres" ;;
            DB_PORT) value=5432 ;;
            DB_NAME|DB_USER|S3_BUCKET) value=lobechat ;;
            DB_PASSWORD|S3_SECRET_ACCESS_KEY) value="$(random_secret)" ;;
            DB_SSLMODE) value=disable ;;
            REDIS_DATABASE) value=0 ;;
            REDIS_PREFIX) value="$INSTANCE_NAME" ;;
            REDIS_URL) value="redis://${INSTANCE_NAME}_redis:6379/${REDIS_DATABASE}" ;;
            RUSTFS_PORT)
                value="$(random_port)"
                while [ "$value" = "$LOBECHAT_PORT" ] || [ "$value" = "$RUSTFS_ADMIN_PORT" ]; do
                    value="$(random_port)"
                done
                ;;
            RUSTFS_ADMIN_PORT)
                value="$(random_port)"
                while [ "$value" = "$LOBECHAT_PORT" ] || [ "$value" = "$RUSTFS_PORT" ]; do
                    value="$(random_port)"
                done
                ;;
            S3_INTERNAL_ENDPOINT) value="http://${INSTANCE_NAME}_rustfs:9000" ;;
            S3_ACCESS_KEY_ID) value="$(openssl rand -hex 10)" ;;
        esac
        save_setting "$key" "$value"
        printf -v "$key" '%s' "$value"
    done
}

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

ensure_jwks() {
    if [ -z "$JWKS_KEY" ]; then
        JWKS_KEY="$(generate_jwks)"
        save_setting JWKS_KEY "$JWKS_KEY"
    fi
    export JWKS_KEY
}

rustfs_uid_gid() (
    local probe_name="" passwd_dir passwd_file uid_gid
    passwd_dir="$(mktemp -d)"
    passwd_file="$passwd_dir/passwd"
    trap '[ -z "$probe_name" ] || docker rm -f "$probe_name" >/dev/null; rm -f -- "$passwd_file"; rmdir -- "$passwd_dir"' EXIT

    if ! docker image inspect "$RUSTFS_IMAGE" >/dev/null 2>&1; then
        docker pull "$RUSTFS_IMAGE" >/dev/null
    fi
    probe_name="$(docker create "$RUSTFS_IMAGE")"
    docker cp "$probe_name:/etc/passwd" "$passwd_file" >/dev/null
    uid_gid="$(awk -F: '$1 == "rustfs" { print $3 ":" $4; exit }' "$passwd_file")"
    if [ -z "$uid_gid" ]; then
        echo "[ERROR] [RustFS] Could not resolve the UID/GID for image user 'rustfs'." >&2
        return 1
    fi
    printf '%s' "$uid_gid"
)

ensure_data_owner() {
    local data_dir="$1" uid_gid current_owner
    uid_gid="$(rustfs_uid_gid)"
    current_owner="$(stat -c '%u:%g' "$data_dir")"
    if [ "$current_owner" != "$uid_gid" ]; then
        echo "[INFO] [RustFS] Setting data directory ownership to $uid_gid."
        chown -R "$uid_gid" "$data_dir"
    fi
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
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
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
    export IMAGE DOCKER_NETWORK DATABASE_URL POSTGRES_IMAGE REDIS_IMAGE RUSTFS_IMAGE RUSTFS_INIT_IMAGE
}

require_connections() {
    local key
    for key in LOBECHAT_PORT POSTGRES_IMAGE REDIS_IMAGE RUSTFS_IMAGE RUSTFS_INIT_IMAGE \
        DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE REDIS_URL REDIS_DATABASE REDIS_PREFIX \
        RUSTFS_PORT RUSTFS_ADMIN_PORT S3_ENDPOINT S3_INTERNAL_ENDPOINT S3_BUCKET \
        S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY APP_URL AUTH_ALLOWED_EMAILS KEY_VAULTS_SECRET AUTH_SECRET; do
        if [ -z "${!key:-}" ]; then
            echo "[ERROR] Set $key in $CONF_FILE before starting. Run init to complete bundled defaults; see docs/deploy_apps/lobechat.md." >&2
            return 1
        fi
    done
    if [ "$LOBECHAT_PORT" = "$RUSTFS_PORT" ] || [ "$LOBECHAT_PORT" = "$RUSTFS_ADMIN_PORT" ] || [ "$RUSTFS_PORT" = "$RUSTFS_ADMIN_PORT" ]; then
        echo "[ERROR] LOBECHAT_PORT, RUSTFS_PORT and RUSTFS_ADMIN_PORT must be different." >&2
        return 1
    fi
}

compose() {
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local service container_name container labels
    for service in lobechat postgres redis rustfs rustfs_init; do
        container_name="${INSTANCE_NAME}_${service}"
        if [ "$service" = lobechat ]; then container_name="$INSTANCE_NAME"; fi
        container="$(docker container ls -a --filter "name=^/$container_name$" --format '{{.Names}}')"
        [ -n "$container" ] || continue
        labels="$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$container_name")"
        if [ "$labels" != "$INSTANCE_NAME/$service" ]; then
            echo "[ERROR] '$container_name' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
            return 1
        fi
    done
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() (
    umask 077
    local port vault_sec auth_sec name
    port=$(random_port)
    vault_sec=$(random_secret)
    auth_sec=$(random_secret)
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
    complete_settings
    load_settings
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data" "$CONF_DIR/data/${INSTANCE_NAME}_rustfs_data"
    echo "[SUCCESS] LobeHub, PostgreSQL, Redis and RustFS configuration is ready."
    echo "Set APP_URL, S3_ENDPOINT and a real AUTH_ALLOWED_EMAILS in $CONF_FILE before start."
    echo "Application port: $LOBECHAT_PORT; S3 API port: $RUSTFS_PORT; RustFS console port: $RUSTFS_ADMIN_PORT."
    echo "Existing nonempty settings and keys were preserved. Missing JWKS will be generated on start."
    echo "Bucket CORS is not configured automatically; see docs/deploy_apps/lobechat.md."
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl instead)"
    hr
}

do_start() {
    load_settings
    require_connections
    require_managed_container
    ensure_jwks
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data" "$CONF_DIR/data/${INSTANCE_NAME}_rustfs_data"
    ensure_data_owner "$CONF_DIR/data/${INSTANCE_NAME}_rustfs_data"
    hr
    compose up -d
    echo "[INFO] LobeHub stack started: $APP_URL"
    echo "Check database migration and readiness: docker logs -f $INSTANCE_NAME"
    hr
}

do_update() {
    load_settings
    require_connections
    require_managed_container
    ensure_jwks
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data" "$CONF_DIR/data/${INSTANCE_NAME}_rustfs_data"
    hr
    compose pull
    ensure_data_owner "$CONF_DIR/data/${INSTANCE_NAME}_rustfs_data"
    compose up -d
    echo "[SUCCESS] LobeHub and bundled dependencies updated; settings, keys and data were preserved."
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
    if [ -d "$CONF_DIR/data" ]; then
        docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf \
            "/purge/${INSTANCE_NAME}_postgres_data" \
            "/purge/${INSTANCE_NAME}_redis_data" \
            "/purge/${INSTANCE_NAME}_rustfs_data"
    fi
    echo "[SUCCESS] This instance's PostgreSQL, Redis and RustFS data removed; settings and keys were preserved."
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    echo "[SUCCESS] This instance's stack, data, settings and generated YAML were removed."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network [ls]} [--conf PATH] [--name NAME]"
    echo "  init    : Generate/complete stack settings, Compose YAML and data dirs; no Docker required"
    echo "  start   : Generate missing JWKS and start LobeHub with PostgreSQL, Redis and RustFS"
    echo "  up      : init + start (APP_URL, S3_ENDPOINT and AUTH_ALLOWED_EMAILS must be set)"
    echo "  update  : Pull all configured stack images and apply them with Compose"
    echo "  stop    : Stop this entire LobeHub stack"
    echo "  rm      : Remove this stack's containers/private network; preserve settings and data"
    echo "  purge   : DANGER - rm and delete this instance's PostgreSQL, Redis and RustFS data"
    echo "  reset   : DANGER - purge, then delete this settings file and generated YAML"
    echo "  network : Inspect the configured Docker network; never create or remove it"
    echo "  --conf PATH : Config location; Compose YAML and all stack data stay beside it"
    echo "  --name NAME : Instance name written only when generating new settings"
    echo "On start, missing JWKS uses host Node.js or a one-off application container."
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

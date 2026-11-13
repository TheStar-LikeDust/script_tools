#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

CONF_FILE=""
NAME_OVERRIDE=""
declare -A INIT_VALUES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --conf|--name|--app-url|--s3-endpoint|--auth-allowed-emails)
            [ $# -ge 2 ] || { echo "[ERROR] $1 requires a value." >&2; exit 2; }
            case "$1" in
                --conf) CONF_FILE="$2" ;;
                --name) NAME_OVERRIDE="$2" ;;
                *)
                    case "$COMMAND" in
                        init|up) ;;
                        *) echo "[ERROR] $1 requires init or up." >&2; exit 2 ;;
                    esac
                    case "$1" in
                        --app-url) INIT_VALUES[APP_URL]="$2" ;;
                        --s3-endpoint) INIT_VALUES[S3_ENDPOINT]="$2" ;;
                        --auth-allowed-emails) INIT_VALUES[AUTH_ALLOWED_EMAILS]="$2" ;;
                    esac
                    ;;
            esac
            shift 2
            ;;
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
PARADEDB_CONF=""
REDIS_CONF=""
RUSTFS_CONF=""
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
REDIS_DATABASE=""
REDIS_PREFIX=""
S3_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY_ID=""
S3_SECRET_ACCESS_KEY=""
source "$SCRIPT_DIR/hooks.sh"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 32; }
default_bucket_name() {
    local instance_name="$1" normalized hash
    normalized="${instance_name//_/-}"
    hash="$(printf '%s' "$instance_name" | sha256sum | cut -c1-12)" || return
    printf 'lobe-%s-%s' "${normalized:0:38}" "$hash"
}

save_setting() (
    umask 077
    local key="$1" value="$2" line found=false temp_file
    temp_file="$(mktemp "${CONF_FILE}.tmp.XXXXXX")" || return
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
    done < "$CONF_FILE" > "$temp_file" || return
    if [ "$found" = false ]; then
        printf '%s=%q\n' "$key" "$value" >> "$temp_file" || return
    fi
    mv -- "$temp_file" "$CONF_FILE"
)

complete_settings() {
    local key value
    for key in IMAGE DOCKER_NETWORK LOBECHAT_PORT PARADEDB_CONF REDIS_CONF RUSTFS_CONF \
        REDIS_DATABASE REDIS_PREFIX S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY \
        APP_URL S3_ENDPOINT AUTH_ALLOWED_EMAILS KEY_VAULTS_SECRET AUTH_SECRET; do
        [ -n "${!key:-}" ] && continue
        case "$key" in
            IMAGE) value="lobehub/lobehub:latest" ;;
            DOCKER_NETWORK) value="" ;;
            LOBECHAT_PORT) value="$(random_port)" || return ;;
            PARADEDB_CONF) value="settings_paradedb.conf" ;;
            REDIS_CONF) value="settings_redis.conf" ;;
            RUSTFS_CONF) value="settings_rustfs.conf" ;;
            REDIS_DATABASE) value=0 ;;
            REDIS_PREFIX) value="$INSTANCE_NAME" ;;
            S3_BUCKET) value="$(default_bucket_name "$INSTANCE_NAME")" || return ;;
            S3_ACCESS_KEY_ID) value="$(openssl rand -hex 10)" || return ;;
            S3_SECRET_ACCESS_KEY|KEY_VAULTS_SECRET|AUTH_SECRET) value="$(random_secret)" || return ;;
            APP_URL|S3_ENDPOINT|AUTH_ALLOWED_EMAILS) value="${INIT_VALUES[$key]-}" ;;
        esac
        save_setting "$key" "$value" || return
        printf -v "$key" '%s' "$value"
    done
}

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [LobeHub] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    local key
    for key in INSTANCE_NAME IMAGE DOCKER_NETWORK LOBECHAT_PORT PARADEDB_CONF REDIS_CONF RUSTFS_CONF \
        APP_URL KEY_VAULTS_SECRET AUTH_SECRET JWKS_KEY AUTH_ALLOWED_EMAILS COMPOSIO_API_KEY \
        AUTH_SSO_PROVIDERS AUTH_CASDOOR_ID AUTH_CASDOOR_SECRET AUTH_CASDOOR_ISSUER \
        OPENAI_API_KEY OPENAI_PROXY_URL OPENAI_MODEL_LIST REDIS_DATABASE REDIS_PREFIX \
        S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
        printf -v "$key" '%s' ""
    done
    ENABLED_OPENAI=1
    set -a
    source <(sed 's/\r$//' "$CONF_FILE") || return
    set +a
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
    if [ -n "$DOCKER_NETWORK" ] && [[ ! "$DOCKER_NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[ERROR] DOCKER_NETWORK contains unsupported characters." >&2
        return 1
    fi
}

require_connections() {
    local key
    for key in LOBECHAT_PORT APP_URL AUTH_ALLOWED_EMAILS KEY_VAULTS_SECRET AUTH_SECRET \
        S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
        if [ -z "${!key:-}" ]; then
            echo "[ERROR] Set $key in $CONF_FILE before starting. Run init to complete bundled defaults; see docs/deploy_apps/lobechat.md." >&2
            return 1
        fi
    done
    if [[ ! "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
        echo "[ERROR] S3_BUCKET must use 3-63 lowercase letters, digits or hyphens." >&2
        return 1
    fi
}

compose() {
    export_app_compose_environment
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local service container_name container labels
    for service in lobechat postgres redis rustfs; do
        case "$service" in
            lobechat) container_name="$INSTANCE_NAME" ;;
            postgres) container_name="$PARADEDB_INSTANCE_NAME" ;;
            redis) container_name="$REDIS_INSTANCE_NAME" ;;
            rustfs) container_name="$RUSTFS_INSTANCE_NAME" ;;
        esac
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
    local port vault_sec auth_sec name bucket
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
    bucket="$(default_bucket_name "$name")" || return

    sed -e "s|{{INSTANCE_NAME}}|${name}|g" \
        -e "s|{{LOBECHAT_PORT}}|${port}|g" \
        -e "s|{{S3_BUCKET}}|${bucket}|g" \
        -e "s|{{KEY_VAULTS_SECRET}}|${vault_sec}|g" \
        -e "s|{{AUTH_SECRET}}|${auth_sec}|g" \
        "$TPL_DIR/settings_lobechat.conf.tpl" > "$CONF_FILE"
)

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
    load_settings
    complete_settings
    load_settings
    prepare_dependency_settings
    load_dependency_environment
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${RUSTFS_INSTANCE_NAME}_data"

    printf '\n[SUCCESS] LobeHub configuration is ready.\n\n'
    printf '  App:       %s\n  ParadeDB:  %s\n  Redis:     %s\n  RustFS:    %s\n  Compose:   %s\n' \
        "$CONF_FILE" "$(resolve_dependency_conf paradedb)" "$(resolve_dependency_conf redis)" \
        "$(resolve_dependency_conf rustfs)" "$COMPOSE_FILE"
    printf '  App URL:   %s\n  S3 URL:    %s\n  Sign-up:   %s\n' \
        "${APP_URL:-set APP_URL before start}" "${S3_ENDPOINT:-set S3_ENDPOINT before start}" \
        "${AUTH_ALLOWED_EMAILS:-set a real AUTH_ALLOWED_EMAILS value before start}"
    printf '  App port:  %s\n  S3 port:   %s\n  Console:   %s\n\n' \
        "$LOBECHAT_PORT" "$RUSTFS_PORT" "$RUSTFS_ADMIN_PORT"
    printf '  S3 bucket: %s\n  Existing nonempty settings and keys were preserved.\n' "$S3_BUCKET"
    printf '  Compose YAML is generated; edit templates/compose.yaml.tpl for persistent changes.\n\n'
}

do_start() {
    load_settings
    load_dependency_environment
    require_connections
    require_managed_container
    ensure_jwks
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${RUSTFS_INSTANCE_NAME}_data"
    prepare_rustfs_data

    printf '\n[INFO] Starting PostgreSQL, Redis and RustFS...\n'
    compose up -d postgres redis rustfs
    initialize_rustfs_resources
    printf '\n[INFO] Starting LobeHub at %s...\n' "$APP_URL"
    compose up -d lobechat
    printf '\n[SUCCESS] LobeHub stack started.\n'
    printf '  App: %s\n  Logs: docker logs -f %s\n\n' "$APP_URL" "$INSTANCE_NAME"
}

do_update() {
    load_settings
    load_dependency_environment
    require_connections
    require_managed_container
    ensure_jwks
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${RUSTFS_INSTANCE_NAME}_data"
    compose pull
    prepare_rustfs_data
    compose up -d postgres redis rustfs
    initialize_rustfs_resources
    compose up -d lobechat
    printf '\n[SUCCESS] LobeHub, ParadeDB, Redis and RustFS updated; settings and data were preserved.\n\n'
}

do_stop() {
    load_settings
    load_dependency_environment
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || render_compose
    compose stop
}

do_rm() {
    load_settings
    load_dependency_environment
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || render_compose
    compose down
}

do_purge() {
    do_rm
    if [ -d "$CONF_DIR/data" ]; then
        docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf \
            "/purge/${INSTANCE_NAME}_data" \
            "/purge/${PARADEDB_INSTANCE_NAME}_data" \
            "/purge/${REDIS_INSTANCE_NAME}_data" \
            "/purge/${RUSTFS_INSTANCE_NAME}_data"
    fi
    echo "[SUCCESS] LobeHub, ParadeDB, Redis and RustFS data removed; settings and keys were preserved."
}

do_reset() {
    do_purge
    remove_dependency_settings
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    echo "[SUCCESS] This instance's stack, data, app settings, dependency settings and generated YAML were removed."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network [ls]} [--conf PATH] [options]"
    echo "  init    : Prepare app and service settings, render dependency fragments and create data dirs"
    echo "  start   : Start PostgreSQL, Redis and RustFS, initialize S3 resources, then start LobeHub"
    echo "  up      : init + start (APP_URL, S3_ENDPOINT and AUTH_ALLOWED_EMAILS must be set)"
    echo "  update  : Pull all configured images, initialize missing S3 resources and apply the stack"
    echo "  stop    : Stop this entire LobeHub stack"
    echo "  rm      : Remove this stack's containers/private network; preserve settings and data"
    echo "  purge   : DANGER - rm and delete this instance's PostgreSQL, Redis and RustFS data"
    echo "  reset   : DANGER - purge, then delete app and local dependency settings and generated YAML"
    echo "  network : Inspect the configured Docker network; never create or remove it"
    echo "  --conf PATH : Config location; Compose YAML and all stack data stay beside it"
    echo "  --name NAME : Instance name written only when generating new settings"
    echo "Init/up options (existing nonempty settings always win):"
    echo "  --app-url URL             : Browser-facing LobeHub URL"
    echo "  --s3-endpoint URL         : S3 API URL reachable by browsers and the application"
    echo "  --auth-allowed-emails LIST: Real sign-up email addresses or domains"
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
    help)    do_help ;;
    *)       do_help; exit 2 ;;
esac

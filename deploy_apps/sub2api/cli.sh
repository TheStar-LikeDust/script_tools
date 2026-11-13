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
        ls)
            if [ "$COMMAND" != network ]; then
                echo "[ERROR] Unknown option: $1" >&2
                exit 2
            fi
            shift
            ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_sub2api.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
IMAGE="weishaw/sub2api:latest"
DOCKER_NETWORK=""
PARADEDB_CONF=""
REDIS_CONF=""
REDIS_DB=""
REDIS_ENABLE_TLS=""
source "$SCRIPT_DIR/hooks.sh"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_password() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 24; }
random_key() { openssl rand -hex 32; }
random_letters() { openssl rand -base64 48 | tr -dc 'a-z' | head -c 4; }

save_setting() (
    umask 077
    local key="$1" value="$2" setting temp_file
    printf -v setting '%s=%q' "$key" "$value"
    temp_file="$(mktemp "${CONF_FILE}.tmp.XXXXXX")"
    trap 'rm -f -- "$temp_file"' EXIT
    SETTING_LINE="$setting" awk -v key="$key" '
        {
            sub(/\r$/, "")
            if ($0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=") {
                if (!written) print ENVIRON["SETTING_LINE"]
                written = 1
            } else {
                print
            }
        }
        END { if (!written) print ENVIRON["SETTING_LINE"] }
    ' "$CONF_FILE" > "$temp_file"
    mv -- "$temp_file" "$CONF_FILE"
)

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Sub2API] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    local key
    for key in INSTANCE_NAME SUB2API_PORT IMAGE DOCKER_NETWORK TZ SERVER_MODE RUN_MODE \
        PARADEDB_CONF REDIS_CONF ADMIN_EMAIL ADMIN_PASSWORD JWT_SECRET JWT_EXPIRE_HOUR \
        TOTP_ENCRYPTION_KEY DATABASE_MAX_OPEN_CONNS DATABASE_MAX_IDLE_CONNS \
        DATABASE_CONN_MAX_LIFETIME_MINUTES DATABASE_CONN_MAX_IDLE_TIME_MINUTES \
        REDIS_DB REDIS_POOL_SIZE REDIS_MIN_IDLE_CONNS REDIS_ENABLE_TLS \
        GEMINI_OAUTH_CLIENT_ID GEMINI_OAUTH_CLIENT_SECRET GEMINI_OAUTH_SCOPES GEMINI_QUOTA_POLICY \
        GEMINI_CLI_OAUTH_CLIENT_SECRET ANTIGRAVITY_OAUTH_CLIENT_SECRET ANTIGRAVITY_USER_AGENT_VERSION \
        SECURITY_URL_ALLOWLIST_ENABLED SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP \
        SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS SECURITY_URL_ALLOWLIST_UPSTREAM_HOSTS \
        UPDATE_PROXY_URL GATEWAY_OPENAI_RESPONSE_HEADER_TIMEOUT GATEWAY_OPENAI_HTTP2_ENABLED \
        GATEWAY_OPENAI_HTTP2_ALLOW_PROXY_FALLBACK_TO_HTTP1 GATEWAY_OPENAI_HTTP2_FALLBACK_ERROR_THRESHOLD \
        GATEWAY_OPENAI_HTTP2_FALLBACK_WINDOW_SECONDS GATEWAY_OPENAI_HTTP2_FALLBACK_TTL_SECONDS \
        GATEWAY_IMAGE_STREAM_DATA_INTERVAL_TIMEOUT GATEWAY_IMAGE_STREAM_KEEPALIVE_INTERVAL \
        GATEWAY_IMAGE_CONCURRENCY_ENABLED GATEWAY_IMAGE_CONCURRENCY_MAX_CONCURRENT_REQUESTS \
        GATEWAY_IMAGE_CONCURRENCY_OVERFLOW_MODE GATEWAY_IMAGE_CONCURRENCY_WAIT_TIMEOUT_SECONDS \
        GATEWAY_IMAGE_CONCURRENCY_MAX_WAITING_REQUESTS; do
        printf -v "$key" '%s' ''
    done
    # Read CRLF files without rewriting existing settings.
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    export IMAGE DOCKER_NETWORK PARADEDB_CONF REDIS_CONF
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
}

complete_settings() {
    local key value
    for key in IMAGE SUB2API_PORT PARADEDB_CONF REDIS_CONF TZ SERVER_MODE RUN_MODE \
        ADMIN_EMAIL ADMIN_PASSWORD JWT_SECRET JWT_EXPIRE_HOUR TOTP_ENCRYPTION_KEY \
        DATABASE_MAX_OPEN_CONNS DATABASE_MAX_IDLE_CONNS DATABASE_CONN_MAX_LIFETIME_MINUTES \
        DATABASE_CONN_MAX_IDLE_TIME_MINUTES REDIS_DB REDIS_POOL_SIZE REDIS_MIN_IDLE_CONNS \
        REDIS_ENABLE_TLS SECURITY_URL_ALLOWLIST_ENABLED SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP \
        SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS GATEWAY_OPENAI_RESPONSE_HEADER_TIMEOUT \
        GATEWAY_OPENAI_HTTP2_ENABLED GATEWAY_OPENAI_HTTP2_ALLOW_PROXY_FALLBACK_TO_HTTP1 \
        GATEWAY_OPENAI_HTTP2_FALLBACK_ERROR_THRESHOLD GATEWAY_OPENAI_HTTP2_FALLBACK_WINDOW_SECONDS \
        GATEWAY_OPENAI_HTTP2_FALLBACK_TTL_SECONDS GATEWAY_IMAGE_STREAM_DATA_INTERVAL_TIMEOUT \
        GATEWAY_IMAGE_STREAM_KEEPALIVE_INTERVAL GATEWAY_IMAGE_CONCURRENCY_ENABLED \
        GATEWAY_IMAGE_CONCURRENCY_MAX_CONCURRENT_REQUESTS GATEWAY_IMAGE_CONCURRENCY_OVERFLOW_MODE \
        GATEWAY_IMAGE_CONCURRENCY_WAIT_TIMEOUT_SECONDS GATEWAY_IMAGE_CONCURRENCY_MAX_WAITING_REQUESTS; do
        [ -z "${!key:-}" ] || continue
        case "$key" in
            IMAGE) value="weishaw/sub2api:latest" ;;
            SUB2API_PORT) value="$(random_port)" ;;
            PARADEDB_CONF) value="settings_paradedb.conf" ;;
            REDIS_CONF) value="settings_redis.conf" ;;
            TZ) value=Asia/Shanghai ;;
            SERVER_MODE) value=release ;;
            RUN_MODE) value=standard ;;
            ADMIN_EMAIL) value="$(random_letters)@sub2api.local" ;;
            ADMIN_PASSWORD) value="$(random_password)" ;;
            JWT_SECRET|TOTP_ENCRYPTION_KEY) value="$(random_key)" ;;
            JWT_EXPIRE_HOUR) value=24 ;;
            DATABASE_MAX_OPEN_CONNS) value=50 ;;
            DATABASE_MAX_IDLE_CONNS) value=10 ;;
            DATABASE_CONN_MAX_LIFETIME_MINUTES) value=30 ;;
            DATABASE_CONN_MAX_IDLE_TIME_MINUTES) value=5 ;;
            REDIS_DB) value=0 ;;
            REDIS_POOL_SIZE) value=1024 ;;
            REDIS_MIN_IDLE_CONNS) value=10 ;;
            REDIS_ENABLE_TLS) value=false ;;
            SECURITY_URL_ALLOWLIST_ENABLED|SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP|SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS) value=false ;;
            GATEWAY_OPENAI_RESPONSE_HEADER_TIMEOUT) value=0 ;;
            GATEWAY_OPENAI_HTTP2_ENABLED|GATEWAY_OPENAI_HTTP2_ALLOW_PROXY_FALLBACK_TO_HTTP1) value=true ;;
            GATEWAY_OPENAI_HTTP2_FALLBACK_ERROR_THRESHOLD) value=2 ;;
            GATEWAY_OPENAI_HTTP2_FALLBACK_WINDOW_SECONDS) value=60 ;;
            GATEWAY_OPENAI_HTTP2_FALLBACK_TTL_SECONDS) value=600 ;;
            GATEWAY_IMAGE_STREAM_DATA_INTERVAL_TIMEOUT) value=900 ;;
            GATEWAY_IMAGE_STREAM_KEEPALIVE_INTERVAL) value=10 ;;
            GATEWAY_IMAGE_CONCURRENCY_ENABLED) value=false ;;
            GATEWAY_IMAGE_CONCURRENCY_MAX_CONCURRENT_REQUESTS) value=0 ;;
            GATEWAY_IMAGE_CONCURRENCY_OVERFLOW_MODE) value=reject ;;
            GATEWAY_IMAGE_CONCURRENCY_WAIT_TIMEOUT_SECONDS) value=30 ;;
            GATEWAY_IMAGE_CONCURRENCY_MAX_WAITING_REQUESTS) value=100 ;;
        esac
        save_setting "$key" "$value"
        printf -v "$key" '%s' "$value"
    done
}

validate_settings() {
    local field
    for field in IMAGE SUB2API_PORT ADMIN_EMAIL ADMIN_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY PARADEDB_CONF REDIS_CONF; do
        if [ -z "${!field:-}" ]; then
            echo "[ERROR] Set $field in $CONF_FILE. Keep application keys with database backups; see docs/deploy_apps/sub2api.md." >&2
            return 1
        fi
    done
}

compose() {
    export_app_compose_environment
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local service container_name container labels
    for service in sub2api postgres redis; do
        case "$service" in
            sub2api) container_name="$INSTANCE_NAME" ;;
            postgres) container_name="$PARADEDB_INSTANCE_NAME" ;;
            redis) container_name="$REDIS_INSTANCE_NAME" ;;
        esac
        container="$(docker container ls -a --filter "name=^/${container_name}$" --format '{{.Names}}')"
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
    local port admin_user admin_pass jwt_secret totp_key name ts
    port=$(random_port)
    admin_user=$(random_letters)
    admin_pass=$(random_password)
    jwt_secret=$(random_key)
    totp_key=$(random_key)
    name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        ts=$(date +%s)
        name="sub2api_${ts: -4}"
    fi
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{SUB2API_PORT}}/${port}/g" \
        -e "s/{{ADMIN_USER}}/${admin_user}/g" \
        -e "s/{{ADMIN_PASSWORD}}/${admin_pass}/g" \
        -e "s/{{JWT_SECRET}}/${jwt_secret}/g" \
        -e "s/{{TOTP_ENCRYPTION_KEY}}/${totp_key}/g" \
        "$TPL_DIR/settings_sub2api.conf.tpl" > "$CONF_FILE"
)

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    [ -f "$CONF_FILE" ] || generate_settings
    load_settings
    complete_settings
    load_settings
    prepare_dependency_settings
    load_dependency_environment
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [Sub2API] Application, ParadeDB and Redis settings are ready."
    echo "  App:       $CONF_FILE"
    echo "  ParadeDB:  $(resolve_dependency_conf paradedb)"
    echo "  Redis:     $(resolve_dependency_conf redis)"
    echo "  Compose:   $COMPOSE_FILE"
    echo "Existing nonempty dependency settings and application keys were preserved."
    echo "Next: bash cli.sh start --conf $CONF_FILE"
    hr
}

do_start() {
    load_settings
    load_dependency_environment
    validate_settings
    require_managed_container
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data"
    compose up -d

    hr
    echo "[INFO] [Sub2API] Bundled instance started: http://<SERVER_IP>:${SUB2API_PORT}"
    echo "Check readiness: docker logs -f $INSTANCE_NAME"
    echo "Initial admin credentials are saved in $CONF_FILE."
    hr
}

do_update() {
    load_settings
    load_dependency_environment
    validate_settings
    require_managed_container
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data"
    compose pull
    compose up -d

    hr
    echo "[SUCCESS] [Sub2API] Application and dependency image updates applied; settings and data were preserved."
    hr
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
    hr
    echo "[WARN] Deleting this instance's application, PostgreSQL and Redis data."
    local data_name
    for data_name in "${INSTANCE_NAME}_data" "${PARADEDB_INSTANCE_NAME}_data" "${REDIS_INSTANCE_NAME}_data"; do
        if [ -d "$CONF_DIR/data/$data_name" ]; then
            # Use a throwaway root container for bind mounts owned by the services.
            docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/$data_name"
        fi
    done
    echo "[SUCCESS] [Sub2API] Bundled instance data purged; settings were preserved."
    hr
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    local dependency_conf dependency_dir dependency_compose
    for dependency_conf in "$(resolve_dependency_conf paradedb)" "$(resolve_dependency_conf redis)"; do
        dependency_dir="$(cd "$(dirname "$dependency_conf")" && pwd)"
        dependency_conf="$dependency_dir/$(basename "$dependency_conf")"
        case "$dependency_conf" in
            "$CONF_DIR"/*)
                dependency_compose="${dependency_conf%.conf}.compose.yaml"
                rm -f -- "$dependency_conf" "$dependency_compose"
                ;;
        esac
    done
    echo "[SUCCESS] [Sub2API] This instance's app and in-directory dependency settings and YAML were removed."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network [ls]} [--conf PATH] [--name NAME]"
    echo "  init        : Generate app and dependency settings, compose YAML and data directories"
    echo "  start       : Start Sub2API with its ParadeDB and Redis Compose services"
    echo "  up          : init + start for the bundled instance"
    echo "  update      : Pull application and dependency images; preserve settings and data"
    echo "  stop        : Stop this instance's application, PostgreSQL and Redis"
    echo "  rm          : Remove only this Compose project; preserve data and settings"
    echo "  purge       : DANGER - rm and delete this instance's application, PostgreSQL and Redis data"
    echo "  reset       : DANGER - purge and delete app/in-directory dependency settings and YAML"
    echo "  network ls  : Inspect the configured network without changing it"
    echo "  --conf PATH : Settings path; YAML and data are relative to its directory"
    echo "  --name NAME : Instance name for a new settings file"
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

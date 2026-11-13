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
if [ "${#EXTRA_ARGS[@]}" -gt 0 ] && { [ "$COMMAND" != network ] || [ "${EXTRA_ARGS[*]}" != ls ]; }; then
    echo "[ERROR] Unknown arguments: ${EXTRA_ARGS[*]}" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_newapi.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
IMAGE="calciumion/new-api:latest"
POSTGRES_IMAGE=""
REDIS_IMAGE=""
DOCKER_NETWORK=""
NEWAPI_PUBLISH_PORT=true
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_SSLMODE=""
REDIS_CONN_STRING=""
CRYPTO_SECRET=""

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32; }
urlencode() {
    local LC_ALL=C value="$1" char index
    for ((index=0; index<${#value}; index++)); do
        char="${value:index:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
            *) printf '%%%02X' "'$char" ;;
        esac
    done
}

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    export IMAGE POSTGRES_IMAGE REDIS_IMAGE DOCKER_NETWORK NEWAPI_PUBLISH_PORT
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
    local db_host="${DB_HOST:-}"
    if [[ "$db_host" == *:* && "$db_host" != \[*\] ]]; then db_host="[$db_host]"; fi
    export SQL_DSN=""
    if [ -n "$db_host" ]; then
        SQL_DSN="postgresql://$(urlencode "${DB_USER:-}"):$(urlencode "${DB_PASSWORD:-}")@$db_host:${DB_PORT:-5432}/$(urlencode "${DB_NAME:-}")?sslmode=$(urlencode "${DB_SSLMODE:-disable}")"
    fi
}

require_connections() {
    local field
    for field in NEWAPI_PORT POSTGRES_IMAGE REDIS_IMAGE DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE REDIS_CONN_STRING CRYPTO_SECRET; do
        if [ -z "${!field:-}" ]; then
            echo "[ERROR] $field is missing in $CONF_FILE. Run 'bash cli.sh init --conf $CONF_FILE' to complete bundled defaults." >&2
            return 1
        fi
    done
}

compose() {
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local service container_name container labels
    for service in newapi postgres redis; do
        container_name="${INSTANCE_NAME}_${service}"
        if [ "$service" = newapi ]; then container_name="$INSTANCE_NAME"; fi
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
    local port secret
    port=$(random_port)
    secret=$(random_secret)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="newapi_${ts: -4}"
    fi

    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] Invalid instance name: $name" >&2
        return 1
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{NEWAPI_PORT}}/${port}/g" \
        -e "s/{{CRYPTO_SECRET}}/${secret}/g" \
        "$TPL_DIR/settings_newapi.conf.tpl" > "$CONF_FILE"
)

save_setting() (
    umask 077
    local key="$1" value="$2" setting_line settings_tmp
    printf -v setting_line '%s=%q' "$key" "$value"
    settings_tmp="$(mktemp "${CONF_FILE}.XXXXXX")"
    trap 'rm -f -- "$settings_tmp"' EXIT
    SETTING_LINE="$setting_line" awk -v key="$key" '
        { sub(/\r$/, "") }
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=" {
            if (!written) print ENVIRON["SETTING_LINE"]
            written = 1
            next
        }
        { print }
        END { if (!written) print ENVIRON["SETTING_LINE"] }
    ' "$CONF_FILE" > "$settings_tmp"
    mv -- "$settings_tmp" "$CONF_FILE"
)

complete_settings() {
    local setting key value
    for setting in \
        "POSTGRES_IMAGE=paradedb/paradedb:latest-pg17" \
        "REDIS_IMAGE=redis:7-alpine" \
        "DB_HOST=${INSTANCE_NAME}_postgres" \
        "DB_PORT=5432" \
        "DB_NAME=newapi" \
        "DB_USER=newapi" \
        "DB_SSLMODE=disable" \
        "REDIS_CONN_STRING=redis://${INSTANCE_NAME}_redis:6379/0"; do
        key="${setting%%=*}"
        value="${setting#*=}"
        if [ -z "${!key:-}" ]; then save_setting "$key" "$value"; fi
    done
    if [ -z "${NEWAPI_PORT:-}" ]; then save_setting NEWAPI_PORT "$(random_port)"; fi
    if [ -z "$DB_PASSWORD" ]; then save_setting DB_PASSWORD "$(random_secret)"; fi
    if [ -z "$CRYPTO_SECRET" ]; then save_setting CRYPTO_SECRET "$(random_secret)"; fi
}

generate_compose() {
    cat "$TPL_DIR/compose.yaml.tpl" > "$COMPOSE_FILE"
    if [ "$NEWAPI_PUBLISH_PORT" = true ]; then
        cat >> "$COMPOSE_FILE" <<'YAML'
    ports:
      - "${NEWAPI_PORT:?NEWAPI_PORT is required}:3000"
YAML
    fi
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
# 4. Lifecycle Functions
# -----------------------------------------------------------------------------
do_init() {
    if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
    load_settings
    complete_settings
    load_settings
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data"
    echo "[SUCCESS] New API, PostgreSQL and Redis settings, Compose YAML and data directories are ready."
    echo "Run 'bash cli.sh start --conf $CONF_FILE' to start this instance and its bundled dependencies."
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl for persistent changes)."
    echo "Existing nonempty settings and keys were preserved; init did not start containers."
}

do_start() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data"
    compose up -d
    echo "[SUCCESS] New API and its bundled PostgreSQL/Redis were started; check docker logs $INSTANCE_NAME for readiness."
    if [ "$NEWAPI_PUBLISH_PORT" = true ]; then
        echo "Web UI: http://<SERVER_IP>:${NEWAPI_PORT}"
    fi
}

do_update() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data"
    compose pull
    compose up -d
    echo "[SUCCESS] New API and bundled dependency images updated; settings and data were preserved."
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
    echo "[WARN] Permanently deleting this instance's application, PostgreSQL and Redis data."
    local data_name
    for data_name in "${INSTANCE_NAME}_data" "${INSTANCE_NAME}_postgres_data" "${INSTANCE_NAME}_redis_data"; do
        if [ -d "$CONF_DIR/data/$data_name" ]; then
            docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf "/purge/$data_name"
        fi
    done
    echo "[SUCCESS] This instance's application, PostgreSQL and Redis data removed; settings were preserved."
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    echo "[SUCCESS] This instance's stack, persistent data, settings and generated YAML were removed."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network [ls]} [--conf PATH] [--name NAME]"
    echo "  init    : Generate/complete settings, Compose YAML and data directories; do not start containers"
    echo "  start   : Start New API with its bundled PostgreSQL and Redis"
    echo "  up      : init + start for this whole instance"
    echo "  update  : Pull app and bundled dependency images, then apply them with Compose"
    echo "  stop    : Stop this instance's app, PostgreSQL and Redis"
    echo "  rm      : Remove this project's containers and private network; preserve settings and data"
    echo "  purge   : DANGER - rm and delete this instance's app, PostgreSQL and Redis data"
    echo "  reset   : DANGER - purge and delete this instance's settings and generated YAML"
    echo "  network : Display the configured network and attached containers"
    echo "  --conf  : Settings path; YAML and data stay beside this file"
    echo "  --name  : Instance name written when creating new settings"
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

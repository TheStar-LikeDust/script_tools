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
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_openwebui.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
IMAGE="ghcr.io/open-webui/open-webui:main"
DOCKER_NETWORK=""
OPENWEBUI_PUBLISH_PORT=true
DB_HOST=""
DB_PORT=5432
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_SSLMODE=disable
WEBUI_SECRET_KEY=""
REDIS_URL=""
STORAGE_PROVIDER=local
S3_ENDPOINT_URL=""
S3_ACCESS_KEY_ID=""
S3_SECRET_ACCESS_KEY=""
S3_BUCKET_NAME=""

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32; }
random_letters() { openssl rand -base64 48 | tr -dc 'a-z' | head -c 4; }
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
    export IMAGE DOCKER_NETWORK OPENWEBUI_PUBLISH_PORT
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
    export DATABASE_URL="sqlite:////app/backend/data/webui.db"
    if [ -n "${DB_HOST:-}" ]; then
        local db_host="$DB_HOST"
        if [[ "$db_host" == *:* && "$db_host" != \[*\] ]]; then db_host="[$db_host]"; fi
        DATABASE_URL="postgresql://$(urlencode "${DB_USER:-}"):$(urlencode "${DB_PASSWORD:-}")@$db_host:${DB_PORT:-5432}/$(urlencode "${DB_NAME:-}")?sslmode=$(urlencode "${DB_SSLMODE:-disable}")"
    fi
}

require_connections() {
    local field
    if [ -z "${WEBUI_SECRET_KEY:-}" ]; then
        echo "[ERROR] WEBUI_SECRET_KEY is required in $CONF_FILE; preserve the original key for existing data." >&2
        return 1
    fi
    if [ -n "${DB_HOST:-}" ]; then
        for field in DB_NAME DB_USER DB_PASSWORD; do
            if [ -z "${!field:-}" ]; then
                echo "[ERROR] Fill $field in $CONF_FILE for external PostgreSQL." >&2
                return 1
            fi
        done
    fi
    if [ "${STORAGE_PROVIDER:-local}" = s3 ]; then
        for field in S3_ENDPOINT_URL S3_BUCKET_NAME S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
            if [ -z "${!field:-}" ]; then
                echo "[ERROR] Fill $field in $CONF_FILE for S3 storage." >&2
                return 1
            fi
        done
    fi
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
    if [ "$labels" != "$INSTANCE_NAME/openwebui" ]; then
        echo "[ERROR] '$INSTANCE_NAME' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() (
    umask 077
    local port secret admin_name admin_pass
    port=$(random_port)
    secret=$(random_secret)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="openwebui_${ts: -4}"
    fi

    admin_name=$(random_letters)
    local admin_email="${admin_name}@example.com"
    admin_pass=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)

    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] Invalid instance name: $name" >&2
        return 1
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{OPENWEBUI_PORT}}/${port}/g" \
        -e "s/{{WEBUI_SECRET_KEY}}/${secret}/g" \
        -e "s/{{WEBUI_ADMIN_EMAIL}}/${admin_email}/g" \
        -e "s/{{WEBUI_ADMIN_PASSWORD}}/${admin_pass}/g" \
        -e "s/{{WEBUI_ADMIN_NAME}}/${admin_name}/g" \
        "$TPL_DIR/settings_openwebui.conf.tpl" > "$CONF_FILE"
)

generate_compose() {
    cat "$TPL_DIR/compose.yaml.tpl" > "$COMPOSE_FILE"
    if [ "$OPENWEBUI_PUBLISH_PORT" = true ]; then
        cat >> "$COMPOSE_FILE" <<'YAML'
    ports:
      - "${OPENWEBUI_PORT:?OPENWEBUI_PORT is required}:8080"
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
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    echo "[SUCCESS] Open WebUI settings and Compose YAML are ready."
    echo "Review $CONF_FILE, then run 'bash cli.sh start'."
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl for persistent changes)."
    echo "SQLite remains the default; fill DB_* only when using external PostgreSQL."
    echo "Keep WEBUI_SECRET_KEY and existing database files when migrating."
}

do_start() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    compose up -d
    echo "[SUCCESS] Open WebUI container started; check docker logs $INSTANCE_NAME for readiness."
    if [ "$OPENWEBUI_PUBLISH_PORT" = true ]; then
        echo "Web UI: http://<SERVER_IP>:${OPENWEBUI_PORT}"
    fi
}

do_update() {
    load_settings
    require_connections
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    compose pull
    compose up -d
    echo "[SUCCESS] Open WebUI image update completed; settings and data were preserved."
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
    echo "[WARN] Permanently deleting this application's local data."
    if [ -d "$CONF_DIR/data/${INSTANCE_NAME}_data" ]; then
        docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi
    echo "[SUCCESS] Local application data removed; settings and external services were preserved."
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    echo "[SUCCESS] This application's settings and generated YAML were removed."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network [ls]} [--conf PATH] [--name NAME]"
    echo "  init    : Generate missing settings, then Compose YAML and a local data directory"
    echo "  start   : Refresh YAML and run docker compose up -d for this application"
    echo "  up      : init + start; external connections must already be configured"
    echo "  update  : Pull the configured image and apply it with Compose"
    echo "  stop    : Stop only this application"
    echo "  rm      : Remove this project's containers and private network; preserve settings and data"
    echo "  purge   : DANGER - rm and delete only this application's local data"
    echo "  reset   : DANGER - purge and delete only this settings file and generated YAML"
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

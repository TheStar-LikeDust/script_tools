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
        --conf) [ $# -ge 2 ] || { echo "[ERROR] --conf requires a value." >&2; exit 2; }; CONF_FILE="$2"; shift 2 ;;
        --name) [ $# -ge 2 ] || { echo "[ERROR] --name requires a value." >&2; exit 2; }; NAME_OVERRIDE="$2"; shift 2 ;;
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
COMPOSE_BASENAME="$(basename "$CONF_FILE")"
COMPOSE_BASENAME="${COMPOSE_BASENAME#settings_}"
COMPOSE_FILE="$CONF_DIR/${COMPOSE_BASENAME%.conf}.compose.yaml"

source "$SCRIPT_DIR/hooks.sh"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32; }

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    # Do not inherit application or dependency values from the caller.
    INSTANCE_NAME=""
    IMAGE=""
    DOCKER_NETWORK=""
    NEWAPI_PORT=""
    NEWAPI_PUBLISH_PORT=""
    TZ=""
    ERROR_LOG_ENABLED=""
    CRYPTO_SECRET=""
    NEWAPI_ADMIN_USERNAME=""
    NEWAPI_ADMIN_PASSWORD=""
    PARADEDB_CONF=""
    REDIS_CONF=""
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
}

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
    local key value
    local -a missing_keys=()
    for key in IMAGE DOCKER_NETWORK NEWAPI_PORT NEWAPI_PUBLISH_PORT TZ ERROR_LOG_ENABLED CRYPTO_SECRET PARADEDB_CONF REDIS_CONF; do
        [ -z "${!key:-}" ] || continue
        case "$key" in
            IMAGE) value="calciumion/new-api:latest" ;;
            DOCKER_NETWORK) value="" ;;
            NEWAPI_PORT) value="$(random_port)" ;;
            NEWAPI_PUBLISH_PORT) value=true ;;
            TZ) value="Asia/Shanghai" ;;
            ERROR_LOG_ENABLED) value=true ;;
            CRYPTO_SECRET) value="$(random_secret)" ;;
            PARADEDB_CONF) value="settings_newapi_paradedb.conf" ;;
            REDIS_CONF) value="settings_newapi_redis.conf" ;;
        esac
        printf -v "$key" '%s' "$value"
        missing_keys+=("$key")
    done
    if [ -z "${NEWAPI_ADMIN_USERNAME:-}" ]; then
        NEWAPI_ADMIN_USERNAME="$(openssl rand -hex 4)"
        missing_keys+=(NEWAPI_ADMIN_USERNAME)
    fi
    if [ -z "${NEWAPI_ADMIN_PASSWORD:-}" ]; then
        NEWAPI_ADMIN_PASSWORD="$(openssl rand -base64 12)"
        missing_keys+=(NEWAPI_ADMIN_PASSWORD)
    fi
    require_connections
    for key in "${missing_keys[@]}"; do save_setting "$key" "${!key}"; done
}

require_connections() {
    local key
    for key in INSTANCE_NAME IMAGE NEWAPI_PORT NEWAPI_PUBLISH_PORT TZ ERROR_LOG_ENABLED CRYPTO_SECRET PARADEDB_CONF REDIS_CONF; do
        if [ -z "${!key:-}" ]; then
            echo "[ERROR] $key is missing in $CONF_FILE. Run init with the same --conf first." >&2
            return 1
        fi
    done
    if [[ ! "$NEWAPI_PORT" =~ ^[0-9]{1,5}$ ]] || ((10#$NEWAPI_PORT < 1 || 10#$NEWAPI_PORT > 65535)); then
        echo "[ERROR] NEWAPI_PORT must be a host port between 1 and 65535." >&2
        return 1
    fi
    if [ "$NEWAPI_PUBLISH_PORT" != true ] && [ "$NEWAPI_PUBLISH_PORT" != false ]; then
        echo "[ERROR] NEWAPI_PUBLISH_PORT must be true or false." >&2
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
    for service in newapi postgres redis; do
        case "$service" in
            newapi) container_name="$INSTANCE_NAME" ;;
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
    local port secret name
    port=$(random_port)
    secret=$(random_secret)
    name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local timestamp
        timestamp=$(date +%s)
        name="newapi_${timestamp: -4}"
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

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions
# -----------------------------------------------------------------------------
do_init() {
    if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
    load_settings
    complete_settings
    prepare_dependency_settings
    load_dependency_environment
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data"
    printf '\n[SUCCESS] New API and dependency settings are ready.\n\n'
    printf '  App:       %s\n  ParadeDB:  %s\n  Redis:     %s\n  Compose:   %s\n' \
        "$CONF_FILE" "$(resolve_dependency_conf paradedb)" "$(resolve_dependency_conf redis)" "$COMPOSE_FILE"
    printf '  Initial admin: NEWAPI_ADMIN_USERNAME / NEWAPI_ADMIN_PASSWORD in app settings.\n\n'
    printf 'Next: bash cli.sh start --conf %q\n\n' "$CONF_FILE"
}

do_start() {
    load_settings
    require_connections
    load_dependency_environment
    require_managed_container
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data"
    printf '\n[INFO] Starting New API with ParadeDB and Redis...\n\n'
    compose up -d
    initialize_admin
    printf '\n[SUCCESS] New API stack started.\n\n'
    if [ "$NEWAPI_PUBLISH_PORT" = true ]; then printf '  Web UI: http://<SERVER_IP>:%s\n' "$NEWAPI_PORT"; fi
    printf '  Settings: %s\n  Initial admin: NEWAPI_ADMIN_USERNAME / NEWAPI_ADMIN_PASSWORD in app settings.\n\n' "$CONF_FILE"
}

do_update() {
    load_settings
    require_connections
    load_dependency_environment
    require_managed_container
    render_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${PARADEDB_INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${REDIS_INSTANCE_NAME}_data"
    compose pull
    compose up -d
    echo "[SUCCESS] New API, ParadeDB and Redis images updated; settings and data were preserved."
}

do_stop() {
    load_settings
    require_connections
    load_dependency_environment
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || render_compose
    compose stop
}

do_rm() {
    load_settings
    require_connections
    load_dependency_environment
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || render_compose
    compose down
}

do_purge() {
    do_rm
    local data_name
    for data_name in "${INSTANCE_NAME}_data" "${PARADEDB_INSTANCE_NAME}_data" "${REDIS_INSTANCE_NAME}_data"; do
        if [ -d "$CONF_DIR/data/$data_name" ]; then
            docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf "/purge/$data_name"
        fi
    done
    echo "[SUCCESS] New API, ParadeDB and Redis data removed; settings were preserved."
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    local dependency_conf
    for dependency_conf in "$(resolve_dependency_conf paradedb)" "$(resolve_dependency_conf redis)"; do
        case "$dependency_conf" in
            "$CONF_DIR/settings_paradedb.conf"|"$CONF_DIR/settings_redis.conf"|\
            "$CONF_DIR/settings_newapi_paradedb.conf"|"$CONF_DIR/settings_newapi_redis.conf") rm -f -- "$dependency_conf" ;;
        esac
    done
    echo "[SUCCESS] New API stack, dependency data, default settings and generated YAML were removed."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network [ls]} [--conf PATH] [--name NAME]"
    echo "  init    : Generate app/dependency settings, Compose YAML and data directories"
    echo "  start   : Start New API with its ParadeDB and Redis Compose services"
    echo "  up      : init + start for this instance"
    echo "  update  : Pull and apply New API, ParadeDB and Redis images"
    echo "  stop    : Stop this Compose project"
    echo "  rm      : Remove containers and private network; preserve settings and data"
    echo "  purge   : DANGER - remove this instance's app and dependency data"
    echo "  reset   : DANGER - purge and remove app/default dependency settings"
    echo "  network : Display the configured network and attached containers"
    echo "  --conf  : App settings path; dependency settings and data stay beside it by default"
    echo "  --name  : Instance name written when creating app settings"
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

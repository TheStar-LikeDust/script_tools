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
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_casdoor.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
IMAGE="casbin/casdoor:latest"
DOCKER_NETWORK=""
POSTGRES_IMAGE=""
CASDOOR_PORT=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_SSLMODE=""
APP_CONF_HASH=""
source "$SCRIPT_DIR/hooks.sh"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_password() { openssl rand -hex 16; }

save_setting() (
    umask 077
    local key="$1" value="$2" setting temp_file
    printf -v setting '%s=%q' "$key" "$value"
    temp_file=$(mktemp "${CONF_FILE}.tmp.XXXXXX")
    trap 'rm -f -- "$temp_file"' EXIT
    SETTING_LINE="$setting" awk -v key="$key" '
        { sub(/\r$/, "") }
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=" {
            if (!written) print ENVIRON["SETTING_LINE"]
            written = 1
            next
        }
        { print }
        END { if (!written) print ENVIRON["SETTING_LINE"] }
    ' "$CONF_FILE" > "$temp_file"
    mv -- "$temp_file" "$CONF_FILE"
)

complete_settings() {
    local key value
    for key in POSTGRES_IMAGE CASDOOR_PORT DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE; do
        [ -n "${!key:-}" ] && continue
        case "$key" in
            POSTGRES_IMAGE) value="paradedb/paradedb:latest-pg17" ;;
            CASDOOR_PORT) value=$(random_port) ;;
            DB_HOST) value="${INSTANCE_NAME}_postgres" ;;
            DB_PORT) value="5432" ;;
            DB_NAME|DB_USER) value="casdoor" ;;
            DB_PASSWORD) value=$(random_password) ;;
            DB_SSLMODE) value="disable" ;;
        esac
        save_setting "$key" "$value"
        printf -v "$key" '%s' "$value"
        export "$key"
    done
}

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Casdoor] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    export IMAGE DOCKER_NETWORK POSTGRES_IMAGE APP_CONF_HASH
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
}

validate_settings() {
    local key
    for key in POSTGRES_IMAGE CASDOOR_PORT DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE; do
        if [ -z "${!key:-}" ]; then
            echo "[ERROR] Missing $key in $CONF_FILE. Run 'bash cli.sh init --conf $CONF_FILE' to complete bundled settings." >&2
            return 1
        fi
        if [[ "${!key}" == *$'\n'* || "${!key}" == *$'\r'* ]]; then
            echo "[ERROR] $key must be a single-line value for Casdoor app.conf." >&2
            return 1
        fi
    done
    if [[ ! "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo "[ERROR] DB_NAME must contain letters, digits and underscores, beginning with a letter or underscore." >&2
        return 1
    fi
}

compose() {
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local service container_name container labels
    for service in casdoor postgres; do
        container_name="$INSTANCE_NAME"
        if [ "$service" = postgres ]; then container_name="${INSTANCE_NAME}_postgres"; fi
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
    local name="$NAME_OVERRIDE" port ts db_password
    port=$(random_port)
    db_password=$(random_password)
    if [ -z "$name" ]; then
        ts=$(date +%s)
        name="casdoor_${ts: -4}"
    fi
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] Invalid instance name: $name" >&2
        return 1
    fi
    sed -e "s/{{INSTANCE_NAME}}/$name/g" \
        -e "s/{{CASDOOR_PORT}}/$port/g" \
        -e "s/{{DB_PASSWORD}}/$db_password/g" \
        "$TPL_DIR/settings_casdoor.conf.tpl" > "$CONF_FILE"
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
    [ -f "$CONF_FILE" ] || generate_settings
    load_settings
    complete_settings
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data"
    hr
    echo "[SUCCESS] [Casdoor] Bundled settings and Compose YAML are ready; existing values were preserved."
    echo "Run 'bash cli.sh start --conf $CONF_FILE' to start Casdoor and its PostgreSQL together."
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl for persistent changes)."
    hr
}

do_start() {
    load_settings
    validate_settings
    require_managed_container
    render_app_conf
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data"
    compose up -d
    echo "[INFO] [Casdoor] Bundled stack started: http://<SERVER_IP>:$CASDOOR_PORT; inspect logs for readiness."
}

do_update() {
    load_settings
    validate_settings
    require_managed_container
    render_app_conf
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data"
    compose pull
    compose up -d
    echo "[SUCCESS] [Casdoor] App and PostgreSQL images updated; settings and persistent data were preserved."
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
    if [ -d "$CONF_DIR/data/${INSTANCE_NAME}_data" ] || [ -d "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" ]; then
        docker run --rm -v "$CONF_DIR/data:/purge" alpine rm -rf \
            "/purge/${INSTANCE_NAME}_data" "/purge/${INSTANCE_NAME}_postgres_data"
    fi
    echo "[SUCCESS] [Casdoor] App and PostgreSQL data purged; app.conf and settings were preserved."
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    rm -rf -- "$CONF_DIR/data/${INSTANCE_NAME}_config"
    echo "[SUCCESS] [Casdoor] This instance's stack, persistent data and generated configuration were removed."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network} [--conf PATH] [--name NAME]"
    echo "  init       : Generate or complete bundled settings, YAML and data dirs; do not start containers"
    echo "  start      : Render app.conf and YAML, then start Casdoor and PostgreSQL"
    echo "  up         : init + start for the bundled stack"
    echo "  update     : Pull configured app and PostgreSQL images and apply them"
    echo "  stop       : Stop this instance's Casdoor and PostgreSQL"
    echo "  rm         : Remove only this Compose project; preserve settings and bind mounts"
    echo "  purge      : DANGER - rm and delete this instance's app and PostgreSQL data"
    echo "  reset      : DANGER - purge and delete this instance's settings, YAML and generated config dir"
    echo "  network ls : Inspect the configured network without modifying it"
    echo "  --conf PATH: Settings path; YAML and data live relative to its directory"
    echo "  --name NAME: Instance name written only when generating new settings"
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

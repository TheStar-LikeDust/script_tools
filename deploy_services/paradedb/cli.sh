#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Parse instance paths, initialization values and read-only output options.
CONF_FILE=""
CONFIG_ONLY=false
SERVICE_NAME=paradedb
declare -A INIT_VALUES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --config-only)
            if [ "$COMMAND" != init ]; then
                echo "[ERROR] --config-only is only supported by init." >&2
                exit 2
            fi
            CONFIG_ONLY=true
            shift
            ;;
        --conf|--name|--image|--port|--publish-port|--network|--db-name|--db-user|--db-password|--service-name)
            if [ $# -lt 2 ]; then
                echo "[ERROR] $1 requires a value." >&2
                exit 2
            fi
            option="$1"
            value="$2"
            shift 2
            case "$option" in
                --conf) CONF_FILE="$value"; continue ;;
                --service-name)
                    if [ "$COMMAND" != render ]; then
                        echo "[ERROR] --service-name is only supported by render." >&2
                        exit 2
                    fi
                    SERVICE_NAME="$value"
                    continue
                    ;;
            esac
            if [ "$COMMAND" != init ] && [ "$COMMAND" != up ]; then
                echo "[ERROR] $option is only supported by init/up." >&2
                exit 2
            fi
            case "$option" in
                --name) INIT_VALUES[INSTANCE_NAME]="$value" ;;
                --image) INIT_VALUES[IMAGE]="$value" ;;
                --port) INIT_VALUES[DB_PORT]="$value" ;;
                --publish-port) INIT_VALUES[DB_PUBLISH_PORT]="$value" ;;
                --network) INIT_VALUES[DOCKER_NETWORK]="$value" ;;
                --db-name) INIT_VALUES[DB_NAME]="$value" ;;
                --db-user) INIT_VALUES[DB_USER]="$value" ;;
                --db-password) INIT_VALUES[DB_PASSWORD]="$value" ;;
            esac
            ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Anchor paths to this script's own location so it works from any cwd and survives moves
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_paradedb.conf}"
# Config + data live together; data dir is derived from the config file's directory at runtime
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
source "$SCRIPT_DIR/hooks.sh"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_password() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32; }

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [ParadeDB] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    # Do not inherit application values when called as a dependency.
    INSTANCE_NAME="" IMAGE="" DOCKER_NETWORK="" DB_PORT=""
    DB_PUBLISH_PORT="" DB_USER="" DB_PASSWORD="" DB_NAME=""
    # Read CRLF files without rewriting existing credentials.
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
}

require_settings() {
    local key
    for key in INSTANCE_NAME IMAGE DB_PORT DB_PUBLISH_PORT DB_USER DB_PASSWORD DB_NAME; do
        if [ -z "${!key}" ]; then
            echo "[ERROR] $key is missing in $CONF_FILE. Run init with the same --conf." >&2
            return 1
        fi
    done
    if [[ ! "$INSTANCE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
    if [[ ! "$DB_PORT" =~ ^[0-9]{1,5}$ ]] || ((10#$DB_PORT < 1 || 10#$DB_PORT > 65535)); then
        echo "[ERROR] DB_PORT must be a host port between 1 and 65535." >&2
        return 1
    fi
    if [ "$DB_PUBLISH_PORT" != true ] && [ "$DB_PUBLISH_PORT" != false ]; then
        echo "[ERROR] DB_PUBLISH_PORT must be true or false." >&2
        return 1
    fi
}

compose() {
    export_compose_env >/dev/null
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local container labels
    container="$(docker container ls -a --filter "name=^/${INSTANCE_NAME}$" --format '{{.Names}}')"
    [ -n "$container" ] || return 0
    labels="$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$INSTANCE_NAME")"
    if [ "$labels" != "$INSTANCE_NAME/paradedb" ]; then
        echo "[ERROR] '$INSTANCE_NAME' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() (
    umask 077
    cat "$TPL_DIR/settings_paradedb.conf.tpl" > "$CONF_FILE"
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
    local key value ts
    local -a missing_keys=()
    for key in INSTANCE_NAME IMAGE DOCKER_NETWORK DB_PORT DB_PUBLISH_PORT DB_USER DB_PASSWORD DB_NAME; do
        [ -z "${!key}" ] || continue
        value="${INIT_VALUES[$key]:-}"
        if [ -z "$value" ]; then
            case "$key" in
                INSTANCE_NAME) ts="$(date +%s)"; value="paradedb_${ts: -4}" ;;
                IMAGE) value="paradedb/paradedb:latest-pg17" ;;
                DOCKER_NETWORK) value="" ;;
                DB_PORT) value="$(random_port)" ;;
                DB_PUBLISH_PORT) value=true ;;
                DB_USER|DB_NAME) value=postgres ;;
                DB_PASSWORD) value="$(random_password)" ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
        missing_keys+=("$key")
    done
    require_settings
    for key in "${missing_keys[@]}"; do
        save_setting "$key" "${!key}"
    done
}

generate_compose() {
    {
        printf '# Generated by cli.sh. Edit templates/compose.yaml.tpl for persistent changes.\nservices:\n'
        render_service paradedb
        if [ -n "$DOCKER_NETWORK" ]; then
            cat <<'YAML'
networks:
  default:
    external: true
    name: "${PARADEDB_DOCKER_NETWORK}"
YAML
        fi
    } > "$COMPOSE_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [ParadeDB] Initializing configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
    load_settings
    complete_settings
    if [ "$CONFIG_ONLY" = true ]; then
        printf '\n[SUCCESS] [ParadeDB] Settings ready: %s\n' "$CONF_FILE"
        return 0
    fi
    generate_compose

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [ParadeDB] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review $CONF_FILE (port / credentials / network)"
    echo "  2. Run 'bash cli.sh start' to refresh YAML and start with Docker Compose"
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl instead)"
    hr
}

do_start() {
    load_settings
    require_settings
    require_managed_container
    generate_compose
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [ParadeDB] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    compose up -d
    hr
    echo "[SUCCESS] [ParadeDB] Container started; check Docker health status for readiness."
    if [ "${DB_PUBLISH_PORT:-true}" = "true" ]; then
        echo "Local: psql -h localhost -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME}"
    else
        echo "PostgreSQL is available only through Docker networks (no host port)."
    fi
    echo "Docker network address: ${INSTANCE_NAME}:5432 (same network only)"
    hr
}

do_update() {
    load_settings
    require_settings
    require_managed_container
    generate_compose
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [ParadeDB] Pulling image and recreating the service if needed..."
    hr
    compose pull
    compose up -d
    hr
    echo "[SUCCESS] [ParadeDB] Image update completed; settings and data were preserved."
    hr
}

do_stop() {
    load_settings
    require_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [ParadeDB] Stopping service..."
    hr
    compose stop
}

do_rm() {
    load_settings
    require_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [ParadeDB] Removing container..."
    hr
    compose down
}

do_purge() {
    do_rm
    hr
    echo "[WARN] WARNING: Preparing to completely destroy ParadeDB data!"
    hr

    # Clean up local data directory but preserve configs
    local data_dir="${CONF_DIR}/data/${INSTANCE_NAME}_data"
    if [ -d "$data_dir" ]; then
        echo "Removing local data directory..."
        # Data is bind-mounted and often written as root inside the container;
        # delete via a throwaway root container to avoid host permission errors.
        docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi

    hr
    echo "[SUCCESS] [ParadeDB] Data has been purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] [ParadeDB] Removing this instance's settings and generated YAML..."
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    hr
    echo "[SUCCESS] [ParadeDB] Reset complete (restored to pristine source files)."
    hr
}

do_render() {
    load_settings
    require_settings
    render_service "$SERVICE_NAME"
}

do_env() {
    load_settings
    require_settings
    export_compose_env
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|render|env|help} [OPTIONS]"
    echo "  init    : Generate/complete settings, then Compose YAML and data dir; do not start"
    echo "  start   : Refresh Compose YAML and run docker compose up -d"
    echo "  update  : Pull the configured image and recreate the service if needed"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings_paradedb.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings_paradedb.conf)"
    echo "  reset   : DANGER - purge AND delete only this config and its generated YAML"
    echo "  render  : Print a reusable service YAML fragment; no files or containers changed"
    echo "  env     : Print Bash exports for PARADEDB_* variables, including PARADEDB_DSN"
    echo ""
    echo "Options:"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings_paradedb.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/<INSTANCE_NAME>_data."
    echo "Initialization options (init/up; existing nonempty settings always win):"
    echo "  --name NAME         : Container/data instance name (default: paradedb_<ts>)"
    echo "  --image IMAGE       : Database image (default: paradedb/paradedb:latest-pg17)"
    echo "  --port PORT         : Host port (default: random 30000-40000; container uses 5432)"
    echo "  --publish-port BOOL : Publish the host port (true/false; default: true)"
    echo "  --network NAME      : Existing shared network (default: private Compose network)"
    echo "  --db-name NAME      : Initial database (default: postgres)"
    echo "  --db-user USER      : Initial database administrator (default: postgres)"
    echo "  --db-password PASS  : Initial password (default: generated once)"
    echo "  --config-only       : init only; prepare settings without YAML or data directories"
    echo "Render options:"
    echo "  --service-name NAME : YAML service key (default: paradedb); container name is unchanged"
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
    render)  do_render ;;
    env)     do_env ;;
    help)    do_help ;;
    *)       do_help; exit 2 ;;
esac

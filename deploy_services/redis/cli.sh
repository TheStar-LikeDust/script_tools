#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

CONF_FILE=""
declare -A INIT_VALUES=()
CONFIG_ONLY=false
SERVICE_NAME=redis
CONNECTION_DB=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config-only)
            [ "$COMMAND" = init ] || { echo "[ERROR] --config-only requires init." >&2; exit 2; }
            CONFIG_ONLY=true
            shift
            ;;
        --conf|--name|--image|--port|--publish-port|--network|--service-name|--db)
            [ $# -ge 2 ] || { echo "[ERROR] $1 requires a value." >&2; exit 2; }
            case "$1" in
                --conf) CONF_FILE="$2" ;;
                --service-name)
                    [ "$COMMAND" = render ] || { echo "[ERROR] --service-name requires render." >&2; exit 2; }
                    SERVICE_NAME="$2"
                    ;;
                --db)
                    [ "$COMMAND" = env ] || { echo "[ERROR] --db requires env." >&2; exit 2; }
                    CONNECTION_DB="$2"
                    ;;
                *)
                    case "$COMMAND" in
                        init|up) ;;
                        *) echo "[ERROR] $1 requires init or up." >&2; exit 2 ;;
                    esac
                    case "$1" in
                        --name) INIT_VALUES[INSTANCE_NAME]="$2" ;;
                        --image) INIT_VALUES[IMAGE]="$2" ;;
                        --port) INIT_VALUES[REDIS_PORT]="$2" ;;
                        --publish-port) INIT_VALUES[REDIS_PUBLISH_PORT]="$2" ;;
                        --network) INIT_VALUES[DOCKER_NETWORK]="$2" ;;
                    esac
                    ;;
            esac
            shift 2
            ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_redis.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
source "$SCRIPT_DIR/hooks.sh"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Redis] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        exit 1
    fi
    # Never use settings inherited from an application's exported environment.
    INSTANCE_NAME=""
    IMAGE=""
    DOCKER_NETWORK=""
    REDIS_PORT=""
    REDIS_PUBLISH_PORT=""
    # Read CRLF files without rewriting existing settings.
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
}

require_settings() {
    IMAGE="${IMAGE:-redis:7-alpine}"
    REDIS_PUBLISH_PORT="${REDIS_PUBLISH_PORT:-true}"
    if [[ ! "$INSTANCE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
    if [ "$REDIS_PUBLISH_PORT" != true ] && [ "$REDIS_PUBLISH_PORT" != false ]; then
        echo "[ERROR] REDIS_PUBLISH_PORT must be true or false." >&2
        return 1
    fi
    if [ -n "$REDIS_PORT" ] || [ "$REDIS_PUBLISH_PORT" = true ]; then
        if [[ ! "$REDIS_PORT" =~ ^[0-9]{1,5}$ ]] || ((10#$REDIS_PORT < 1 || 10#$REDIS_PORT > 65535)); then
            echo "[ERROR] REDIS_PORT must be an integer between 1 and 65535." >&2
            return 1
        fi
    fi
    if [ -n "$DOCKER_NETWORK" ] && [[ ! "$DOCKER_NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[ERROR] DOCKER_NETWORK contains unsupported characters." >&2
        return 1
    fi
}

compose() {
    export_compose_env
    docker compose --env-file /dev/null --project-directory "$CONF_DIR" \
        --project-name "$INSTANCE_NAME" -f "$COMPOSE_FILE" "$@"
}

require_managed_container() {
    local container labels
    container="$(docker container ls -a --filter "name=^/${INSTANCE_NAME}$" --format '{{.Names}}')"
    [ -n "$container" ] || return 0
    labels="$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$INSTANCE_NAME")"
    if [ "$labels" != "$INSTANCE_NAME/redis" ]; then
        echo "[ERROR] '$INSTANCE_NAME' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() (
    umask 077
    cat "$TPL_DIR/settings_redis.conf.tpl" > "$CONF_FILE"
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
    local key value timestamp
    local -a missing_keys=()
    for key in INSTANCE_NAME IMAGE DOCKER_NETWORK REDIS_PORT REDIS_PUBLISH_PORT; do
        [ -z "${!key:-}" ] || continue
        value="${INIT_VALUES[$key]-}"
        if [ -z "$value" ]; then
            case "$key" in
                INSTANCE_NAME) timestamp="$(date +%s)"; value="redis_${timestamp: -4}" ;;
                IMAGE) value=redis:7-alpine ;;
                REDIS_PORT) value="$(random_port)" ;;
                REDIS_PUBLISH_PORT) value=true ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
        missing_keys+=("$key")
    done
    require_settings
    for key in "${missing_keys[@]}"; do save_setting "$key" "${!key}"; done
}

generate_compose() {
    {
        printf '# Generated by cli.sh. Edit templates/compose.yaml.tpl for persistent changes.\nservices:\n'
        render_service
        if [ -n "$DOCKER_NETWORK" ]; then
            cat <<'YAML'
networks:
  default:
    external: true
    name: "${REDIS_DOCKER_NETWORK}"
YAML
        fi
    } > "$COMPOSE_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [Redis] Initializing configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then generate_settings; fi
    load_settings
    complete_settings
    if [ "$CONFIG_ONLY" = true ]; then
        printf '\n[SUCCESS] [Redis] Settings ready: %s\n' "$CONF_FILE"
        printf 'Existing nonempty values were preserved; no YAML or data directory was generated.\n\n'
        return 0
    fi
    generate_compose

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [Redis] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review $CONF_FILE (port / instance name / network)"
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
    echo "[INFO] [Redis] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    compose up -d
    hr
    echo "[SUCCESS] [Redis] Container started; check Docker health status for readiness."
    if [ "$REDIS_PUBLISH_PORT" = true ]; then
        echo "Connection: redis://<SERVER_IP>:${REDIS_PORT}"
        echo "Local: redis-cli -p ${REDIS_PORT}"
    fi
    echo "Docker network address: ${INSTANCE_NAME}:6379 (same network only)"
    hr
}

do_update() {
    load_settings
    require_settings
    require_managed_container
    generate_compose
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[INFO] [Redis] Pulling image and recreating the service if needed..."
    hr
    compose pull
    compose up -d
    hr
    echo "[SUCCESS] [Redis] Image update completed; settings and data were preserved."
    hr
}

do_stop() {
    load_settings
    require_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [Redis] Stopping service..."
    hr
    compose stop
}

do_rm() {
    load_settings
    require_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [Redis] Removing container..."
    hr
    compose down
}

do_purge() {
    do_rm
    hr
    echo "[WARN] WARNING: Preparing to completely destroy Redis data!"
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
    echo "[SUCCESS] [Redis] Data has been purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] [Redis] Removing this instance's settings and generated YAML..."
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    hr
    echo "[SUCCESS] [Redis] Reset complete (restored to pristine source files)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|render|env} [--conf PATH] [options]"
    echo "  init    : Generate/complete settings, then Compose YAML and data dir; do not start"
    echo "  start   : Refresh Compose YAML and run docker compose up -d"
    echo "  update  : Pull the configured image and recreate the service if needed"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings_redis.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings_redis.conf)"
    echo "  reset   : DANGER - purge AND delete only this config and its generated YAML"
    echo "  render  : Print this service's YAML block without a services header or networks"
    echo "  env     : Print scoped Bash exports and REDIS_URL for a composing application"
    echo ""
    echo "Options:"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings_redis.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/<INSTANCE_NAME>_data."
    echo "Init/up defaults (existing nonempty settings always win):"
    echo "  --name NAME          : Instance name (default: auto 'redis_<ts>')."
    echo "  --image IMAGE        : Container image (default: redis:7-alpine)."
    echo "  --port PORT          : Host port (default: random 30000-40000; container port stays 6379)."
    echo "  --publish-port BOOL  : Publish the host port (default: true)."
    echo "  --network NAME       : Existing external network (default: private Compose network)."
    echo "  --config-only        : init only; generate/complete settings without YAML or data directories."
    echo "Render options: --service-name NAME (default: redis)."
    echo "Env options: --db NUMBER (default: 0; selects the URL database, not an ACL)."
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
    render)  load_settings; require_settings; render_service "$SERVICE_NAME" ;;
    env)     load_settings; require_settings; export_compose_env true ;;
    help)    do_help ;;
    *)       do_help; exit 2 ;;
esac

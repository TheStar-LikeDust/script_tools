#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

CONF_FILE=""
INTERNAL_ONLY=false
CONFIG_ONLY=false
SERVICE_NAME=rustfs
RESOURCE_OWNER=""
RESOURCE_BUCKET=""
RESOURCE_ACCESS_KEY=""
RESOURCE_SECRET_KEY=""
RESOURCE_ENDPOINT=""
DATA_DIR=""
declare -A INIT_VALUES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --conf|--name|--image|--init-image|--port|--admin-port|--publish-ports|--network|--service-name|--owner|--bucket|--access-key|--secret-key|--endpoint|--data-dir)
            [ $# -ge 2 ] || { echo "[ERROR] $1 requires a value." >&2; exit 2; }
            case "$1" in
                --conf) CONF_FILE="$2" ;;
                --service-name)
                    [ "$COMMAND" = render ] || { echo "[ERROR] --service-name requires render." >&2; exit 2; }
                    SERVICE_NAME="$2"
                    ;;
                --data-dir)
                    [ "$COMMAND" = prepare-data ] || { echo "[ERROR] --data-dir requires prepare-data." >&2; exit 2; }
                    DATA_DIR="$2"
                    ;;
                --owner) RESOURCE_OWNER="$2" ;;
                --bucket) RESOURCE_BUCKET="$2" ;;
                --access-key)
                    case "$COMMAND" in
                        init|up) INIT_VALUES[RUSTFS_ACCESS_KEY]="$2" ;;
                        *) RESOURCE_ACCESS_KEY="$2" ;;
                    esac
                    ;;
                --secret-key)
                    case "$COMMAND" in
                        init|up) INIT_VALUES[RUSTFS_SECRET_KEY]="$2" ;;
                        *) RESOURCE_SECRET_KEY="$2" ;;
                    esac
                    ;;
                --endpoint) RESOURCE_ENDPOINT="$2" ;;
                *)
                    case "$COMMAND" in
                        init|up) ;;
                        *) echo "[ERROR] $1 requires init or up." >&2; exit 2 ;;
                    esac
                    case "$1" in
                        --name) INIT_VALUES[INSTANCE_NAME]="$2" ;;
                        --image) INIT_VALUES[IMAGE]="$2" ;;
                        --init-image) INIT_VALUES[RUSTFS_INIT_IMAGE]="$2" ;;
                        --port) INIT_VALUES[RUSTFS_PORT]="$2" ;;
                        --admin-port) INIT_VALUES[RUSTFS_ADMIN_PORT]="$2" ;;
                        --publish-ports) INIT_VALUES[RUSTFS_PUBLISH_PORTS]="$2" ;;
                        --network) INIT_VALUES[DOCKER_NETWORK]="$2" ;;
                    esac
                    ;;
            esac
            shift 2
            ;;
        --config-only)
            [ "$COMMAND" = init ] || { echo "[ERROR] --config-only requires init." >&2; exit 2; }
            CONFIG_ONLY=true
            shift
            ;;
        --internal)
            INTERNAL_ONLY=true
            shift
            ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_rustfs.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
COMPOSE_FILE="${CONF_FILE%.conf}.compose.yaml"
IMAGE="rustfs/rustfs:latest"
DOCKER_NETWORK=""
RUSTFS_PUBLISH_PORTS=true
RUSTFS_PORT=""
RUSTFS_ADMIN_PORT=""
RUSTFS_ACCESS_KEY=""
RUSTFS_SECRET_KEY=""
RUSTFS_INIT_IMAGE="rustfs/rc:latest"
source "$SCRIPT_DIR/hooks.sh"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -hex 16; }

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
    for key in INSTANCE_NAME IMAGE RUSTFS_INIT_IMAGE DOCKER_NETWORK RUSTFS_PORT RUSTFS_ADMIN_PORT RUSTFS_PUBLISH_PORTS RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY; do
        [ -n "${!key:-}" ] || {
            value="${INIT_VALUES[$key]-}"
            if [ -z "$value" ]; then
                case "$key" in
                    INSTANCE_NAME) timestamp="$(date +%s)"; value="rustfs_${timestamp: -4}" ;;
                    IMAGE) value="rustfs/rustfs:latest" ;;
                    RUSTFS_INIT_IMAGE) value="rustfs/rc:latest" ;;
                    DOCKER_NETWORK) value="" ;;
                    RUSTFS_PORT) value="$(random_port)" ;;
                    RUSTFS_ADMIN_PORT)
                        value="$(random_port)"
                        while [ "$value" = "$RUSTFS_PORT" ]; do value="$(random_port)"; done
                        ;;
                    RUSTFS_PUBLISH_PORTS) value=true ;;
                    RUSTFS_ACCESS_KEY) value="$(openssl rand -hex 10)" ;;
                    RUSTFS_SECRET_KEY) value="$(random_secret)" ;;
                esac
            fi
            printf -v "$key" '%s' "$value"
            missing_keys+=("$key")
        }
    done
    require_settings
    for key in "${missing_keys[@]}"; do save_setting "$key" "${!key}"; done
}

require_settings() {
    local key
    for key in INSTANCE_NAME IMAGE RUSTFS_INIT_IMAGE RUSTFS_PORT RUSTFS_ADMIN_PORT RUSTFS_PUBLISH_PORTS RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY; do
        if [ -z "${!key:-}" ]; then
            echo "[ERROR] Missing $key in $CONF_FILE." >&2
            return 1
        fi
    done
    if [[ ! "$INSTANCE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
    if [ "$RUSTFS_PUBLISH_PORTS" != true ] && [ "$RUSTFS_PUBLISH_PORTS" != false ]; then
        echo "[ERROR] RUSTFS_PUBLISH_PORTS must be true or false." >&2
        return 1
    fi
    for key in RUSTFS_PORT RUSTFS_ADMIN_PORT; do
        if [[ ! "${!key}" =~ ^[0-9]{1,5}$ ]] || ((10#${!key} < 1 || 10#${!key} > 65535)); then
            echo "[ERROR] $key must be an integer between 1 and 65535." >&2
            return 1
        fi
    done
    for key in RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY; do
        if [[ "${!key}" == *$'\n'* || "${!key}" == *$'\r'* ]]; then
            echo "[ERROR] $key must be a single-line value." >&2
            return 1
        fi
    done
    if [ "$RUSTFS_PORT" = "$RUSTFS_ADMIN_PORT" ]; then
        echo "[ERROR] RUSTFS_PORT and RUSTFS_ADMIN_PORT must be different." >&2
        return 1
    fi
    if [ -n "$DOCKER_NETWORK" ] && [[ ! "$DOCKER_NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[ERROR] DOCKER_NETWORK contains unsupported characters." >&2
        return 1
    fi
}

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [RustFS] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        exit 1
    fi
    INSTANCE_NAME=""
    IMAGE=""
    DOCKER_NETWORK=""
    RUSTFS_PORT=""
    RUSTFS_ADMIN_PORT=""
    RUSTFS_PUBLISH_PORTS=""
    RUSTFS_ACCESS_KEY=""
    RUSTFS_SECRET_KEY=""
    RUSTFS_INIT_IMAGE=""
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    if [ "$INTERNAL_ONLY" = true ]; then
        RUSTFS_PUBLISH_PORTS=false
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
    if [ "$labels" != "$INSTANCE_NAME/rustfs" ]; then
        echo "[ERROR] '$INSTANCE_NAME' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() (
    umask 077
    local name="${INIT_VALUES[INSTANCE_NAME]-}"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="rustfs_${ts: -4}"
    fi
    [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "[ERROR] Invalid instance name: $name" >&2; return 1; }

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        "$TPL_DIR/settings_rustfs.conf.tpl" > "$CONF_FILE"
)

generate_compose() {
    require_settings
    export_compose_env
    {
        printf '# Generated by cli.sh. Edit templates/compose.yaml.tpl for persistent changes.\nservices:\n'
        render_service
        if [ -n "$DOCKER_NETWORK" ]; then
            cat <<'YAML'
networks:
  default:
    external: true
    name: "${RUSTFS_DOCKER_NETWORK}"
YAML
        fi
    } > "$COMPOSE_FILE"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [RustFS] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    load_settings
    complete_settings
    if [ "$CONFIG_ONLY" = true ]; then
        printf '\n[SUCCESS] [RustFS] Settings ready: %s\n' "$CONF_FILE"
        printf 'Existing nonempty values were preserved; no YAML or data directory was generated.\n\n'
        return 0
    fi
    generate_compose

    # Pre-create the bind-mount data dir so Docker won't auto-create it as root
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [RustFS] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review $CONF_FILE (ports / access key / secret key / network)"
    echo "  2. Run 'bash cli.sh start' to refresh YAML and start with Docker Compose"
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl instead)"
    hr
}

do_start() {
    load_settings
    require_settings
    require_managed_container
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"
    ensure_data_owner "${CONF_DIR}/data/${INSTANCE_NAME}_data"
    generate_compose

    hr
    echo "[INFO] [RustFS] Starting service (Container: ${INSTANCE_NAME})..."
    hr
    compose up -d
    hr
    echo "[SUCCESS] [RustFS] Container started; check Docker health status for readiness."
    if [ "$RUSTFS_PUBLISH_PORTS" = false ]; then
        echo "S3 API and console are not published to host ports."
    else
        echo "S3 API:  http://<SERVER_IP>:${RUSTFS_PORT}"
        echo "Console: http://<SERVER_IP>:${RUSTFS_ADMIN_PORT} (local: http://localhost:${RUSTFS_ADMIN_PORT})"
    fi
    echo "Docker network endpoints: http://${INSTANCE_NAME}:9000 (S3), http://${INSTANCE_NAME}:9001 (console)"
    echo "Credentials are stored in $CONF_FILE."
    hr
}

do_update() {
    load_settings
    require_settings
    require_managed_container
    mkdir -p "${CONF_DIR}/data/${INSTANCE_NAME}_data"
    generate_compose

    hr
    echo "[INFO] [RustFS] Pulling image and recreating the service if needed..."
    hr
    compose pull
    # Resolve ownership from the newly pulled image before replacing the service.
    ensure_data_owner "${CONF_DIR}/data/${INSTANCE_NAME}_data"
    compose up -d
    hr
    echo "[SUCCESS] [RustFS] Image update completed; settings and data were preserved."
    hr
}

do_stop() {
    load_settings
    require_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [RustFS] Stopping service..."
    hr
    compose stop
}

do_rm() {
    load_settings
    require_settings
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [RustFS] Removing container..."
    hr
    compose down
}

do_purge() {
    do_rm
    hr
    echo "[WARN] WARNING: Preparing to completely destroy RustFS data!"
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
    echo "[SUCCESS] [RustFS] Data has been purged (configs preserved)."
    hr
}

do_reset() {
    do_purge
    echo "[INFO] [RustFS] Removing this instance's settings and generated YAML..."
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    hr
    echo "[SUCCESS] [RustFS] Reset complete (restored to pristine source files)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|render|env|prepare-data|resource-init} [OPTIONS]"
    echo "  init    : Generate or complete settings, Compose YAML and data dir; do not start"
    echo "  start   : Refresh Compose YAML and run docker compose up -d"
    echo "  update  : Pull the configured image and recreate the service if needed"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings_rustfs.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings_rustfs.conf)"
    echo "  reset   : DANGER - purge AND delete only this config and its generated YAML"
    echo "  render  : Print a reusable RustFS service fragment"
    echo "  env     : Print Bash exports for RUSTFS_* values, including root credentials"
    echo "  prepare-data  : Prepare the configured RustFS data directory and its owner"
    echo "  resource-init : Create an app bucket, dedicated user and bucket-scoped policy"
    echo ""
    echo "Options:"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings_rustfs.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/<INSTANCE_NAME>_data."
    echo "  init options: --name NAME --image IMAGE --init-image IMAGE --port PORT --admin-port PORT"
    echo "               --publish-ports true|false --network NAME --config-only"
    echo "               --access-key KEY --secret-key SECRET"
    echo "  render option: --service-name NAME (default: rustfs)"
    echo "  prepare-data option: --data-dir PATH (default: settings directory/data/<INSTANCE_NAME>_data)"
    echo "  resource-init options: --owner NAME --bucket NAME --access-key KEY"
    echo "                        --secret-key SECRET --endpoint URL"
    echo "  --internal: Disable host ports for this command only."
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
    render)  load_settings; require_settings; export_compose_env; render_service "$SERVICE_NAME" ;;
    env)     load_settings; require_settings; export_compose_env true ;;
    prepare-data) load_settings; require_settings; ensure_data_owner "${DATA_DIR:-$CONF_DIR/data/${INSTANCE_NAME}_data}" ;;
    resource-init) load_settings; require_settings; initialize_resources ;;
    help)    do_help ;;
    *)       do_help; exit 2 ;;
esac

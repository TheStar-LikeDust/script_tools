#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

CONF_FILE=""
NAME_OVERRIDE=""
INTERNAL_ONLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        --internal) INTERNAL_ONLY=true; shift ;;
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

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_secret() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32; }

rustfs_uid_gid() (
    local probe_name passwd_dir passwd_file uid_gid
    probe_name="rustfs_uid_probe_$$"
    passwd_dir="$(mktemp -d)"
    passwd_file="$passwd_dir/passwd"
    trap 'docker rm -f "$probe_name" >/dev/null 2>&1 || true; rm -f "$passwd_file"; rmdir "$passwd_dir" 2>/dev/null || true' EXIT

    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        docker pull "$IMAGE" >/dev/null
    fi
    docker create --name "$probe_name" "$IMAGE" >/dev/null
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

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [RustFS] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
    # Read CRLF files without rewriting existing credentials.
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    if [ "$INTERNAL_ONLY" = true ]; then
        RUSTFS_PUBLISH_PORTS=false
    fi
    export IMAGE DOCKER_NETWORK RUSTFS_PUBLISH_PORTS
    if [[ ! "$INSTANCE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        exit 1
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
    local port admin_port access_key secret_key
    port=$(random_port)
    admin_port=$(random_port)
    while [ "$admin_port" = "$port" ]; do admin_port=$(random_port); done
    access_key=$(random_secret)
    secret_key=$(random_secret)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="rustfs_${ts: -4}"
    fi

    sed -e "s/{{INSTANCE_NAME}}/${name}/g" \
        -e "s/{{RUSTFS_PORT}}/${port}/g" \
        -e "s/{{RUSTFS_ADMIN_PORT}}/${admin_port}/g" \
        -e "s/{{RUSTFS_ACCESS_KEY}}/${access_key}/g" \
        -e "s/{{RUSTFS_SECRET_KEY}}/${secret_key}/g" \
        "$TPL_DIR/settings_rustfs.conf.tpl" > "$CONF_FILE"
)

generate_compose() {
    cat "$TPL_DIR/compose.yaml.tpl" > "$COMPOSE_FILE"
    if [ "$RUSTFS_PUBLISH_PORTS" = true ]; then
        cat >> "$COMPOSE_FILE" <<'YAML'
    ports:
      - "${RUSTFS_PORT:?RUSTFS_PORT is required}:9000"
      - "${RUSTFS_ADMIN_PORT:?RUSTFS_ADMIN_PORT is required}:9001"
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
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [RustFS] Initializing configuration..."
    hr

    [ ! -f "$CONF_FILE" ] && generate_settings
    load_settings
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
    require_managed_container
    [ -f "$COMPOSE_FILE" ] || generate_compose
    hr
    echo "[INFO] [RustFS] Stopping service..."
    hr
    compose stop
}

do_rm() {
    load_settings
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
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset} [--conf PATH] [--name NAME] [--internal]"
    echo "  init    : Generate settings if absent, then Compose YAML and data dir; do not start"
    echo "  start   : Refresh Compose YAML and run docker compose up -d"
    echo "  update  : Pull the configured image and recreate the service if needed"
    echo "  up      : Initialize config and start the container instantly"
    echo "  stop    : Stop the running container"
    echo "  rm      : Remove the container (Preserves ./data and settings_rustfs.conf)"
    echo "  purge   : DANGER - Remove container AND permanently delete ./data (Preserves settings_rustfs.conf)"
    echo "  reset   : DANGER - purge AND delete only this config and its generated YAML"
    echo ""
    echo "Options:"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings_rustfs.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/<INSTANCE_NAME>_data."
    echo "  --name NAME : Full instance name to write at init (default: auto 'rustfs_<ts>')."
    echo "  --internal  : Do not publish ports for this start command (persist RUSTFS_PUBLISH_PORTS=false to keep private)."
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
    *)       do_help ;;
esac

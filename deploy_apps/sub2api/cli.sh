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
DB_PORT="5432"
DB_SSLMODE="disable"
REDIS_PORT="6379"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }
random_port() { shuf -i 30000-40000 -n 1; }
random_password() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 24; }
random_key() { openssl rand -hex 32; }
random_letters() { openssl rand -base64 48 | tr -dc 'a-z' | head -c 4; }

load_settings() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Sub2API] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    # Read CRLF files without rewriting existing settings.
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    export IMAGE DOCKER_NETWORK DB_PORT DB_SSLMODE REDIS_PORT
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
}

validate_settings() {
    local field
    for field in SUB2API_PORT DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE REDIS_HOST REDIS_PORT ADMIN_EMAIL ADMIN_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY; do
        if [ -z "${!field:-}" ]; then
            echo "[ERROR] Set $field in $CONF_FILE. Keep application keys with database backups; see docs/deploy_apps/sub2api.md." >&2
            return 1
        fi
    done
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
    if [ "$labels" != "$INSTANCE_NAME/sub2api" ]; then
        echo "[ERROR] '$INSTANCE_NAME' belongs to another deployment. Choose a unique INSTANCE_NAME; this container will not be modified." >&2
        return 1
    fi
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
    [ ! -f "$CONF_FILE" ] && generate_settings
    load_settings
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"

    hr
    echo "[SUCCESS] [Sub2API] Settings, Compose YAML and local data directory are ready."
    echo "Fill DB_* and REDIS_* in $CONF_FILE, then run 'bash cli.sh start'."
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl instead)"
    hr
}

do_start() {
    load_settings
    validate_settings
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    compose up -d

    hr
    echo "[INFO] [Sub2API] Container started: http://<SERVER_IP>:${SUB2API_PORT}"
    echo "Check readiness: docker logs -f $INSTANCE_NAME"
    echo "Initial admin credentials are saved in $CONF_FILE."
    hr
}

do_update() {
    load_settings
    validate_settings
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data"
    compose pull
    compose up -d

    hr
    echo "[SUCCESS] [Sub2API] Image update applied; settings and data were preserved."
    hr
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
    hr
    echo "[WARN] Deleting only Sub2API local data; external PostgreSQL and Redis are unchanged."
    if [ -d "$CONF_DIR/data/${INSTANCE_NAME}_data" ]; then
        # Use a throwaway root container for bind mounts owned by the application.
        docker run --rm -v "${CONF_DIR}/data:/purge" alpine rm -rf "/purge/${INSTANCE_NAME}_data"
    fi
    echo "[SUCCESS] [Sub2API] Local data purged; settings were preserved."
    hr
}

do_reset() {
    do_purge
    rm -f -- "$CONF_FILE" "$COMPOSE_FILE"
    echo "[SUCCESS] [Sub2API] This instance's settings and generated YAML were removed."
}

do_network() {
    load_settings
    docker network inspect "${DOCKER_NETWORK:-${INSTANCE_NAME}_default}" \
        --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
}

do_help() {
    echo "Usage: $0 {init|start|up|update|stop|rm|purge|reset|network [ls]} [--conf PATH] [--name NAME]"
    echo "  init        : Generate missing settings, Compose YAML and local data directory"
    echo "  start       : Refresh YAML and run docker compose up -d for Sub2API"
    echo "  up          : init + start; external connections must already be configured"
    echo "  update      : Pull the configured image and apply it without resetting data"
    echo "  stop        : Stop only Sub2API"
    echo "  rm          : Remove only this Compose project; preserve data and settings"
    echo "  purge       : DANGER - rm and delete only this application's local data"
    echo "  reset       : DANGER - purge and delete only this settings file and YAML"
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

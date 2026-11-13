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
POSTGRES_IMAGE=""
REDIS_IMAGE=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_SSLMODE=""
REDIS_HOST=""
REDIS_PORT=""
REDIS_DB=""
REDIS_ENABLE_TLS=""

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
    # Read CRLF files without rewriting existing settings.
    set -a
    source <(sed 's/\r$//' "$CONF_FILE")
    set +a
    export IMAGE DOCKER_NETWORK POSTGRES_IMAGE REDIS_IMAGE
    if [[ ! "${INSTANCE_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "[ERROR] INSTANCE_NAME must match [a-z0-9][a-z0-9_-]*." >&2
        return 1
    fi
}

complete_settings() {
    local key value
    for key in POSTGRES_IMAGE REDIS_IMAGE DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE REDIS_HOST REDIS_PORT REDIS_DB REDIS_ENABLE_TLS; do
        [ -z "${!key:-}" ] || continue
        case "$key" in
            POSTGRES_IMAGE) value="paradedb/paradedb:latest-pg17" ;;
            REDIS_IMAGE) value="redis:7-alpine" ;;
            DB_HOST) value="${INSTANCE_NAME}_postgres" ;;
            DB_PORT) value="5432" ;;
            DB_NAME|DB_USER) value="sub2api" ;;
            DB_PASSWORD) value="$(random_password)" ;;
            DB_SSLMODE) value="disable" ;;
            REDIS_HOST) value="${INSTANCE_NAME}_redis" ;;
            REDIS_PORT) value="6379" ;;
            REDIS_DB) value="0" ;;
            REDIS_ENABLE_TLS) value="false" ;;
        esac
        save_setting "$key" "$value"
    done
    if [ -z "${REDIS_PASSWORD+x}" ]; then
        save_setting REDIS_PASSWORD ""
    fi
}

validate_settings() {
    local field
    for field in SUB2API_PORT POSTGRES_IMAGE REDIS_IMAGE DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE REDIS_HOST REDIS_PORT REDIS_DB REDIS_ENABLE_TLS ADMIN_EMAIL ADMIN_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY; do
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
    local service container_name container labels
    for service in sub2api postgres redis; do
        container_name="$INSTANCE_NAME"
        if [ "$service" != sub2api ]; then container_name="${INSTANCE_NAME}_${service}"; fi
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
    load_settings
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data"

    hr
    echo "[SUCCESS] [Sub2API] Bundled application, PostgreSQL and Redis settings are ready."
    echo "Existing settings and application keys were preserved. Run 'bash cli.sh start' to start this instance."
    local field
    for field in SUB2API_PORT ADMIN_EMAIL ADMIN_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY; do
        if [ -z "${!field:-}" ]; then
            echo "[WARN] Set or restore $field in $CONF_FILE before start; existing application keys are not regenerated."
        fi
    done
    echo "Compose definition: $COMPOSE_FILE (generated; edit templates/compose.yaml.tpl instead)"
    hr
}

do_start() {
    load_settings
    validate_settings
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data"
    compose up -d

    hr
    echo "[INFO] [Sub2API] Bundled instance started: http://<SERVER_IP>:${SUB2API_PORT}"
    echo "Check readiness: docker logs -f $INSTANCE_NAME"
    echo "Initial admin credentials are saved in $CONF_FILE."
    hr
}

do_update() {
    load_settings
    validate_settings
    require_managed_container
    generate_compose
    mkdir -p "$CONF_DIR/data/${INSTANCE_NAME}_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_postgres_data" \
        "$CONF_DIR/data/${INSTANCE_NAME}_redis_data"
    compose pull
    compose up -d

    hr
    echo "[SUCCESS] [Sub2API] Application and dependency image updates applied; settings and data were preserved."
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
    echo "[WARN] Deleting this instance's application, PostgreSQL and Redis data."
    local data_name
    for data_name in "${INSTANCE_NAME}_data" "${INSTANCE_NAME}_postgres_data" "${INSTANCE_NAME}_redis_data"; do
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
    echo "  init        : Generate local settings, fill empty dependency fields, and prepare YAML/data directories"
    echo "  start       : Start Sub2API with its bundled PostgreSQL and Redis"
    echo "  up          : init + start for the bundled instance"
    echo "  update      : Pull application and dependency images; preserve settings and data"
    echo "  stop        : Stop this instance's application, PostgreSQL and Redis"
    echo "  rm          : Remove only this Compose project; preserve data and settings"
    echo "  purge       : DANGER - rm and delete this instance's application, PostgreSQL and Redis data"
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

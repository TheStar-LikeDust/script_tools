#!/usr/bin/env bash
# Redis connection and reusable Compose rendering. Sourced by cli.sh.

build_connection_string() {
    if [[ ! "$CONNECTION_DB" =~ ^[0-9]+$ ]]; then
        echo "[ERROR] --db must be a nonnegative integer." >&2
        return 1
    fi
    printf 'redis://%s:6379/%s' "$INSTANCE_NAME" "$CONNECTION_DB"
}

export_compose_env() {
    local print_exports="${1:-false}" key
    REDIS_INSTANCE_NAME="$INSTANCE_NAME"
    REDIS_IMAGE="$IMAGE"
    REDIS_DOCKER_NETWORK="$DOCKER_NETWORK"
    REDIS_URL="$(build_connection_string)"
    for key in REDIS_INSTANCE_NAME REDIS_IMAGE REDIS_PORT REDIS_PUBLISH_PORT REDIS_DOCKER_NETWORK REDIS_URL; do
        export "$key"
        if [ "$print_exports" = true ]; then printf 'export %s=%q\n' "$key" "${!key}"; fi
    done
}

render_service() {
    local service_name="${1:-redis}"
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[ERROR] Invalid Compose service name: $service_name" >&2
        return 1
    fi
    sed "s/{{SERVICE_NAME}}/$service_name/" "$TPL_DIR/compose.yaml.tpl"
    if [ "$REDIS_PUBLISH_PORT" = true ]; then
        cat <<'YAML'
    ports:
      - "${REDIS_PORT:?REDIS_PORT is required}:6379"
YAML
    fi
}

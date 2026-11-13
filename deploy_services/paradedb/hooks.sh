#!/usr/bin/env bash
# ParadeDB-specific Compose fragments and connection settings, sourced by cli.sh.

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

build_connection_string() {
    printf 'postgresql://%s:%s@%s:5432/%s?sslmode=disable' \
        "$(urlencode "$DB_USER")" "$(urlencode "$DB_PASSWORD")" \
        "$INSTANCE_NAME" "$(urlencode "$DB_NAME")"
}

export_compose_env() {
    local key scoped_key
    for key in INSTANCE_NAME IMAGE DB_PORT DB_PUBLISH_PORT DOCKER_NETWORK DB_USER DB_PASSWORD DB_NAME; do
        scoped_key="PARADEDB_$key"
        printf -v "$scoped_key" '%s' "${!key}"
        export "$scoped_key"
        printf 'export %s=%q\n' "$scoped_key" "${!scoped_key}"
    done
    PARADEDB_DSN="$(build_connection_string)"
    export PARADEDB_DSN
    printf 'export PARADEDB_DSN=%q\n' "$PARADEDB_DSN"
}

render_service() {
    local service_name="${1:-paradedb}"
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[ERROR] Invalid Compose service name: $service_name" >&2
        return 1
    fi
    sed "s/{{SERVICE_NAME}}/$service_name/g" "$TPL_DIR/compose.yaml.tpl"
    if [ "$DB_PUBLISH_PORT" = true ]; then
        cat <<'YAML'
    ports:
      - "${PARADEDB_DB_PORT:?PARADEDB_DB_PORT is required}:5432"
YAML
    fi
}

#!/usr/bin/env bash
# LobeHub dependency composition and RustFS resource initialization.

generate_jwks() {
    local -a node_cmd
    if command -v node >/dev/null 2>&1; then
        node_cmd=(node)
    else
        node_cmd=(docker run --rm -i --network none --entrypoint node "$IMAGE")
    fi
    "${node_cmd[@]}" --input-type=commonjs - <<'JS'
const { generateKeyPairSync, randomUUID } = require('node:crypto');
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const key = {
  ...privateKey.export({ format: 'jwk' }),
  alg: 'RS256',
  use: 'sig',
  kid: randomUUID(),
};
process.stdout.write(JSON.stringify({ keys: [key] }));
JS
}

ensure_jwks() {
    if [ -z "$JWKS_KEY" ]; then
        JWKS_KEY="$(generate_jwks)" || return
        save_setting JWKS_KEY "$JWKS_KEY" || return
    fi
    export JWKS_KEY
}

resolve_dependency_conf() {
    local dependency_name="$1" dependency_path
    case "$dependency_name" in
        paradedb) dependency_path="$PARADEDB_CONF" ;;
        redis) dependency_path="$REDIS_CONF" ;;
        rustfs) dependency_path="$RUSTFS_CONF" ;;
        *)
            echo "[ERROR] Unknown dependency: $dependency_name" >&2
            return 1
            ;;
    esac
    if [[ "$dependency_path" = /* ]]; then
        printf '%s' "$dependency_path"
    else
        printf '%s/%s' "$CONF_DIR" "$dependency_path"
    fi
}

service_cli_path() {
    case "$1" in
        paradedb|redis|rustfs) printf '%s/../../deploy_services/%s/cli.sh' "$SCRIPT_DIR" "$1" ;;
        *)
            echo "[ERROR] Unknown dependency: $1" >&2
            return 1
            ;;
    esac
}

require_dependency_settings() {
    local dependency_name dependency_conf dependency_cli
    for dependency_name in paradedb redis rustfs; do
        dependency_conf="$(resolve_dependency_conf "$dependency_name")" || return
        dependency_cli="$(service_cli_path "$dependency_name")" || return
        if [ ! -f "$dependency_conf" ]; then
            echo "[ERROR] $dependency_name settings not found: $dependency_conf. Run init with the same --conf first." >&2
            return 1
        fi
        if [ ! -f "$dependency_cli" ]; then
            echo "[ERROR] $dependency_name CLI not found: $dependency_cli" >&2
            return 1
        fi
    done
}

prepare_dependency_settings() {
    local dependency_conf dependency_cli
    local -a service_args

    dependency_conf="$(resolve_dependency_conf paradedb)" || return
    dependency_cli="$(service_cli_path paradedb)" || return
    service_args=(init --conf "$dependency_conf" --name "${INSTANCE_NAME}_postgres" \
        --publish-port false --db-name lobechat --db-user lobechat --config-only)
    if [ -n "$DOCKER_NETWORK" ]; then service_args+=(--network "$DOCKER_NETWORK"); fi
    if ! bash "$dependency_cli" "${service_args[@]}" >/dev/null; then
        echo "[ERROR] Could not prepare ParadeDB settings: $dependency_conf" >&2
        return 1
    fi

    dependency_conf="$(resolve_dependency_conf redis)" || return
    dependency_cli="$(service_cli_path redis)" || return
    service_args=(init --conf "$dependency_conf" --name "${INSTANCE_NAME}_redis" \
        --publish-port false --config-only)
    if [ -n "$DOCKER_NETWORK" ]; then service_args+=(--network "$DOCKER_NETWORK"); fi
    if ! bash "$dependency_cli" "${service_args[@]}" >/dev/null; then
        echo "[ERROR] Could not prepare Redis settings: $dependency_conf" >&2
        return 1
    fi

    dependency_conf="$(resolve_dependency_conf rustfs)" || return
    dependency_cli="$(service_cli_path rustfs)" || return
    service_args=(init --conf "$dependency_conf" --name "${INSTANCE_NAME}_rustfs" \
        --publish-ports true --config-only)
    if [ -n "$DOCKER_NETWORK" ]; then service_args+=(--network "$DOCKER_NETWORK"); fi
    if ! bash "$dependency_cli" "${service_args[@]}" >/dev/null; then
        echo "[ERROR] Could not prepare RustFS settings: $dependency_conf" >&2
        return 1
    fi
}

load_dependency_environment() {
    require_dependency_settings || return

    local dependency_name dependency_conf dependency_cli environment_output
    dependency_name=paradedb
    dependency_conf="$(resolve_dependency_conf "$dependency_name")" || return
    dependency_cli="$(service_cli_path "$dependency_name")" || return
    if ! environment_output="$(bash "$dependency_cli" env --conf "$dependency_conf")"; then
        echo "[ERROR] Could not load ParadeDB environment: $dependency_conf" >&2
        return 1
    fi
    eval "$environment_output" || return

    dependency_name=redis
    dependency_conf="$(resolve_dependency_conf "$dependency_name")" || return
    dependency_cli="$(service_cli_path "$dependency_name")" || return
    if ! environment_output="$(bash "$dependency_cli" env --conf "$dependency_conf" --db "$REDIS_DATABASE")"; then
        echo "[ERROR] Could not load Redis environment: $dependency_conf" >&2
        return 1
    fi
    eval "$environment_output" || return

    dependency_name=rustfs
    dependency_conf="$(resolve_dependency_conf "$dependency_name")" || return
    dependency_cli="$(service_cli_path "$dependency_name")" || return
    if ! environment_output="$(bash "$dependency_cli" env --conf "$dependency_conf")"; then
        echo "[ERROR] Could not load RustFS environment: $dependency_conf" >&2
        return 1
    fi
    eval "$environment_output" || return

    DATABASE_URL="$PARADEDB_DSN"
    S3_INTERNAL_ENDPOINT="$RUSTFS_ENDPOINT"
    export DATABASE_URL S3_INTERNAL_ENDPOINT
}

export_app_compose_environment() {
    LOBECHAT_DOCKER_NETWORK="$DOCKER_NETWORK"
    export LOBECHAT_DOCKER_NETWORK INSTANCE_NAME IMAGE LOBECHAT_PORT APP_URL DATABASE_URL KEY_VAULTS_SECRET AUTH_SECRET JWKS_KEY \
        AUTH_SSO_PROVIDERS AUTH_CASDOOR_ID AUTH_CASDOOR_SECRET AUTH_CASDOOR_ISSUER \
        AUTH_ALLOWED_EMAILS COMPOSIO_API_KEY ENABLED_OPENAI OPENAI_API_KEY OPENAI_PROXY_URL \
        OPENAI_MODEL_LIST REDIS_URL REDIS_DATABASE REDIS_PREFIX S3_ENDPOINT \
        S3_INTERNAL_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
}

render_compose() (
    umask 077
    local dependency_name service_name dependency_conf dependency_cli service_fragment compose_tmp
    compose_tmp="$(mktemp "${COMPOSE_FILE}.XXXXXX")" || return
    trap 'rm -f -- "$compose_tmp"' EXIT
    {
        printf '# Generated by LobeHub using deploy_services service fragments.\nservices:\n' || return
        for dependency_name in paradedb redis rustfs; do
            case "$dependency_name" in
                paradedb) service_name=postgres ;;
                *) service_name="$dependency_name" ;;
            esac
            dependency_conf="$(resolve_dependency_conf "$dependency_name")" || return
            dependency_cli="$(service_cli_path "$dependency_name")" || return
            if ! service_fragment="$(bash "$dependency_cli" render --conf "$dependency_conf" --service-name "$service_name")"; then
                echo "[ERROR] Could not render $dependency_name service." >&2
                return 1
            fi
            printf '%s\n' "$service_fragment" || return
        done
        cat "$TPL_DIR/compose.yaml.tpl" || return
        if [ -n "$DOCKER_NETWORK" ]; then
            cat <<'YAML' || return
networks:
  default:
    external: true
    name: "${LOBECHAT_DOCKER_NETWORK}"
YAML
        fi
    } > "$compose_tmp" || return
    mv -- "$compose_tmp" "$COMPOSE_FILE"
)

initialize_rustfs_resources() {
    local dependency_conf dependency_cli
    dependency_conf="$(resolve_dependency_conf rustfs)" || return
    dependency_cli="$(service_cli_path rustfs)" || return
    bash "$dependency_cli" resource-init --conf "$dependency_conf" \
        --owner "$INSTANCE_NAME" --bucket "$S3_BUCKET" \
        --access-key "$S3_ACCESS_KEY_ID" --secret-key "$S3_SECRET_ACCESS_KEY" \
        --endpoint "$RUSTFS_ENDPOINT"
}

prepare_rustfs_data() {
    local dependency_conf dependency_cli
    dependency_conf="$(resolve_dependency_conf rustfs)" || return
    dependency_cli="$(service_cli_path rustfs)" || return
    bash "$dependency_cli" prepare-data --conf "$dependency_conf" \
        --data-dir "$CONF_DIR/data/${RUSTFS_INSTANCE_NAME}_data"
}

remove_dependency_settings() {
    local dependency_name dependency_path dependency_conf dependency_dir dependency_compose_basename
    for dependency_name in paradedb redis rustfs; do
        case "$dependency_name" in
            paradedb) dependency_path="$PARADEDB_CONF" ;;
            redis) dependency_path="$REDIS_CONF" ;;
            rustfs) dependency_path="$RUSTFS_CONF" ;;
        esac
        [ -n "$dependency_path" ] || continue
        dependency_conf="$(resolve_dependency_conf "$dependency_name")" || return
        dependency_dir="$(cd "$(dirname "$dependency_conf")" && pwd)" || return
        dependency_compose_basename="${dependency_conf##*/}"
        dependency_compose_basename="${dependency_compose_basename#settings_}"
        case "$dependency_dir" in
            "$CONF_DIR"|"$CONF_DIR"/*) rm -f -- "$dependency_conf" "$dependency_dir/${dependency_compose_basename%.conf}.compose.yaml" || return ;;
        esac
    done
}

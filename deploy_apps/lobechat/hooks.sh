#!/usr/bin/env bash

source "$SCRIPT_DIR/../../shared_scripts/network.sh"

PARADEDB_CLI="$SCRIPT_DIR/../../deploy_services/paradedb/cli.sh"
PG_CONF="$CONF_DIR/settings_paradedb.conf"
REDIS_CLI="$SCRIPT_DIR/../../deploy_services/redis/cli.sh"
REDIS_CONF="$CONF_DIR/settings_redis.conf"
RUSTFS_CLI="$SCRIPT_DIR/../../deploy_services/rustfs/cli.sh"
AWS_CLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"

deploy_paradedb() { local sub="$1"; shift; bash "$PARADEDB_CLI" "$sub" --conf "$PG_CONF" "$@"; }
deploy_redis() { local sub="$1"; shift; bash "$REDIS_CLI" "$sub" --conf "$REDIS_CONF" "$@"; }
conf_val() { ( . "$1" >/dev/null 2>&1; printf '%s' "${!2:-}" ); }
redis_instance_name() { printf '%s_redis' "$INSTANCE_NAME"; }
rustfs_conf_path() { printf '%s/settings_rustfs.conf' "$CONF_DIR"; }
legacy_rustfs_conf_path() { printf '%s/settings_%s_rustfs.conf' "$CONF_DIR" "$INSTANCE_NAME"; }
rustfs_instance_name() { printf '%s_rustfs' "$INSTANCE_NAME"; }
deploy_rustfs() {
    local sub="$1"
    shift
    bash "$RUSTFS_CLI" "$sub" --conf "$(rustfs_conf_path)" "$@"
}

migrate_rustfs_conf() {
    local rustfs_conf legacy_conf
    rustfs_conf="$(rustfs_conf_path)"
    legacy_conf="$(legacy_rustfs_conf_path)"
    if [ ! -f "$rustfs_conf" ] && [ -f "$legacy_conf" ]; then
        echo "[INFO] [LobeHub] Migrating RustFS settings to $rustfs_conf."
        mv "$legacy_conf" "$rustfs_conf"
        chmod 600 "$rustfs_conf"
    fi
}

ensure_rustfs_conf() {
    local rustfs_conf
    rustfs_conf="$(rustfs_conf_path)"
    migrate_rustfs_conf
    if [ ! -f "$rustfs_conf" ]; then
        deploy_rustfs init --name "$(rustfs_instance_name)" >/dev/null
    fi
    chmod 600 "$rustfs_conf"
}

ensure_redis_conf() {
    if [ ! -f "$REDIS_CONF" ]; then
        deploy_redis init --name "$(redis_instance_name)" >/dev/null
    fi
    chmod 600 "$REDIS_CONF"
}

wait_healthy() {
    local label="$1" name="$2"
    echo "[INFO] [LobeHub] Waiting for $label ($name)..."
    for _ in $(seq 1 30); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = "healthy" ]; then
            return 0
        fi
        sleep 2
    done
    echo "[ERROR] $label not healthy after ~60s. Inspect: docker logs $name" >&2
    return 1
}

ensure_s3_bucket() {
    local network="$1" endpoint="$2" bucket="$3" access_key="$4" secret_key="$5"
    local aws_cli_args=(
        --rm
        --network "$network"
        -e "AWS_ACCESS_KEY_ID=$access_key"
        -e "AWS_SECRET_ACCESS_KEY=$secret_key"
        -e "AWS_DEFAULT_REGION=us-east-1"
        "$AWS_CLI_IMAGE"
        --endpoint-url "$endpoint"
    )

    if docker run "${aws_cli_args[@]}" s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
        return 0
    fi

    docker run "${aws_cli_args[@]}" s3api create-bucket --bucket "$bucket" >/dev/null
}

on_init() {
    local new_db=false
    [ -f "$PG_CONF" ] || new_db=true
    deploy_paradedb init --name "${INSTANCE_NAME}_paradedb" >/dev/null
    chmod 600 "$PG_CONF"
    ensure_rustfs_conf
    ensure_redis_conf
    if [ "$new_db" = true ]; then
        # The app reaches Postgres through the private Docker network.
        sed -i 's/^DB_PUBLISH_PORT=.*/DB_PUBLISH_PORT="false"/' "$PG_CONF"
    fi
}

on_start() {
    if [ ! -f "$PG_CONF" ]; then
        echo "[ERROR] Missing bundled DB config. Run 'bash cli.sh init' first." >&2
        return 1
    fi
    local net="${INSTANCE_NAME}_net" rustfs_conf rustfs_name access_key secret_key
    local redis_name
    local db_name
    local rustfs_ip
    db_name="$(conf_val "$PG_CONF" INSTANCE_NAME)"
    ensure_rustfs_conf
    ensure_redis_conf
    rustfs_conf="$(rustfs_conf_path)"
    rustfs_name="$(conf_val "$rustfs_conf" INSTANCE_NAME)"
    redis_name="$(conf_val "$REDIS_CONF" INSTANCE_NAME)"

    net_ensure "$net"
    deploy_paradedb start
    deploy_redis start
    net_connect "$net" "$db_name"
    net_connect "$net" "$redis_name"
    wait_healthy "database" "$db_name"
    wait_healthy "Redis" "$redis_name"

    deploy_rustfs start --internal
    net_connect "$net" "$rustfs_name"
    wait_healthy "RustFS" "$rustfs_name"

    # RustFS listens on container port 9000; RUSTFS_PORT is only a host-published port.
    if ! rustfs_ip="$(docker inspect --format "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$rustfs_name")" || [ -z "$rustfs_ip" ]; then
        echo "[ERROR] Could not determine RustFS IP on Docker network '$net'." >&2
        return 1
    fi

    S3_ENDPOINT="http://${rustfs_ip}:9000"
    S3_BUCKET="${S3_BUCKET:-lobechat}"
    access_key="$(conf_val "$rustfs_conf" RUSTFS_ACCESS_KEY)"
    secret_key="$(conf_val "$rustfs_conf" RUSTFS_SECRET_KEY)"
    S3_ACCESS_KEY_ID="$access_key"
    S3_SECRET_ACCESS_KEY="$secret_key"
    ensure_s3_bucket "$net" "$S3_ENDPOINT" "$S3_BUCKET" "$access_key" "$secret_key"

    REDIS_DATABASE="${REDIS_DATABASE:-0}"
    REDIS_PREFIX="${REDIS_PREFIX:-lobechat}"
    REDIS_URL="redis://${redis_name}:6379/${REDIS_DATABASE}"
    HOOK_RUN_ARGS=(--network "$net")
}

on_stop() {
    deploy_paradedb stop
    if [ -f "$REDIS_CONF" ]; then deploy_redis stop; fi
    migrate_rustfs_conf
    if [ -f "$(rustfs_conf_path)" ]; then deploy_rustfs stop; fi
}

on_rm() {
    deploy_paradedb rm
    if [ -f "$REDIS_CONF" ]; then deploy_redis rm; fi
    migrate_rustfs_conf
    if [ -f "$(rustfs_conf_path)" ]; then deploy_rustfs rm; fi
    net_rm "${INSTANCE_NAME}_net"
}

on_purge() {
    deploy_paradedb purge
    if [ -f "$REDIS_CONF" ]; then deploy_redis purge; fi
    migrate_rustfs_conf
    if [ -f "$(rustfs_conf_path)" ]; then deploy_rustfs purge; fi
    net_rm "${INSTANCE_NAME}_net"
}

on_network() { net_ls "${INSTANCE_NAME}_net"; }

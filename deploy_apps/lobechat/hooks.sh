#!/usr/bin/env bash

source "$SCRIPT_DIR/../../lib/network.sh"

PARADEDB_CLI="$SCRIPT_DIR/../../deploy/paradedb/cli.sh"
REDIS_CLI="$SCRIPT_DIR/../../deploy/redis/cli.sh"
RUSTFS_CLI="$SCRIPT_DIR/../../deploy/rustfs/cli.sh"
CASDOOR_CLI="$SCRIPT_DIR/../casdoor/cli.sh"

PG_CONF="$CONF_DIR/settings_paradedb.conf"
REDIS_CONF="$CONF_DIR/settings_redis.conf"
RUSTFS_CONF="$CONF_DIR/settings_rustfs.conf"
CASDOOR_CONF="$CONF_DIR/../casdoor/settings_casdoor.conf"

deploy_paradedb() { local sub="$1"; shift; bash "$PARADEDB_CLI" "$sub" --conf "$PG_CONF" "$@"; }
deploy_redis()    { local sub="$1"; shift; bash "$REDIS_CLI" "$sub" --conf "$REDIS_CONF" "$@"; }
deploy_rustfs()   { local sub="$1"; shift; bash "$RUSTFS_CLI" "$sub" --conf "$RUSTFS_CONF" "$@"; }
deploy_casdoor()  { local sub="$1"; shift; bash "$CASDOOR_CLI" "$sub" "$@"; }

conf_val() { ( . "$1" >/dev/null 2>&1; printf '%s' "${!2:-}" ); }

wait_pg() {
    local name="$1"
    echo "[INFO] [LobeChat] Waiting for bundled DB ($name) to become healthy..."
    for _ in $(seq 1 30); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = "healthy" ]; then
            return 0
        fi
        sleep 2
    done
    echo "[WARN] [LobeChat] DB not healthy after ~60s; continuing anyway."
}

on_init() {
    if [ "$USE_INTERNAL_DB" = "true" ]; then deploy_paradedb init --name "${INSTANCE_NAME}_paradedb" >/dev/null; fi
    if [ "$USE_INTERNAL_REDIS" = "true" ]; then deploy_redis init --name "${INSTANCE_NAME}_redis" >/dev/null; fi
    if [ "$USE_INTERNAL_S3" = "true" ]; then deploy_rustfs init --name "${INSTANCE_NAME}_rustfs" >/dev/null; fi
    if [ "$USE_INTERNAL_CASDOOR" = "true" ]; then deploy_casdoor init >/dev/null; fi
}

on_start() {
    local net="${INSTANCE_NAME}_net"
    net_ensure "$net"

    echo "[INFO] Starting bundled base services and attaching to ${net}..."
    if [ "$USE_INTERNAL_DB" = "true" ]; then
        deploy_paradedb start
        net_connect "$net" "${INSTANCE_NAME}_paradedb"
        wait_pg "${INSTANCE_NAME}_paradedb"
    fi
    if [ "$USE_INTERNAL_REDIS" = "true" ]; then
        deploy_redis start
        net_connect "$net" "${INSTANCE_NAME}_redis"
    fi
    if [ "$USE_INTERNAL_S3" = "true" ]; then
        deploy_rustfs start
        net_connect "$net" "${INSTANCE_NAME}_rustfs"
    fi
    if [ "$USE_INTERNAL_CASDOOR" = "true" ]; then
        deploy_casdoor start
        net_connect "$net" "$(conf_val "$CASDOOR_CONF" INSTANCE_NAME)"
    fi

    HOOK_RUN_ARGS=(--network "$net")
}

on_stop() {
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && deploy_casdoor stop || true
    [ "$USE_INTERNAL_S3" = "true" ] && deploy_rustfs stop || true
    [ "$USE_INTERNAL_REDIS" = "true" ] && deploy_redis stop || true
    [ "$USE_INTERNAL_DB" = "true" ] && deploy_paradedb stop || true
}

on_rm() {
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && deploy_casdoor rm || true
    [ "$USE_INTERNAL_S3" = "true" ] && deploy_rustfs rm || true
    [ "$USE_INTERNAL_REDIS" = "true" ] && deploy_redis rm || true
    [ "$USE_INTERNAL_DB" = "true" ] && deploy_paradedb rm || true
    net_rm "${INSTANCE_NAME}_net"
}

on_purge() {
    [ "$USE_INTERNAL_CASDOOR" = "true" ] && deploy_casdoor purge || true
    [ "$USE_INTERNAL_S3" = "true" ] && deploy_rustfs purge || true
    [ "$USE_INTERNAL_REDIS" = "true" ] && deploy_redis purge || true
    [ "$USE_INTERNAL_DB" = "true" ] && deploy_paradedb purge || true
    net_rm "${INSTANCE_NAME}_net"
}

on_network() { net_ls "${INSTANCE_NAME}_net"; }

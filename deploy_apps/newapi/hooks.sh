#!/usr/bin/env bash
# New API service-specific operations, invoked passively by cli.sh hooks.
# Keeps cli.sh focused on the new-api container itself; everything that makes
# new-api "composite" (bundled paradedb + redis, networking) lives here.
# Sourced into cli.sh, so it shares its variables (SCRIPT_DIR, CONF_DIR,
# INSTANCE_NAME, HOOK_RUN_ARGS, ...) and utility functions.

source "$SCRIPT_DIR/../../lib/network.sh"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Bundled deps delegated to deploy/*'s cli.sh; their configs + data live here via --conf
PARADEDB_CLI="$SCRIPT_DIR/../../deploy/paradedb/cli.sh"
REDIS_CLI="$SCRIPT_DIR/../../deploy/redis/cli.sh"
PG_CONF="$CONF_DIR/settings_paradedb.conf"
REDIS_CONF="$CONF_DIR/settings_redis.conf"
deploy_paradedb() { local sub="$1"; shift; bash "$PARADEDB_CLI" "$sub" --conf "$PG_CONF" "$@"; }
deploy_redis()    { local sub="$1"; shift; bash "$REDIS_CLI" "$sub" --conf "$REDIS_CONF" "$@"; }

# Read one value from a bundled dep's config without clobbering new-api's own vars
pg_val() {
    ( . "$PG_CONF"; case "$1" in
        user)      echo "$DB_USER" ;;
        pass)      echo "$DB_PASSWORD" ;;
        db)        echo "$DB_NAME" ;;
        container) echo "$INSTANCE_NAME" ;;
    esac )
}

redis_container() { ( . "$REDIS_CONF"; echo "$INSTANCE_NAME" ); }

# Wait until the bundled DB container reports healthy (best effort)
wait_pg() {
    local name="$1"
    echo "[INFO] [NewAPI] Waiting for bundled DB ($name) to become healthy..."
    for _ in $(seq 1 30); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = "healthy" ]; then
            return 0
        fi
        sleep 2
    done
    echo "[WARN] [NewAPI] DB not healthy after ~60s; continuing anyway."
}

# -----------------------------------------------------------------------------
# Lifecycle hooks (called by cli.sh)
# -----------------------------------------------------------------------------
on_init() {
    deploy_paradedb init --name "${INSTANCE_NAME}_paradedb"
    deploy_redis init --name "${INSTANCE_NAME}_redis"
}

# Bring up bundled deps, attach them to the app network, wait for DB health,
# then expose connection strings and the --network arg to cli.sh's docker run.
on_start() {
    local net="${INSTANCE_NAME}_net"
    net_ensure "$net"
    deploy_paradedb start
    deploy_redis start
    net_connect "$net" "$(pg_val container)"
    net_connect "$net" "$(redis_container)"
    wait_pg "$(pg_val container)"

    # Connection strings consumed by cli.sh's docker run (-e SQL_DSN / -e REDIS_CONN_STRING)
    SQL_DSN="postgresql://$(pg_val user):$(pg_val pass)@$(pg_val container):5432/$(pg_val db)"
    REDIS_CONN_STRING="redis://$(redis_container):6379"
    HOOK_RUN_ARGS=(--network "$net")
}

on_stop() {
    deploy_paradedb stop
    deploy_redis stop
}

on_rm() {
    deploy_paradedb rm
    deploy_redis rm
    net_rm "${INSTANCE_NAME}_net"
}

on_purge() {
    deploy_paradedb purge
    deploy_redis purge
    net_rm "${INSTANCE_NAME}_net"
}

# Optional `network` proxy command exposed by cli.sh
on_network() { net_ls "${INSTANCE_NAME}_net"; }

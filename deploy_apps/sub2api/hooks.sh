#!/usr/bin/env bash
# Sub2API service-specific operations, invoked passively by cli.sh hooks.
# Keeps cli.sh focused on the sub2api container itself; everything that makes
# sub2api "composite" (bundled paradedb + redis, networking) lives here.
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

# Read one value from a bundled dep's config without clobbering sub2api's own vars
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
    echo "[INFO] [Sub2API] Waiting for bundled DB ($name) to become healthy..."
    for _ in $(seq 1 30); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = "healthy" ]; then
            return 0
        fi
        sleep 2
    done
    echo "[WARN] [Sub2API] DB not healthy after ~60s; continuing anyway."
}

# -----------------------------------------------------------------------------
# Lifecycle hooks (called by cli.sh)
# -----------------------------------------------------------------------------
on_init() {
    deploy_paradedb init --name "paradedb_${INSTANCE_NAME}"
    deploy_redis init --name "redis_${INSTANCE_NAME}"
}

# Bring up bundled deps, attach them to the app network, wait for DB health,
# then expose connection values and the --network arg to cli.sh's docker run.
on_start() {
    local net="${INSTANCE_NAME}_net"
    net_ensure "$net"
    deploy_paradedb start
    deploy_redis start
    net_connect "$net" "$(pg_val container)"
    net_connect "$net" "$(redis_container)"
    wait_pg "$(pg_val container)"

    # Connection values consumed by cli.sh's docker run (split DATABASE_*/REDIS_* env)
    SUB2API_DB_HOST="$(pg_val container)"
    SUB2API_DB_USER="$(pg_val user)"
    SUB2API_DB_PASSWORD="$(pg_val pass)"
    SUB2API_DB_NAME="$(pg_val db)"
    SUB2API_REDIS_HOST="$(redis_container)"
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

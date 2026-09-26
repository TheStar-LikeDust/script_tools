#!/usr/bin/env bash

source "$SCRIPT_DIR/../../shared_scripts/network.sh"

PARADEDB_CLI="$SCRIPT_DIR/../../deploy_services/paradedb/cli.sh"
PG_CONF="$CONF_DIR/settings_paradedb.conf"

deploy_paradedb() { local sub="$1"; shift; bash "$PARADEDB_CLI" "$sub" --conf "$PG_CONF" "$@"; }
conf_val() { ( . "$1" >/dev/null 2>&1; printf '%s' "${!2:-}" ); }

wait_pg() {
    local name="$1"
    echo "[INFO] [LobeHub] Waiting for bundled DB ($name)..."
    for _ in $(seq 1 30); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = "healthy" ]; then
            return 0
        fi
        sleep 2
    done
    echo "[ERROR] Database not healthy after ~60s. Inspect: docker logs $name" >&2
    return 1
}

on_init() {
    local new_db=false
    [ -f "$PG_CONF" ] || new_db=true
    deploy_paradedb init --name "${INSTANCE_NAME}_paradedb" >/dev/null
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
    local net="${INSTANCE_NAME}_net"
    local db_name
    db_name="$(conf_val "$PG_CONF" INSTANCE_NAME)"
    net_ensure "$net"
    deploy_paradedb start
    net_connect "$net" "$db_name"
    wait_pg "$db_name"
    HOOK_RUN_ARGS=(--network "$net")
}

on_stop() { deploy_paradedb stop; }
on_rm() { deploy_paradedb rm; net_rm "${INSTANCE_NAME}_net"; }
on_purge() { deploy_paradedb purge; net_rm "${INSTANCE_NAME}_net"; }
on_network() { net_ls "${INSTANCE_NAME}_net"; }

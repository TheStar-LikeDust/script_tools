#!/usr/bin/env bash
# Casdoor service-specific operations, invoked passively by cli.sh hooks.
# Keeps cli.sh focused on the casdoor container itself; everything that makes
# casdoor "composite" (bundled paradedb, app.conf rendering, networking) lives here.
# Sourced into cli.sh, so it shares its variables (SCRIPT_DIR, CONF_DIR,
# INSTANCE_NAME, HOOK_RUN_ARGS, ...) and utility functions.

source "$SCRIPT_DIR/../../lib/network.sh"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Bundled DB delegated to deploy_services/paradedb's cli.sh; its config + data live here via --conf
PARADEDB_CLI="$SCRIPT_DIR/../../deploy_services/paradedb/cli.sh"
PG_CONF="$SCRIPT_DIR/settings_paradedb.conf"
deploy_paradedb() { local sub="$1"; shift; bash "$PARADEDB_CLI" "$sub" --conf "$PG_CONF" "$@"; }

# app.conf lives in a dedicated config dir, parallel to data, so config never mixes with runtime data
app_conf_path() { echo "$CONF_DIR/data/${INSTANCE_NAME}_config/app.conf"; }

# Read one value from the bundled paradedb config without clobbering casdoor's own vars
pg_val() {
    ( . "$PG_CONF"; case "$1" in
        port)      echo "$DB_PORT" ;;
        user)      echo "$DB_USER" ;;
        pass)      echo "$DB_PASSWORD" ;;
        bootstrap) echo "$DB_NAME" ;;
        container) echo "$INSTANCE_NAME" ;;
    esac )
}

# Render config/app.conf from current settings_casdoor.conf (+ bundled DB config when applicable)
render_app_conf() {
    local db_host db_port db_user db_pass db_bootstrap
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        db_host="$(pg_val container)"; db_port="5432"
        db_user="$(pg_val user)"; db_pass="$(pg_val pass)"; db_bootstrap="$(pg_val bootstrap)"
    else
        db_host="$EXT_DB_HOST"; db_port="$EXT_DB_PORT"
        db_user="$EXT_DB_USER"; db_pass="$EXT_DB_PASSWORD"; db_bootstrap="$EXT_DB_NAME"
    fi

    local app_conf; app_conf="$(app_conf_path)"
    mkdir -p "$(dirname "$app_conf")"
    sed -e "s#{{CASDOOR_DB_USER}}#${db_user}#g" \
        -e "s#{{CASDOOR_DB_PASSWORD}}#${db_pass}#g" \
        -e "s#{{CASDOOR_DB_HOST}}#${db_host}#g" \
        -e "s#{{CASDOOR_DB_PORT}}#${db_port}#g" \
        -e "s#{{CASDOOR_DB_BOOTSTRAP}}#${db_bootstrap}#g" \
        -e "s#{{CASDOOR_DB_NAME}}#${CASDOOR_DB_NAME}#g" \
        "$TPL_DIR/app.conf.tpl" > "$app_conf"
}

# Wait until the bundled DB container reports healthy (best effort)
wait_pg() {
    local name="$1"
    echo "[INFO] [Casdoor] Waiting for bundled DB ($name) to become healthy..."
    for _ in $(seq 1 30); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = "healthy" ]; then
            return 0
        fi
        sleep 2
    done
    echo "[WARN] [Casdoor] DB not healthy after ~60s; continuing anyway."
}

# -----------------------------------------------------------------------------
# Lifecycle hooks (called by cli.sh)
# -----------------------------------------------------------------------------
on_init() {
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        deploy_paradedb init --name "${INSTANCE_NAME}_paradedb"
    fi
    render_app_conf
}

# Bring up bundled DB, attach to the app network, wait healthy, then hand the
# --network arg to cli.sh's docker run via HOOK_RUN_ARGS.
on_start() {
    render_app_conf
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        local net="${INSTANCE_NAME}_net"
        net_ensure "$net"
        deploy_paradedb start
        net_connect "$net" "$(pg_val container)"
        wait_pg "$(pg_val container)"
        HOOK_RUN_ARGS=(--network "$net")
    fi
}

on_stop() { [ "$WITH_BUNDLED_DB" = "true" ] && deploy_paradedb stop || true; }

on_rm() {
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        deploy_paradedb rm
        net_rm "${INSTANCE_NAME}_net"
    fi
}

on_purge() {
    rm -rf "$CONF_DIR/data/${INSTANCE_NAME}_config" 2>/dev/null || true
    if [ "$WITH_BUNDLED_DB" = "true" ]; then
        deploy_paradedb purge
        net_rm "${INSTANCE_NAME}_net"
    fi
}

# Optional `network` proxy command exposed by cli.sh
on_network() { net_ls "${INSTANCE_NAME}_net"; }

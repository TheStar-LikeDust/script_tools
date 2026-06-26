#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Cascade args (--conf/--name) for sandboxed/embedded use
CONF_FILE=""
NAME_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_nginx.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
CONFD_DIR="/etc/nginx/conf.d"
# Writing into /etc/nginx and ufw needs root; fall back to sudo for non-root callers
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() {
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="nginx_${ts: -4}"
    fi
    sed -e "s/nginx_XXXX/${name}/g" \
        "$TPL_DIR/settings_nginx.conf.tpl" > "$CONF_FILE"
}

# Render the nginx server block into the service's own data dir (sandbox-friendly).
# Echoes the rendered file's absolute path.
render_site() {
    local site_dir="$CONF_DIR/data/${INSTANCE_NAME}_config"
    mkdir -p "$site_dir"
    # ALLOW_PREFIX contains '/', so use '#' as the sed delimiter for that one
    sed -e "s/{{LISTEN_PORT}}/${LISTEN_PORT}/g" \
        -e "s/{{SERVER_NAME}}/${SERVER_NAME}/g" \
        -e "s/{{UPSTREAM_PORT}}/${UPSTREAM_PORT}/g" \
        -e "s#{{ALLOW_PREFIX}}#${ALLOW_PREFIX}#g" \
        "$TPL_DIR/site.conf.tpl" > "$site_dir/site.conf"
    echo "$site_dir/site.conf"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_start() {
    if [ ! -f "$CONF_FILE" ]; then
        hr
        echo "[INFO] [Nginx] settings_nginx.conf not found, generating defaults..."
        generate_settings
        hr
        echo "[IMPORTANT] Review $CONF_FILE then re-run 'start':"
        echo "  - SERVER_NAME   : your domain (or _)"
        echo "  - LISTEN_PORT   : public port nginx listens on"
        echo "  - UPSTREAM_PORT : the app's host port to proxy (e.g. newapi NEWAPI_PORT)"
        echo "  - ALLOW_PREFIX  : the only public path prefix (default /v1/)"
        hr
        exit 0
    fi
    set -a; source "$CONF_FILE"; set +a

    if ! command -v nginx >/dev/null 2>&1; then
        echo "[INFO] [Nginx] nginx not installed, installing via apt-get..."
        $SUDO apt-get update -y
        $SUDO apt-get install -y nginx
    fi

    local site_file
    site_file=$(render_site)
    local link="$CONFD_DIR/${INSTANCE_NAME}.conf"

    hr
    echo "[INFO] [Nginx] Deploying gateway site '${INSTANCE_NAME}'..."
    hr
    $SUDO ln -sf "$site_file" "$link"
    if $SUDO nginx -t; then
        $SUDO systemctl reload nginx
    else
        echo "[ERROR] [Nginx] config test failed; removing the broken site link."
        $SUDO rm -f "$link"
        exit 1
    fi

    $SUDO ufw allow "${LISTEN_PORT}/tcp" || true

    hr
    echo "[SUCCESS] [Nginx] Gateway is up."
    echo "Public : http://${SERVER_NAME}:${LISTEN_PORT}${ALLOW_PREFIX} (only this prefix; others 404)"
    echo "Admin  : upstream is NOT public; reach the management UI via an SSH tunnel:"
    echo "         ssh -L ${UPSTREAM_PORT}:127.0.0.1:${UPSTREAM_PORT} <user>@<server>"
    echo "         then open http://localhost:${UPSTREAM_PORT}"
    hr
}

do_stop() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Nginx] $CONF_FILE not found. Nothing to take down."
        exit 1
    fi
    set -a; source "$CONF_FILE"; set +a

    local link="$CONFD_DIR/${INSTANCE_NAME}.conf"
    hr
    echo "[INFO] [Nginx] Taking down gateway site '${INSTANCE_NAME}'..."
    hr
    if [ -e "$link" ] || [ -L "$link" ]; then
        $SUDO rm -f "$link"
        $SUDO systemctl reload nginx || true
    fi
    $SUDO ufw delete allow "${LISTEN_PORT}/tcp" || true
    hr
    echo "[SUCCESS] [Nginx] Gateway is down (settings_nginx.conf preserved)."
    hr
}

do_help() {
    echo "Usage: $0 {start|stop} [--conf PATH] [--name NAME]"
    echo "  start : Generate settings_nginx.conf on first run; render site, link into nginx conf.d,"
    echo "          reload nginx, and 'ufw allow' the listen port"
    echo "  stop  : Remove the site from conf.d, reload nginx, and 'ufw delete allow' the port"
}

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    start) do_start ;;
    stop)  do_stop ;;
    *)     do_help ;;
esac

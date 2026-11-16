#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
shift || true

CONF_FILE=""
NAME_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --conf)
            [ $# -ge 2 ] || { echo "[ERROR] --conf requires a path." >&2; exit 2; }
            [ -n "$2" ] || { echo "[ERROR] --conf requires a non-empty path." >&2; exit 2; }
            CONF_FILE="$2"
            shift 2
            ;;
        --name)
            [ $# -ge 2 ] || { echo "[ERROR] --name requires a value." >&2; exit 2; }
            [ -n "$2" ] || { echo "[ERROR] --name requires a non-empty value." >&2; exit 2; }
            NAME_OVERRIDE="$2"
            shift 2
            ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if [ -n "$NAME_OVERRIDE" ] && [ "$COMMAND" != init ]; then
    echo "[ERROR] --name is only valid with init." >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_nginx.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd -P)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
CONFD_DIR="/etc/nginx/conf.d"
SUDO=()
[ "$(id -u)" -eq 0 ] || SUDO=(sudo)

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] $CONF_FILE not found. Run 'bash cli.sh init' first." >&2
        exit 1
    fi
}

generate_settings() {
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts
        ts="$(date +%s)"
        name="nginx_${ts: -4}"
    fi
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || {
        echo "[ERROR] --name accepts only letters, numbers, '_' and '-'." >&2
        exit 2
    }
    umask 077
    sed "s/nginx_XXXX/${name}/g" "$TPL_DIR/settings_nginx.conf.tpl" > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

load_conf() {
    require_conf
    set -a
    source "$CONF_FILE"
    set +a

    [[ "${INSTANCE_NAME:-}" =~ ^[a-zA-Z0-9_-]+$ ]] || {
        echo "[ERROR] INSTANCE_NAME contains unsupported characters." >&2
        exit 1
    }
    [[ "${SERVER_NAME:-}" =~ ^[a-zA-Z0-9._*-]+$ ]] || {
        echo "[ERROR] SERVER_NAME contains unsupported characters." >&2
        exit 1
    }
    for port in "${LISTEN_PORT:-}" "${UPSTREAM_PORT:-}"; do
        [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || {
            echo "[ERROR] Nginx ports must be between 1 and 65535." >&2
            exit 1
        }
    done
    [[ "${ALLOW_PREFIX:-}" =~ ^/[a-zA-Z0-9/_-]*/$ ]] || {
        echo "[ERROR] ALLOW_PREFIX must be a path prefix ending in '/'." >&2
        exit 1
    }

    SITE_DIR="$(realpath -m "$CONF_DIR/data/${INSTANCE_NAME}_config")"
    SITE_LINK="$CONFD_DIR/${INSTANCE_NAME}.conf"
}

render_site() {
    local site_file
    mkdir -p "$SITE_DIR"
    site_file="$(mktemp "$SITE_DIR/site.conf.XXXXXX")"
    sed -e "s/{{LISTEN_PORT}}/${LISTEN_PORT}/g" \
        -e "s/{{SERVER_NAME}}/${SERVER_NAME}/g" \
        -e "s/{{UPSTREAM_PORT}}/${UPSTREAM_PORT}/g" \
        -e "s#{{ALLOW_PREFIX}}#${ALLOW_PREFIX}#g" \
        "$TPL_DIR/site.conf.tpl" > "$site_file"
    printf '%s' "$site_file"
}

check_site_link() {
    if [ -e "$SITE_LINK" ] || [ -L "$SITE_LINK" ]; then
        if [ ! -L "$SITE_LINK" ]; then
            echo "[ERROR] Refusing to replace non-symlink site: $SITE_LINK" >&2
            return 1
        fi
        local target
        target="$(readlink -f "$SITE_LINK" 2>/dev/null || true)"
        case "$target" in
            "$SITE_DIR/site.conf"|"$SITE_DIR"/site.conf.*) ;;
            *) echo "[ERROR] Refusing to manage a site link not owned by this instance: $SITE_LINK" >&2; return 1 ;;
        esac
    fi
}

restore_site_link() {
    local old_target="$1"
    if [ -n "$old_target" ]; then
        "${SUDO[@]}" ln -sfnT "$old_target" "$SITE_LINK"
    else
        "${SUDO[@]}" rm -f "$SITE_LINK"
    fi
}

do_init() {
    if [ -n "$NAME_OVERRIDE" ] && [[ ! "$NAME_OVERRIDE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "[ERROR] --name accepts only letters, numbers, '_' and '-'." >&2
        exit 2
    fi
    if [ -n "$NAME_OVERRIDE" ] && [ -f "$CONF_FILE" ]; then
        echo "[ERROR] --name only applies when init creates a new settings file." >&2
        exit 2
    fi
    if [ ! -f "$CONF_FILE" ]; then
        generate_settings
    fi
    echo "[SUCCESS] Nginx settings initialized at $CONF_FILE."
}

do_install() {
    if ! command -v nginx >/dev/null 2>&1; then
        "${SUDO[@]}" apt-get update -y
        "${SUDO[@]}" apt-get install -y nginx
    fi
    echo "[SUCCESS] Nginx installed. Run 'bash cli.sh init' to create settings."
}

do_start() {
    load_conf
    command -v nginx >/dev/null 2>&1 || { echo "[ERROR] Nginx is missing. Run 'bash cli.sh install'." >&2; exit 1; }
    check_site_link

    local site_file old_target=""
    site_file="$(render_site)"
    if [ -L "$SITE_LINK" ]; then
        old_target="$(readlink -f "$SITE_LINK")"
    fi

    "${SUDO[@]}" ln -sfnT "$site_file" "$SITE_LINK"
    if ! "${SUDO[@]}" nginx -t; then
        restore_site_link "$old_target"
        rm -f "$site_file"
        exit 1
    fi
    if ! "${SUDO[@]}" systemctl reload nginx; then
        restore_site_link "$old_target"
        "${SUDO[@]}" nginx -t && "${SUDO[@]}" systemctl reload nginx || true
        rm -f "$site_file"
        exit 1
    fi

    if [ -n "$old_target" ] && [ "$old_target" != "$site_file" ]; then
        rm -f "$old_target"
    fi
    echo "[SUCCESS] Gateway '$INSTANCE_NAME' started at http://${SERVER_NAME}:${LISTEN_PORT}${ALLOW_PREFIX}."
    echo "[INFO] Firewall rules are managed separately; this tool does not change UFW rules."
}

do_stop() {
    load_conf
    check_site_link
    if [ -L "$SITE_LINK" ]; then
        "${SUDO[@]}" rm -f "$SITE_LINK"
        "${SUDO[@]}" systemctl reload nginx
    fi
    echo "[SUCCESS] Gateway '$INSTANCE_NAME' stopped; settings preserved."
}

do_rm() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[INFO] No instance configuration found."
        return 0
    fi
    load_conf
    check_site_link
    if [ -L "$SITE_LINK" ]; then
        "${SUDO[@]}" rm -f "$SITE_LINK"
        "${SUDO[@]}" systemctl reload nginx
    fi
    rm -f "$SITE_DIR/site.conf" "$SITE_DIR"/site.conf.* "$CONF_FILE"
    echo "[SUCCESS] Instance settings and generated site configuration removed; Nginx package preserved."
}

do_help() {
    echo "Usage: $0 {init|install|start|stop|rm} [--conf PATH] [--name NAME]"
    echo "  init    : Create missing instance settings."
    echo "  install : Install Nginx."
    echo "  start   : Render, validate and enable this instance's site."
    echo "  stop    : Disable this instance's site and preserve settings."
    echo "  rm      : Stop and remove this instance's settings and generated site config."
    echo "  --conf  : Settings path (default: <script_dir>/settings_nginx.conf)."
    echo "  --name  : Instance name used when init creates settings."
}

case "$COMMAND" in
    init)    do_init ;;
    install) do_install ;;
    start)   do_start ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    help|-h|--help) do_help ;;
    *) echo "[ERROR] Unknown command: $COMMAND" >&2; do_help; exit 2 ;;
esac

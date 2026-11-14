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

if [ -n "$NAME_OVERRIDE" ] && [ "$COMMAND" != install ]; then
    echo "[ERROR] --name is only valid with install." >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings_codeserver.conf}"
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd -P)"
CONF_FILE="$CONF_DIR/$(basename "$CONF_FILE")"
SUDO=()
[ "$(id -u)" -eq 0 ] || SUDO=(sudo)

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] $CONF_FILE not found. Run 'bash cli.sh install' first." >&2
        exit 1
    fi
}

load_conf() {
    require_conf
    set -a
    source "$CONF_FILE"
    set +a

    if [[ ! "${SESSION_NAME:-}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "[ERROR] SESSION_NAME contains unsupported characters." >&2
        exit 1
    fi

    for dir_name in "${CONFIG_DIR:-}" "${USER_DATA_DIR:-}"; do
        case "$dir_name" in
            ""|.|./|/*|..|../*|*/..|*/../*)
                echo "[ERROR] CONFIG_DIR and USER_DATA_DIR must stay inside the settings directory." >&2
                exit 1
                ;;
        esac
    done

    CONFIG_PATH="$(realpath -m "$CONF_DIR/${CONFIG_DIR#./}")"
    USER_DATA_PATH="$(realpath -m "$CONF_DIR/${USER_DATA_DIR#./}")"
    case "$CONFIG_PATH" in "$CONF_DIR"/*) ;; *) echo "[ERROR] CONFIG_DIR resolves outside the settings directory." >&2; exit 1 ;; esac
    case "$USER_DATA_PATH" in "$CONF_DIR"/*) ;; *) echo "[ERROR] USER_DATA_DIR resolves outside the settings directory." >&2; exit 1 ;; esac
    case "$CONFIG_PATH/" in "$USER_DATA_PATH/"*) echo "[ERROR] CONFIG_DIR and USER_DATA_DIR must not overlap." >&2; exit 1 ;; esac
    case "$USER_DATA_PATH/" in "$CONFIG_PATH/"*) echo "[ERROR] CONFIG_DIR and USER_DATA_DIR must not overlap." >&2; exit 1 ;; esac

    if [[ ! "${PORT:-}" =~ ^[0-9]{1,5}$ ]] || ((10#$PORT < 1 || 10#$PORT > 65535)); then
        echo "[ERROR] PORT must be between 1 and 65535." >&2
        exit 1
    fi
    [[ "${HOST:-}" =~ ^[a-zA-Z0-9:._-]+$ ]] || {
        echo "[ERROR] HOST contains unsupported characters." >&2
        exit 1
    }
}

generate_settings() {
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts
        ts="$(date +%s)"
        name="codeserver_${ts: -4}"
    fi
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || {
        echo "[ERROR] --name accepts only letters, numbers, '_' and '-'." >&2
        exit 2
    }

    umask 077
    sed -e "s/codeserver_XXXX/${name}/g" \
        -e "s/{{PASSWORD}}/$(openssl rand -hex 16)/g" \
        "$TPL_DIR/settings_codeserver.conf.tpl" > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

generate_yaml() {
    umask 077
    sed -e "s/{{HOST}}/${HOST}/g" \
        -e "s/{{PORT}}/${PORT}/g" \
        -e "s/{{PASSWORD}}/${PASSWORD}/g" \
        "$TPL_DIR/config.yaml.tpl" > "$CONFIG_PATH/config.yaml"
    chmod 600 "$CONFIG_PATH/config.yaml"
}

do_install() {
    if [ -n "$NAME_OVERRIDE" ] && [ -f "$CONF_FILE" ]; then
        echo "[ERROR] --name only applies when install creates a new settings file." >&2
        exit 2
    fi
    if [ ! -f "$CONF_FILE" ]; then
        generate_settings
    fi
    load_conf
    chmod 600 "$CONF_FILE"

    if ! command -v tmux >/dev/null 2>&1 || ! command -v code-server >/dev/null 2>&1; then
        "${SUDO[@]}" apt-get update -y
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        "${SUDO[@]}" apt-get install -y tmux
    fi
    if ! command -v code-server >/dev/null 2>&1; then
        curl -fsSL https://code-server.dev/install.sh | sh
    fi

    mkdir -p "$CONFIG_PATH" "$USER_DATA_PATH"
    echo "[SUCCESS] Code-Server installed. Review $CONF_FILE, then run 'bash cli.sh start'."
}

do_start() {
    load_conf
    command -v tmux >/dev/null 2>&1 || { echo "[ERROR] tmux is missing. Run 'bash cli.sh install'." >&2; exit 1; }
    command -v code-server >/dev/null 2>&1 || { echo "[ERROR] code-server is missing. Run 'bash cli.sh install'." >&2; exit 1; }

    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "[INFO] Session '$SESSION_NAME' is already running."
        return 0
    fi

    mkdir -p "$CONFIG_PATH" "$USER_DATA_PATH"
    generate_yaml
    local command
    printf -v command 'code-server --config %q --user-data-dir %q' \
        "$CONFIG_PATH/config.yaml" "$USER_DATA_PATH"
    tmux new-session -d -s "$SESSION_NAME" "$command"
    echo "[SUCCESS] Code-Server started at http://${HOST}:${PORT}."
}

do_stop() {
    load_conf
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        tmux kill-session -t "$SESSION_NAME"
        echo "[SUCCESS] Session '$SESSION_NAME' stopped."
    else
        echo "[INFO] Session '$SESSION_NAME' is not running."
    fi
}

do_rm() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[INFO] No instance configuration found."
        return 0
    fi
    load_conf
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        tmux kill-session -t "$SESSION_NAME"
    fi
    rm -f "$CONFIG_PATH/config.yaml" "$CONF_FILE"
    echo "[SUCCESS] Instance settings and generated config removed; user data and software preserved."
}

do_help() {
    echo "Usage: $0 {install|start|stop|rm} [--conf PATH] [--name NAME]"
    echo "  install : Install code-server and tmux; create missing instance settings."
    echo "  start   : Start the configured tmux session."
    echo "  stop    : Stop the configured tmux session."
    echo "  rm      : Stop and remove this instance's settings and generated config.yaml."
    echo "  --conf  : Settings path (default: <script_dir>/settings_codeserver.conf)."
    echo "  --name  : Instance name used when install creates settings."
}

case "$COMMAND" in
    install) do_install ;;
    start)   do_start ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    help|-h|--help) do_help ;;
    *) echo "[ERROR] Unknown command: $COMMAND" >&2; do_help; exit 2 ;;
esac

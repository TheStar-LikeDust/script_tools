#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Cascade args (--conf/--name) plus any command-specific extras
CONF_FILE=""
NAME_OVERRIDE=""
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --conf) CONF_FILE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# Anchor paths to this script's own location so it works from any cwd and survives moves
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/templates"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/settings.conf}"
# Config + data live together; data dir is derived from the config file's directory at runtime
CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }

require_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "[ERROR] [Code-Server] $CONF_FILE not found. Run 'bash cli.sh init' first."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Service Config Rendering
# -----------------------------------------------------------------------------
generate_settings() {
    local pass=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)
    local name="$NAME_OVERRIDE"
    if [ -z "$name" ]; then
        local ts=$(date +%s)
        name="codeserver_${ts: -4}"
    fi

    sed -e "s/codeserver_XXXX/${name}/g" \
        -e "s/{{PASSWORD}}/${pass}/g" \
        "$TPL_DIR/settings.conf.tpl" > "$CONF_FILE"
}

generate_yaml() {
    local abs_config_dir="${CONF_DIR}/${CONFIG_DIR#./}"
    mkdir -p "$abs_config_dir"
    
    echo "Generating config.yaml..."
    sed -e "s/{{HOST}}/${HOST:-127.0.0.1}/g" \
        -e "s/{{PORT}}/${PORT:-8080}/g" \
        -e "s/{{PASSWORD}}/${PASSWORD}/g" \
        "$TPL_DIR/config.yaml.tpl" > "$abs_config_dir/config.yaml"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    hr
    echo "[INFO] [Code-Server] Initializing configuration..."
    hr

    if [ ! -f "$CONF_FILE" ]; then
        generate_settings
    fi
    source "$CONF_FILE"

    # Pre-create the data dir
    local abs_config_dir="${CONF_DIR}/${CONFIG_DIR#./}"
    local abs_user_data_dir="${CONF_DIR}/${USER_DATA_DIR#./}"
    mkdir -p "$abs_config_dir" "$abs_user_data_dir"

    # Install code-server if missing
    if ! command -v code-server &> /dev/null; then
        echo "[INFO] code-server is not installed. Running official installation script..."
        curl -fsSL https://code-server.dev/install.sh | sh
    fi

    hr
    echo "[SUCCESS] [Code-Server] Initialization completed!"
    hr
    echo "[IMPORTANT] Recommended next steps:"
    echo "  1. Review settings.conf (port / credentials)"
    echo "  2. Run 'bash cli.sh start' to start code-server in background via tmux"
    hr
}

do_start() {
    require_conf
    set -a; source "$CONF_FILE"; set +a

    if ! command -v tmux &> /dev/null; then
        echo "[ERROR] tmux is not installed. Please install tmux first."
        exit 1
    fi
    
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "[INFO] [Code-Server] Session '${SESSION_NAME}' already exists, skipping start."
        echo "Use 'tmux attach -t $SESSION_NAME' to view it."
        return 0
    fi

    local abs_config_dir="${CONF_DIR}/${CONFIG_DIR#./}"
    local abs_user_data_dir="${CONF_DIR}/${USER_DATA_DIR#./}"
    
    mkdir -p "$abs_config_dir" "$abs_user_data_dir"
    
    # Generate config.yaml based on settings.conf
    generate_yaml
    
    hr
    echo "[INFO] [Code-Server] Starting service in Tmux (Session: ${SESSION_NAME})..."
    hr

    # Start code-server in tmux session
    tmux new-session -d -s "$SESSION_NAME" "code-server --config \"$abs_config_dir/config.yaml\" --user-data-dir \"$abs_user_data_dir\""
    
    hr
    echo "[SUCCESS] [Code-Server] Service is up and running in background!"
    echo "Access URL: http://${HOST:-127.0.0.1}:$PORT"
    echo "Password  : $PASSWORD"
    echo "To view logs: tmux attach -t $SESSION_NAME"
    hr
}

do_stop() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[INFO] [Code-Server] Stopping service..."
    hr

    if ! command -v tmux &> /dev/null; then
        return 0
    fi

    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        tmux kill-session -t "$SESSION_NAME"
    fi
}

do_rm() {
    do_stop
}

do_purge() {
    require_conf
    source "$CONF_FILE"
    hr
    echo "[WARN] WARNING: Preparing to completely destroy Code-Server data!"
    hr
    
    do_stop

    # Clean up local data directory but preserve configs
    local abs_config_dir="${CONF_DIR}/${CONFIG_DIR#./}"
    local abs_user_data_dir="${CONF_DIR}/${USER_DATA_DIR#./}"
    
    if [ -d "$abs_config_dir" ] || [ -d "$abs_user_data_dir" ]; then
        echo "Removing local data directory..."
        # Host-level tool: data is owned by the current user, plain rm is enough.
        # Do not silence errors so a failed delete is not reported as success.
        rm -rf "$abs_config_dir"
        rm -rf "$abs_user_data_dir"
    fi

    hr
    echo "[SUCCESS] [Code-Server] Data has been purged (configs preserved)."
    hr
}

do_help() {
    echo "Usage: $0 {init|start|up|stop|rm|purge} [--conf PATH] [--name NAME]"
    echo "  init    : Generate settings.conf and config.yaml, install code-server if absent"
    echo "  start   : Start code-server in the background using tmux"
    echo "  up      : Initialize config and start the service instantly"
    echo "  stop    : Stop the running tmux session"
    echo "  rm      : Equivalent to stop for host-level tools"
    echo "  purge   : DANGER - Stop session AND permanently delete ./data (Preserves settings.conf)"
    echo ""
    echo "Options (for embedding as a sub-service under another app):"
    echo "  --conf PATH : Config file location (default: <script_dir>/settings.conf)."
    echo "                Data dir is derived as <dir-of-conf>/data/..."
    echo "  --name NAME : Full session name to write at init (default: auto 'codeserver_<ts>')."
}

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    init)    do_init ;;
    start)   do_start ;;
    up)      do_init && do_start ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    purge)   do_purge ;;
    *)       do_help ;;
esac

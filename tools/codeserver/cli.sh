#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Determine the directory of the current script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Default paths
SETTINGS_FILE="${SCRIPT_DIR}/settings.conf"
TEMPLATE_FILE="${SCRIPT_DIR}/templates/settings.conf.tpl"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }

print_banner() {
    hr
    echo "$1"
    hr
}

require_conf() {
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "Error: settings.conf not found. Please run 'bash cli.sh init' first."
        exit 1
    fi
}

load_settings() {
    require_conf
    source "$SETTINGS_FILE"
}

# -----------------------------------------------------------------------------
# 3. Special / Business Functions
# -----------------------------------------------------------------------------
generate_settings() {
    # Generate 4-digit timestamp suffix
    local ts=$(date +%s)
    local suffix=${ts: -4}
    local password=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
    
    # Replace templates and create settings.conf
    sed -e "s/codeserver_XXXX/codeserver_${suffix}/" \
        -e "s/{{PASSWORD}}/${password}/" \
        "$TEMPLATE_FILE" > "$SETTINGS_FILE"

    # Load settings to generate config.yaml
    source "$SETTINGS_FILE"
    local abs_config_dir="${SCRIPT_DIR}/${CONFIG_DIR#./}"
    mkdir -p "$abs_config_dir"
    
    echo "Generating config.yaml..."
    sed -e "s/{{HOST}}/${HOST:-127.0.0.1}/" \
        -e "s/{{PORT}}/${PORT:-8080}/" \
        -e "s/{{PASSWORD}}/${PASSWORD}/" \
        "${SCRIPT_DIR}/templates/config.yaml.tpl" > "$abs_config_dir/config.yaml"
}

# -----------------------------------------------------------------------------
# 4. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_init() {
    print_banner "Initializing code-server configuration"
    
    if [ -f "$SETTINGS_FILE" ]; then
        echo "Warning: settings.conf already exists. Skipping initialization."
        echo "If you want to re-init, please delete it manually."
        return 0
    fi

    echo "Generating settings.conf from template..."
    generate_settings

    echo "Initialization complete."
    echo ""
    echo "Next steps:"
    echo "1. Run 'bash cli.sh install' to install code-server if not already installed."
    echo "2. Check and modify settings.conf if needed."
    echo "3. Run 'bash cli.sh run' to run code-server in the foreground."
    echo "4. Or run 'bash cli.sh start' to start a background tmux session."
}

do_install() {
    print_banner "Installing code-server"
    echo "Running code-server official installation script..."
    curl -fsSL https://code-server.dev/install.sh | sh
    echo "Installation complete."
}

do_run() {
    print_banner "Running code-server (Foreground)"
    load_settings
    
    # Resolve absolute paths based on the script directory
    ABS_CONFIG_DIR="${SCRIPT_DIR}/${CONFIG_DIR#./}"
    ABS_USER_DATA_DIR="${SCRIPT_DIR}/${USER_DATA_DIR#./}"
    
    mkdir -p "$ABS_CONFIG_DIR"
    mkdir -p "$ABS_USER_DATA_DIR"
    
    echo "Starting code-server..."
    echo "Config: $ABS_CONFIG_DIR/config.yaml"
    echo "User Data: $ABS_USER_DATA_DIR"
    echo "Address: ${HOST:-127.0.0.1}:$PORT"
    echo "Password: $PASSWORD"
    echo ""
    code-server --config "$ABS_CONFIG_DIR/config.yaml" --user-data-dir "$ABS_USER_DATA_DIR"
}

do_start() {
    print_banner "Starting code-server in Tmux (Background)"
    load_settings
    
    if ! command -v tmux &> /dev/null; then
        echo "Error: tmux is not installed. Please install tmux first."
        exit 1
    fi
    
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Warning: code-server session '$SESSION_NAME' is already running."
        echo "Use 'tmux attach -t $SESSION_NAME' to view it."
        return 0
    fi
    
    # Resolve absolute paths based on the script directory
    ABS_CONFIG_DIR="${SCRIPT_DIR}/${CONFIG_DIR#./}"
    ABS_USER_DATA_DIR="${SCRIPT_DIR}/${USER_DATA_DIR#./}"
    
    mkdir -p "$ABS_CONFIG_DIR"
    mkdir -p "$ABS_USER_DATA_DIR"
    
    echo "Starting code-server in tmux session: $SESSION_NAME"
    tmux new-session -d -s "$SESSION_NAME" "code-server --config \"$ABS_CONFIG_DIR/config.yaml\" --user-data-dir \"$ABS_USER_DATA_DIR\""
    
    hr
    echo "[SUCCESS] Background session started successfully."
    echo "Access URL: http://${HOST:-127.0.0.1}:$PORT"
    echo "Password  : $PASSWORD"
    echo "To view logs: tmux attach -t $SESSION_NAME"
    hr
}

do_stop() {
    print_banner "Stopping code-server (Tmux session)"
    load_settings
    
    if ! command -v tmux &> /dev/null; then
        echo "Error: tmux is not installed."
        exit 1
    fi

    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Killing tmux session '$SESSION_NAME'..."
        tmux kill-session -t "$SESSION_NAME"
        echo "Session stopped."
    else
        echo "No running tmux session found for '$SESSION_NAME'."
    fi
}

do_status() {
    print_banner "Status code-server"
    load_settings
    
    if ! command -v tmux &> /dev/null; then
        echo "tmux is not installed."
        exit 1
    fi
    
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Status: RUNNING"
        echo "Tmux session: $SESSION_NAME"
    else
        echo "Status: STOPPED"
    fi
}

do_purge() {
    print_banner "Purging code-server data"
    
    hr
    echo "[WARN] WARNING: Preparing to completely destroy code-server data!"
    hr
    
    do_stop
    
    if [ -f "$SETTINGS_FILE" ]; then
        source "$SETTINGS_FILE"
        local abs_config_dir="${SCRIPT_DIR}/${CONFIG_DIR#./}"
        local abs_user_data_dir="${SCRIPT_DIR}/${USER_DATA_DIR#./}"
        
        # Clean up local data directory but preserve settings.conf
        echo "Removing local data directories..."
        rm -rf "$abs_config_dir" 2>/dev/null || true
        rm -rf "$abs_user_data_dir" 2>/dev/null || true
        
        hr
        echo "[SUCCESS] code-server data has been purged (settings.conf preserved)."
        hr
    else
        echo "settings.conf not found. No data to purge based on configuration."
    fi
}

do_help() {
    echo "Usage: $0 {init|install|run|start|stop|purge|status}"
    echo "  init    : Generate configuration file (settings.conf)"
    echo "  install : Install code-server using official script"
    echo "  run     : Start code-server directly in the foreground (blocking)"
    echo "  start   : Start code-server in the background using tmux"
    echo "  stop    : Stop the background tmux session"
    echo "  purge   : DANGER - Permanently delete ./data (Preserves settings.conf)"
    echo "  status  : Check the status of the background tmux session"
}

# -----------------------------------------------------------------------------
# 5. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    init)    do_init ;;
    install) do_install ;;
    run)     do_run ;;
    start)   do_start ;;
    stop)    do_stop ;;
    purge)   do_purge ;;
    status)  do_status ;;
    *)       do_help ;;
esac

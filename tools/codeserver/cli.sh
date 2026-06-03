#!/usr/bin/env bash

# codeserver cli tool

# Determine the directory of the current script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Default paths
SETTINGS_FILE="${SCRIPT_DIR}/settings.conf"
TEMPLATE_FILE="${SCRIPT_DIR}/templates/settings.conf.tpl"

# ======================================================================
# Helper Functions
# ======================================================================

print_banner() {
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

check_settings() {
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "Error: settings.conf not found. Please run 'bash cli.sh init' first."
        exit 1
    fi
}

load_settings() {
    check_settings
    source "$SETTINGS_FILE"
}

# ======================================================================
# Command Implementations
# ======================================================================

cmd_init() {
    print_banner "Initializing code-server configuration"
    
    if [ -f "$SETTINGS_FILE" ]; then
        echo "Warning: settings.conf already exists. Skipping initialization."
        echo "If you want to re-init, please delete it manually."
        return 0
    fi

    echo "Generating settings.conf from template..."
    
    # Generate 4-digit timestamp suffix
    local ts=$(date +%s)
    local suffix=${ts: -4}
    
    # Replace XXXX with the timestamp suffix and create settings.conf
    sed "s/codeserver_XXXX/codeserver_${suffix}/" "$TEMPLATE_FILE" > "$SETTINGS_FILE"

    echo "Initialization complete."
    echo ""
    echo "Next steps:"
    echo "1. Run 'bash cli.sh install' to install code-server if not already installed."
    echo "2. Check and modify settings.conf if needed."
    echo "3. Run 'bash cli.sh run' to run code-server in the foreground."
    echo "4. Or run 'bash cli.sh stop' to stop a background tmux session."
}

cmd_install() {
    print_banner "Installing code-server"
    echo "Running code-server official installation script..."
    curl -fsSL https://code-server.dev/install.sh | sh
    echo "Installation complete."
}

cmd_run() {
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
    echo "Port: $PORT"
    echo ""
    code-server --bind-addr "0.0.0.0:$PORT" --config "$ABS_CONFIG_DIR/config.yaml" --user-data-dir "$ABS_USER_DATA_DIR"
}

cmd_start() {
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
    echo "Port: $PORT"
    tmux new-session -d -s "$SESSION_NAME" "code-server --bind-addr \"0.0.0.0:$PORT\" --config \"$ABS_CONFIG_DIR/config.yaml\" --user-data-dir \"$ABS_USER_DATA_DIR\""
    
    echo "Background session started successfully."
    echo "To view logs, use: tmux attach -t $SESSION_NAME"
}


cmd_stop() {
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

cmd_status() {
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

# ======================================================================
# Main CLI Router
# ======================================================================

case "$1" in
    init)
        cmd_init
        ;;
    install)
        cmd_install
        ;;
    run)
        cmd_run
        ;;
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    *)
        echo "Usage: $0 {init|install|run|start|stop|status}"
        echo "  init    : Generate configuration file"
        echo "  install : Install code-server using official script"
        echo "  run     : Start code-server directly in the foreground (blocking)"
        echo "  start   : Start code-server in the background using tmux"
        echo "  stop    : Stop the background tmux session"
        echo "  status  : Check the status of the background tmux session"
        exit 1
        ;;
esac

#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization & Path Anchoring
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UFW_DOCKER_BIN="/usr/local/bin/ufw-docker"
UFW_DOCKER_URL="https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker"
AFTER_RULES="/etc/ufw/after.rules"
# Host-global firewall changes need root; fall back to sudo for non-root callers
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }

# ufw-docker writes a marked block into after.rules; presence == applied
ufw_docker_applied() { grep -q "BEGIN UFW AND DOCKER" "$AFTER_RULES" 2>/dev/null; }

# -----------------------------------------------------------------------------
# 3. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_start() {
    hr
    echo "[INFO] [Docker-Setup] Applying host docker config (ufw-docker)..."
    hr

    if ! command -v ufw >/dev/null 2>&1; then
        echo "[ERROR] [Docker-Setup] ufw is not installed. Install ufw first, then retry."
        exit 1
    fi

    if [ ! -x "$UFW_DOCKER_BIN" ]; then
        echo "[INFO] [Docker-Setup] Downloading ufw-docker..."
        $SUDO wget -O "$UFW_DOCKER_BIN" "$UFW_DOCKER_URL"
        $SUDO chmod +x "$UFW_DOCKER_BIN"
    fi

    if ufw_docker_applied; then
        echo "[INFO] [Docker-Setup] ufw-docker already applied, skipping."
    else
        $SUDO "$UFW_DOCKER_BIN" install
        $SUDO systemctl restart ufw
    fi

    hr
    echo "[SUCCESS] [Docker-Setup] ufw-docker active. UFW now governs docker published ports."
    echo "[WARN] Host-global effect: docker '-p' ports are blocked from public unless"
    echo "       explicitly allowed via 'ufw-docker allow <container> <port>'."
    hr
}

do_stop() {
    hr
    echo "[INFO] [Docker-Setup] Reverting host docker config (ufw-docker)..."
    hr

    if ufw_docker_applied; then
        # Remove the marked block ufw-docker injected, then reload firewall
        $SUDO sed -i '/# BEGIN UFW AND DOCKER/,/# END UFW AND DOCKER/d' "$AFTER_RULES"
        $SUDO systemctl restart ufw
        echo "[SUCCESS] [Docker-Setup] ufw-docker rules removed (binary kept at $UFW_DOCKER_BIN)."
    else
        echo "[INFO] [Docker-Setup] ufw-docker not applied, nothing to revert."
    fi
    hr
}

do_help() {
    echo "Usage: $0 {start|stop}"
    echo "  start : Install & enable ufw-docker (host-global; UFW governs docker published ports)"
    echo "  stop  : Remove the ufw-docker block from UFW after.rules (revert)"
}

# -----------------------------------------------------------------------------
# 4. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    start) do_start ;;
    stop)  do_stop ;;
    *)     do_help ;;
esac

#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# script_tools bootstrap installation script
# Purpose: Download the latest Release/Branch tarball and extract to workspace
# ==============================================================================

# TODO: MUST change repository address and version before release!
# Replace this with your actual GitHub repo (e.g., logic/script_tools)
GITHUB_REPO="YourName/YourRepo"
# Can be a release tag (e.g., v1.0.0) or branch name (e.g., main)
VERSION="main"
TARGET_DIR="script_tools"

command_exists() { command -v "$1" >/dev/null 2>&1; }

check_env() {
    echo "======================================================================"
    echo "[INFO] Checking system environment..."
    echo "======================================================================"
    if ! command_exists curl; then echo "[ERROR] Please install curl to pull the deployment package."; exit 1; fi
    if ! command_exists tar; then echo "[ERROR] Please install tar to extract the deployment package."; exit 1; fi
    if ! command_exists docker; then echo "[ERROR] Docker not found. Please install Docker first."; exit 1; fi
}

bootstrap_workspace() {
    echo "======================================================================"
    echo "[INFO] Fetching deployment tools version: $VERSION from GitHub..."
    echo "======================================================================"
    
    local tarball_url="https://github.com/${GITHUB_REPO}/archive/refs/heads/${VERSION}.tar.gz"

    mkdir -p "$TARGET_DIR"
    
    echo "[INFO] Downloading and extracting..."
    curl -fsSL "$tarball_url" | tar -xz -C "$TARGET_DIR" --strip-components=1

    echo "======================================================================"
    echo "[SUCCESS] Deployment tools are ready at: ${TARGET_DIR}/"
    echo "Please enter the workspace and start services following README.md:"
    echo ""
    echo "  cd ${TARGET_DIR}"
    echo "  # Example: Start a standalone ParadeDB:"
    echo "  cd deploy_services/paradedb && bash cli.sh init"
    echo "======================================================================"
}

case "${1:-}" in
    help)
        echo "Usage: bash <(curl -fsSL https://raw.githubusercontent.com/.../install.sh)"
        ;;
    *)
        check_env
        bootstrap_workspace
        ;;
esac

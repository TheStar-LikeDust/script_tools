#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Initialization
# -----------------------------------------------------------------------------
COMMAND=${1:-help}
shift || true

# Installing packages, writing certificates and binding port 80 need root.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# -----------------------------------------------------------------------------
# 2. Utility Functions
# -----------------------------------------------------------------------------
hr() { echo "-----------------------------------------------------------------------------"; }

normalize_domain() {
    local domain="${1#*://}"
    domain="${domain%%/*}"
    domain="${domain%%\?*}"
    domain="${domain%%#*}"
    domain="${domain%%:*}"
    printf '%s' "${domain,,}"
}

# -----------------------------------------------------------------------------
# 3. Lifecycle Functions (do_xxx)
# -----------------------------------------------------------------------------
do_start() {
    # 1. Read the domain from the supplied domain or URL.
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 start <domain-or-url>" >&2
        exit 2
    fi

    local domain
    domain=$(normalize_domain "$1")
    if [ -z "$domain" ]; then
        echo "[ERROR] A domain name is required." >&2
        exit 2
    fi

    # 2. Install Certbot if missing.
    hr
    echo "[INFO] [Certbot] Preparing certificate for ${domain}..."
    hr

    if ! command -v certbot >/dev/null 2>&1; then
        echo "[INFO] [Certbot] certbot not installed, installing via apt-get..."
        $SUDO apt-get update -y
        $SUDO apt-get install -y certbot
    fi

    # 3. Obtain or renew the certificate, keeping it when renewal is not due.
    $SUDO certbot certonly \
        --standalone \
        --preferred-challenges http \
        --server https://acme-v02.api.letsencrypt.org/directory \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --keep-until-expiring \
        --cert-name "$domain" \
        -d "$domain"

    # 4. Show the files to use in the HTTPS service.
    hr
    echo "[SUCCESS] [Certbot] Certificate is ready."
    echo "Certificate : /etc/letsencrypt/live/${domain}/fullchain.pem"
    echo "Private key : /etc/letsencrypt/live/${domain}/privkey.pem"
    hr
}

do_help() {
    echo "Usage: $0 start <domain-or-url>"
    echo "  start : Install Certbot if missing, then obtain or renew a Let's Encrypt certificate"
    echo "  Requires: apt-get for installation, root or sudo, and a publicly reachable free TCP port 80"
}

# -----------------------------------------------------------------------------
# 4. Command Dispatch
# -----------------------------------------------------------------------------
case "$COMMAND" in
    start) do_start "$@" ;;
    help|-h|--help) do_help ;;
    *) do_help; exit 2 ;;
esac

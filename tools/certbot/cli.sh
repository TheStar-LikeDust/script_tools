#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
shift || true

SUDO=()
[ "$(id -u)" -eq 0 ] || SUDO=(sudo)

normalize_domain() {
    local domain="${1#*://}"
    domain="${domain%%/*}"
    domain="${domain%%\?*}"
    domain="${domain%%#*}"
    domain="${domain%%:*}"
    printf '%s' "${domain,,}"
}

do_install() {
    if ! command -v certbot >/dev/null 2>&1; then
        "${SUDO[@]}" apt-get update -y
        "${SUDO[@]}" apt-get install -y certbot
    fi
    echo "[SUCCESS] Certbot is installed. Run 'bash cli.sh start <domain-or-url>' to request or renew a certificate."
}

do_start() {
    [ "$#" -eq 1 ] || { echo "Usage: $0 start <domain-or-url>" >&2; exit 2; }
    command -v certbot >/dev/null 2>&1 || { echo "[ERROR] Certbot is missing. Run 'bash cli.sh install'." >&2; exit 1; }

    local domain
    domain="$(normalize_domain "$1")"
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || {
        echo "[ERROR] A valid fully-qualified domain name is required." >&2
        exit 2
    }

    echo "[INFO] Requesting or renewing certificate for $domain..."
    "${SUDO[@]}" certbot certonly \
        --standalone \
        --preferred-challenges http \
        --server https://acme-v02.api.letsencrypt.org/directory \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --keep-until-expiring \
        --cert-name "$domain" \
        -d "$domain"

    echo "[SUCCESS] Certificate is ready."
    echo "Certificate : /etc/letsencrypt/live/${domain}/fullchain.pem"
    echo "Private key : /etc/letsencrypt/live/${domain}/privkey.pem"
}

do_help() {
    echo "Usage: $0 {install|start <domain-or-url>}"
    echo "  install : Install Certbot."
    echo "  start   : Request or renew a certificate; Certbot is a one-shot tool, not a running service."
    echo "  HTTP-01 requires a publicly reachable TCP port 80 that is not occupied during validation."
}

case "$COMMAND" in
    install) [ $# -eq 0 ] || { echo "[ERROR] install accepts no arguments." >&2; exit 2; }; do_install ;;
    start) do_start "$@" ;;
    help|-h|--help) [ $# -eq 0 ] || { echo "[ERROR] Help accepts no arguments." >&2; exit 2; }; do_help ;;
    *) echo "[ERROR] Unknown command: $COMMAND" >&2; do_help; exit 2 ;;
esac

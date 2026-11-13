#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
shift || true

normalize_domain() {
    local domain="${1#*://}"
    domain="${domain%%/*}"
    domain="${domain%%\?*}"
    domain="${domain%%#*}"
    domain="${domain%%:*}"
    printf '%s' "${domain,,}"
}

do_issue() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 issue <domain-or-url>" >&2
        exit 2
    fi

    local domain
    domain=$(normalize_domain "$1")
    if [ -z "$domain" ]; then
        echo "[ERROR] A domain name is required." >&2
        exit 2
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        echo "[ERROR] certbot is not installed. Install it with your system package manager first." >&2
        exit 1
    fi

    certbot certonly \
        --standalone \
        --preferred-challenges http \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$domain"

    echo "[SUCCESS] Certificate : /etc/letsencrypt/live/${domain}/fullchain.pem"
    echo "[SUCCESS] Private key : /etc/letsencrypt/live/${domain}/privkey.pem"
}

do_help() {
    echo "Usage: $0 issue <domain-or-url>"
    echo "  issue : Obtain a Let's Encrypt certificate using HTTP-01 on port 80"
}

case "$COMMAND" in
    issue) do_issue "$@" ;;
    help|-h|--help) do_help ;;
    *) do_help; exit 2 ;;
esac

#!/usr/bin/env bash
set -euo pipefail

COMMAND=${1:-help}
shift || true
[ $# -eq 0 ] || { echo "[ERROR] This tool accepts no options." >&2; exit 2; }

AFTER_RULES="/etc/ufw/after.rules"
CHAIN="SCRIPT-TOOLS-UFW-DOCKER"
MARKER_BEGIN="# BEGIN SCRIPT_TOOLS UFW DOCKER"
MARKER_END="# END SCRIPT_TOOLS UFW DOCKER"
SUDO=()
[ "$(id -u)" -eq 0 ] || SUDO=(sudo)

require_firewall() {
    command -v ufw >/dev/null 2>&1 || { echo "[ERROR] UFW is missing. Run 'bash cli.sh install'." >&2; exit 1; }
    command -v iptables >/dev/null 2>&1 || { echo "[ERROR] iptables is missing." >&2; exit 1; }
    command -v docker >/dev/null 2>&1 || { echo "[ERROR] Docker is missing." >&2; exit 1; }
    "${SUDO[@]}" ufw status | grep -q '^Status: active$' || {
        echo "[ERROR] UFW must already be active. Enable it after reviewing SSH access." >&2
        exit 1
    }
    docker info >/dev/null 2>&1 || { echo "[ERROR] Docker must be running and accessible." >&2; exit 1; }
    "${SUDO[@]}" iptables -nL DOCKER-USER >/dev/null 2>&1 || {
        echo "[ERROR] Docker's DOCKER-USER chain is unavailable; check the Docker firewall backend." >&2
        exit 1
    }
    "${SUDO[@]}" iptables -nL ufw-user-forward >/dev/null 2>&1 || {
        echo "[ERROR] UFW's forward chain is unavailable." >&2
        exit 1
    }
}

block_state() {
    local begin_count end_count
    begin_count="$(grep -Fxc "$MARKER_BEGIN" "$AFTER_RULES" || true)"
    end_count="$(grep -Fxc "$MARKER_END" "$AFTER_RULES" || true)"
    if [ "$begin_count" -eq 1 ] && [ "$end_count" -eq 1 ]; then
        return 0
    fi
    if [ "$begin_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
        return 1
    fi
    echo "[ERROR] Incomplete or duplicate managed rules in $AFTER_RULES." >&2
    exit 1
}

rewrite_rules() (
    local action="$1" tmp
    tmp="$("${SUDO[@]}" mktemp "${AFTER_RULES}.XXXXXX")"
    trap '"${SUDO[@]}" rm -f "$tmp"' EXIT

    if [ "$action" = add ]; then
        "${SUDO[@]}" awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v chain="$CHAIN" '
            /^\*filter$/ { in_filter = 1; print; next }
            /^COMMIT$/ && in_filter && !inserted {
                print begin
                print ":DOCKER-USER - [0:0]"
                print ":" chain " - [0:0]"
                print "-A DOCKER-USER -j " chain
                print "-A " chain " -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
                print "-A " chain " -j ufw-user-forward"
                print "-A " chain " -m conntrack --ctstate NEW -j DROP"
                print "-A " chain " -j RETURN"
                print end
                inserted = 1
            }
            { print }
            END { if (!inserted) exit 1 }
        ' "$AFTER_RULES" | "${SUDO[@]}" tee "$tmp" >/dev/null
    else
        "${SUDO[@]}" awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
            $0 == begin { if (inside) exit 1; inside = 1; found = 1; next }
            $0 == end { if (!inside) exit 1; inside = 0; next }
            !inside { print }
            END { if (inside || !found) exit 1 }
        ' "$AFTER_RULES" | "${SUDO[@]}" tee "$tmp" >/dev/null
    fi

    "${SUDO[@]}" chmod --reference="$AFTER_RULES" "$tmp"
    "${SUDO[@]}" chown --reference="$AFTER_RULES" "$tmp"
    "${SUDO[@]}" mv "$tmp" "$AFTER_RULES"
    trap - EXIT
)

remove_runtime_rules() {
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi
    if ! "${SUDO[@]}" iptables -nL "$CHAIN" >/dev/null 2>&1; then
        return 0
    fi

    if "${SUDO[@]}" iptables -C DOCKER-USER -j "$CHAIN" >/dev/null 2>&1; then
        "${SUDO[@]}" iptables -D DOCKER-USER -j "$CHAIN"
    fi
    "${SUDO[@]}" iptables -F "$CHAIN"
    "${SUDO[@]}" iptables -X "$CHAIN"
}

do_install() {
    if ! command -v ufw >/dev/null 2>&1; then
        "${SUDO[@]}" apt-get update -y
        "${SUDO[@]}" apt-get install -y ufw
    fi
    echo "[SUCCESS] UFW is installed. Review firewall access before enabling it, then run 'bash cli.sh start'."
}

do_start() {
    require_firewall
    local has_managed_block=0
    if block_state; then
        has_managed_block=1
    else
        if grep -Eq '(^:DOCKER-USER([[:space:]]|$)|^-A DOCKER-USER([[:space:]]|$)|SCRIPT-TOOLS-UFW-DOCKER)' "$AFTER_RULES"; then
            echo "[ERROR] Existing Docker forwarding rules were found in $AFTER_RULES; refusing to overwrite them." >&2
            exit 1
        fi
        if "${SUDO[@]}" iptables -nL "$CHAIN" >/dev/null 2>&1; then
            echo "[ERROR] The managed chain name is already in use; inspect it before continuing." >&2
            exit 1
        fi
        if "${SUDO[@]}" iptables -S DOCKER-USER 2>/dev/null | grep -q '^-A DOCKER-USER'; then
            echo "[ERROR] DOCKER-USER already has rules; inspect them before enabling this managed policy." >&2
            exit 1
        fi
        rewrite_rules add
    fi

    if [ "$has_managed_block" -eq 1 ]; then
        remove_runtime_rules
    fi
    "${SUDO[@]}" ufw reload
    "${SUDO[@]}" iptables -C DOCKER-USER -j "$CHAIN" || {
        echo "[ERROR] Managed Docker rules did not load into DOCKER-USER." >&2
        exit 1
    }
    echo "[SUCCESS] Docker published ports now pass through UFW's forward rules; unmatched new connections are dropped."
    echo "[INFO] Add access with 'ufw route allow proto tcp from any to <container-ip> port <container-port>'."
}

do_stop() {
    if block_state; then
        remove_runtime_rules
        echo "[SUCCESS] Runtime Docker filtering stopped. Persistent rules remain and will return after the next UFW reload."
    else
        echo "[INFO] No managed persistent rules found; runtime state was left unchanged."
    fi
}

do_rm() {
    if block_state; then
        remove_runtime_rules
        rewrite_rules remove
        if command -v ufw >/dev/null 2>&1 && "${SUDO[@]}" ufw status | grep -q '^Status: active$'; then
            "${SUDO[@]}" ufw reload
        fi
        echo "[SUCCESS] Managed Docker firewall configuration removed. UFW and Docker packages are preserved."
    else
        echo "[INFO] No managed Docker firewall configuration found."
    fi
}

do_help() {
    echo "Usage: $0 {install|start|stop|rm}"
    echo "  install : Install UFW if missing; does not enable the firewall."
    echo "  start   : Persist and apply managed DOCKER-USER rules."
    echo "  stop    : Remove runtime filtering; persistent rules remain."
    echo "  rm      : Stop filtering and remove only this tool's rules from UFW config."
}

case "$COMMAND" in
    install) do_install ;;
    start)   do_start ;;
    stop)    do_stop ;;
    rm)      do_rm ;;
    help|-h|--help) do_help ;;
    *) echo "[ERROR] Unknown command: $COMMAND" >&2; do_help; exit 2 ;;
esac

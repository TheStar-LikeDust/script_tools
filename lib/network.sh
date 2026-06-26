#!/usr/bin/env bash
# Shared networking helpers for app-collection services (pure docker run).
# Sourced by a service's hooks.sh when it bundles dependencies; base services
# stay network-agnostic and do not depend on this file.

# Create the app's user-defined network if it does not exist yet
net_ensure() { docker network inspect "$1" >/dev/null 2>&1 || docker network create "$1" >/dev/null; }

# Attach a container to the app network (idempotent, never fails the caller)
net_connect() { docker network connect "$1" "$2" 2>/dev/null || true; }

# Remove the app network (idempotent)
net_rm() { docker network rm "$1" 2>/dev/null || true; }

# Show the app network and the containers currently attached to it
net_ls() {
    local net="$1"
    if docker network inspect "$net" >/dev/null 2>&1; then
        docker network inspect "$net" --format 'Network: {{.Name}}
Containers: {{range .Containers}}{{.Name}} {{end}}'
    else
        echo "No network '$net' yet (services not started)."
    fi
}

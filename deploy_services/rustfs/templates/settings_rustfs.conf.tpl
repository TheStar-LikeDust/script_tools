# RustFS Settings (Bash syntax; quote literal secrets with single quotes)
INSTANCE_NAME="{{INSTANCE_NAME}}"
IMAGE="rustfs/rustfs:latest"

# Optional existing shared Docker network; empty uses a private Compose network.
DOCKER_NETWORK=""

# Host Ports
RUSTFS_PORT="{{RUSTFS_PORT}}"
RUSTFS_ADMIN_PORT="{{RUSTFS_ADMIN_PORT}}"
# Set false to keep both endpoints inside Docker networks.
RUSTFS_PUBLISH_PORTS="true"

# API Keys
RUSTFS_ACCESS_KEY="{{RUSTFS_ACCESS_KEY}}"
RUSTFS_SECRET_KEY="{{RUSTFS_SECRET_KEY}}"

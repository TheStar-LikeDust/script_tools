# Redis Settings (Bash syntax)
INSTANCE_NAME="{{INSTANCE_NAME}}"
IMAGE="redis:7-alpine"

# Optional existing shared Docker network; empty uses a private Compose network.
DOCKER_NETWORK=""

# Host Port
REDIS_PORT="{{REDIS_PORT}}"
# Set false when only other containers need Redis access.
REDIS_PUBLISH_PORT="true"

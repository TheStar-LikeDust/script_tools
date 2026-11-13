# ParadeDB Settings (Bash syntax; quote literal secrets with single quotes)
INSTANCE_NAME="{{INSTANCE_NAME}}"
IMAGE="paradedb/paradedb:latest-pg17"

# Optional existing shared Docker network; empty uses a private Compose network.
DOCKER_NETWORK=""

# Host Port
DB_PORT="{{DB_PORT}}"
# Set false when only other containers need database access.
DB_PUBLISH_PORT="true"

# Database Credentials
DB_USER="{{DB_USER}}"
DB_PASSWORD="{{DB_PASSWORD}}"
DB_NAME="{{DB_NAME}}"

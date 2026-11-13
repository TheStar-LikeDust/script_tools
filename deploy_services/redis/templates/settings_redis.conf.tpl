# Redis settings. Init fills empty values from flags, then defaults.
INSTANCE_NAME=''
# Default: redis:7-alpine.
IMAGE=''

# Optional existing shared Docker network; empty uses a private Compose network.
DOCKER_NETWORK=''

# Host port; defaults to a random port. The container always uses 6379.
REDIS_PORT=''
# Default: true. Set false when only other containers need Redis access.
REDIS_PUBLISH_PORT=''

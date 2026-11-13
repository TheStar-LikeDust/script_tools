# Casdoor Settings
INSTANCE_NAME="{{INSTANCE_NAME}}"
CASDOOR_PORT="{{CASDOOR_PORT}}"
IMAGE="casbin/casdoor:latest"
POSTGRES_IMAGE="paradedb/paradedb:latest-pg17"

# Join an existing shared network, or leave empty for a private Compose network.
DOCKER_NETWORK=""

# The bundled PostgreSQL initializes this database and account on first start.
# Keep the saved password when reusing the persistent PostgreSQL data directory.
DB_HOST="{{INSTANCE_NAME}}_postgres"
DB_PORT="5432"
DB_NAME="casdoor"
DB_USER="casdoor"
DB_PASSWORD='{{DB_PASSWORD}}'
DB_SSLMODE="disable"

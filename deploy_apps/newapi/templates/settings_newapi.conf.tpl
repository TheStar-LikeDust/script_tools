# New API Settings

# === New API ===
INSTANCE_NAME="{{INSTANCE_NAME}}"
IMAGE="calciumion/new-api:latest"
# Empty uses this instance's private Compose network.
DOCKER_NETWORK=""
NEWAPI_PORT="{{NEWAPI_PORT}}"
NEWAPI_PUBLISH_PORT="true"
TZ="Asia/Shanghai"

# Bundled PostgreSQL. Its database and account are created on first start.
POSTGRES_IMAGE="paradedb/paradedb:latest-pg17"
DB_HOST="{{INSTANCE_NAME}}_postgres"
DB_PORT="5432"
DB_NAME="newapi"
DB_USER="newapi"
DB_PASSWORD=''
DB_SSLMODE="disable"

# Bundled Redis has no authentication and no published host port.
REDIS_IMAGE="redis:7-alpine"
REDIS_CONN_STRING='redis://{{INSTANCE_NAME}}_redis:6379/0'

# Record and show error logs in the web console
ERROR_LOG_ENABLED="true"

# Encrypts sensitive DB content (e.g. channel keys). NEVER change after first
# start: already-encrypted data cannot be decrypted with a new secret.
CRYPTO_SECRET='{{CRYPTO_SECRET}}'

# New API Settings

# === New API ===
INSTANCE_NAME="{{INSTANCE_NAME}}"
IMAGE="calciumion/new-api:latest"
DOCKER_NETWORK=""
NEWAPI_PORT="{{NEWAPI_PORT}}"
NEWAPI_PUBLISH_PORT="true"
TZ="Asia/Shanghai"

# Administrator-provisioned PostgreSQL database and dedicated account.
# Same-host containers: set DOCKER_NETWORK and use the DB container name + 5432.
# Remote PostgreSQL: use its reachable hostname/IP and listening port.
DB_HOST=""
DB_PORT="5432"
DB_NAME="newapi"
DB_USER="newapi"
DB_PASSWORD=''
DB_SSLMODE="disable"

# Use a dedicated Redis instance or administrator-managed credentials/isolation.
# Example: redis://:percent-encoded-password@redis-newapi:6379/0
REDIS_CONN_STRING=''

# Record and show error logs in the web console
ERROR_LOG_ENABLED="true"

# Encrypts sensitive DB content (e.g. channel keys). NEVER change after first
# start: already-encrypted data cannot be decrypted with a new secret.
CRYPTO_SECRET='{{CRYPTO_SECRET}}'

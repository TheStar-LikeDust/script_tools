# New API settings. PostgreSQL and Redis settings are separate service files.
INSTANCE_NAME="{{INSTANCE_NAME}}"
IMAGE="calciumion/new-api:latest"

# Empty uses this instance's private Compose network.
DOCKER_NETWORK=""
NEWAPI_PORT="{{NEWAPI_PORT}}"
NEWAPI_PUBLISH_PORT="true"
TZ="Asia/Shanghai"
ERROR_LOG_ENABLED="true"

# Explicit dependency settings paths. Relative paths resolve beside this file.
PARADEDB_CONF="settings_newapi_paradedb.conf"
REDIS_CONF="settings_newapi_redis.conf"

# Initial administrator credentials. Init fills empty values; start uses hooks.sh.
# These values do not change an existing administrator's login credentials.
NEWAPI_ADMIN_USERNAME=''
NEWAPI_ADMIN_PASSWORD=''

# Encrypts sensitive DB content (e.g. channel keys). NEVER change after first
# start: already-encrypted data cannot be decrypted with a new secret.
CRYPTO_SECRET='{{CRYPTO_SECRET}}'

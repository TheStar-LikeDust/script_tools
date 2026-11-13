# LobeHub settings. Dependency settings are maintained by their service CLIs.
INSTANCE_NAME="{{INSTANCE_NAME}}"
LOBECHAT_PORT="{{LOBECHAT_PORT}}"
IMAGE="lobehub/lobehub:latest"

# Relative paths resolve beside this file.
PARADEDB_CONF="settings_lobechat_paradedb.conf"
REDIS_CONF="settings_lobechat_redis.conf"
RUSTFS_CONF="settings_lobechat_rustfs.conf"

# Existing shared Docker network, or empty for a private Compose network.
DOCKER_NETWORK=""

# Defaults to http://localhost:<LOBECHAT_PORT>; set a browser-facing URL for remote access.
APP_URL=""

# Generated once. Keep these with your database backups.
KEY_VAULTS_SECRET='{{KEY_VAULTS_SECRET}}'
AUTH_SECRET='{{AUTH_SECRET}}'
# Generated on the first start, using host Node.js or a one-off app container.
JWKS_KEY=''

# Built-in email/password login, without SMTP or email verification.
# Generated once for initial registration; replace with a real email or domain as needed.
AUTH_ALLOWED_EMAILS=""

# Optional Composio integration.
COMPOSIO_API_KEY=''

# Optional Casdoor OIDC. Leave AUTH_SSO_PROVIDERS empty for email/password only.
AUTH_SSO_PROVIDERS=""
AUTH_CASDOOR_ID=""
AUTH_CASDOOR_SECRET=''
AUTH_CASDOOR_ISSUER=""

# OpenAI or an OpenAI-compatible provider.
ENABLED_OPENAI="1"
OPENAI_API_KEY=''
OPENAI_PROXY_URL="https://api.openai.com/v1"
OPENAI_MODEL_LIST="gpt-4o-mini"

# Redis uses an independent instance without authentication. The logical DB and
# prefix distinguish application data; they do not provide account isolation.
REDIS_DATABASE="0"
REDIS_PREFIX="{{INSTANCE_NAME}}"

# Defaults to http://localhost:<RUSTFS_PORT>; set a browser-facing URL for remote access.
S3_ENDPOINT=""
# The startup hook asks RustFS to create this bucket and its dedicated credentials.
S3_BUCKET="{{S3_BUCKET}}"
S3_ACCESS_KEY_ID=''
S3_SECRET_ACCESS_KEY=''

# TODO: Configure bucket CORS if browser uploads require it.

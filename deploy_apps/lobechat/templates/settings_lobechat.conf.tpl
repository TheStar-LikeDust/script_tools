# LobeHub application settings. PostgreSQL, Redis and S3 are managed separately.
INSTANCE_NAME="{{INSTANCE_NAME}}"
LOBECHAT_PORT="{{LOBECHAT_PORT}}"
IMAGE="lobehub/lobehub:latest"

# Existing shared Docker network, or empty for a private Compose network.
DOCKER_NETWORK=""

# PostgreSQL database and account must be provisioned by the administrator.
# Use the service container name and internal port on a shared Docker network.
# Remote services use a reachable hostname/IP and their published port.
DB_HOST=""
DB_PORT="5432"
DB_NAME="lobechat"
DB_USER="lobechat"
DB_PASSWORD=''
DB_SSLMODE="disable"

# Browser-facing URL. For remote access, use your server IP or HTTPS proxy URL.
APP_URL="http://localhost:{{LOBECHAT_PORT}}"

# Generated once. Keep these with your database backups.
KEY_VAULTS_SECRET='{{KEY_VAULTS_SECRET}}'
AUTH_SECRET='{{AUTH_SECRET}}'
JWKS_KEY='{{JWKS_KEY}}'

# Built-in email/password login, without SMTP or email verification.
# Replace the generated .invalid address with your email or domain before start.
AUTH_ALLOWED_EMAILS="{{AUTH_ALLOWED_EMAILS}}"

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

# Example: redis://username:percent-encoded-password@redis_host:6379/0
# Use rediss:// for TLS; keep the URL database number equal to REDIS_DATABASE.
REDIS_URL=''
REDIS_DATABASE="0"
REDIS_PREFIX="{{INSTANCE_NAME}}"

# Pre-create the bucket and dedicated credentials outside this app.
# For direct browser uploads/downloads, this endpoint must be reachable both
# from the app container and from the browser. Do not use an ephemeral IP.
S3_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY_ID=''
S3_SECRET_ACCESS_KEY=''

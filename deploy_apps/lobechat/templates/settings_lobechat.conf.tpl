# LobeHub Server DB deployment: app + bundled PostgreSQL, Redis and RustFS.
INSTANCE_NAME="{{INSTANCE_NAME}}"
LOBECHAT_PORT="{{LOBECHAT_PORT}}"
IMAGE="lobehub/lobehub:latest"

# Browser-facing URL. For remote access, replace localhost with your server IP
# or use the HTTPS URL of your reverse proxy before starting the app.
APP_URL="http://localhost:{{LOBECHAT_PORT}}"

# Generated once. Keep these with your database backups.
KEY_VAULTS_SECRET="{{KEY_VAULTS_SECRET}}"
AUTH_SECRET="{{AUTH_SECRET}}"
JWKS_KEY='{{JWKS_KEY}}'

# Built-in email/password login, without SMTP or email verification.
# Replace the generated .invalid address with your email or domain before start.
AUTH_ALLOWED_EMAILS="{{AUTH_ALLOWED_EMAILS}}"

# Optional Composio integration. Leave empty when Composio is not used.
COMPOSIO_API_KEY=""

# Optional Casdoor OIDC integration. Leave AUTH_SSO_PROVIDERS empty to use only
# email/password login. To enable Casdoor, set it to "casdoor" and fill all
# three AUTH_CASDOOR_* values below.
AUTH_SSO_PROVIDERS=""
AUTH_CASDOOR_ID=""
AUTH_CASDOOR_SECRET=""
AUTH_CASDOOR_ISSUER=""

# OpenAI or an OpenAI-compatible third-party provider.
# Set OPENAI_PROXY_URL to the provider's /v1 endpoint and adjust the model name.
ENABLED_OPENAI="1"
OPENAI_API_KEY=""
OPENAI_PROXY_URL="https://api.openai.com/v1"
OPENAI_MODEL_LIST="gpt-4o-mini"

# Redis is generated and started as a bundled service on the private Docker network.
# REDIS_URL is replaced at start with the bundled Redis container address.
REDIS_URL=""
REDIS_DATABASE="0"
REDIS_PREFIX="lobechat"

# RustFS runs alongside LobeHub on its private Docker network.
# Endpoint and credentials are generated from the bundled RustFS settings.
S3_BUCKET="lobechat"

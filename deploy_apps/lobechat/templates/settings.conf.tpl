# LobeChat Stack Settings
INSTANCE_NAME="{{INSTANCE_NAME}}"
NETWORK_NAME="{{NETWORK_NAME}}"

# Host Port
LOBECHAT_PORT="{{LOBECHAT_PORT}}"

# Security Keys (Auto-generated)
KEY_VAULTS_SECRET="{{KEY_VAULTS_SECRET}}"
AUTH_SECRET="{{AUTH_SECRET}}"

# Public host used to build the Casdoor SSO issuer URL (browser-facing).
# Default 'localhost' assumes local-only access via port-forwarding (not exposed to the internet).
# For external access, set this to your public IP or domain, e.g. auth.example.com
CASDOOR_PUBLIC_HOST="localhost"

# ==============================================================================
# Internal Services (Set 'true' to auto-deploy these containers)
# ==============================================================================
USE_INTERNAL_DB="true"
USE_INTERNAL_REDIS="true"
USE_INTERNAL_S3="true"
USE_INTERNAL_CASDOOR="true"

# ==============================================================================
# External Services (If above is 'false', fill in external connection info here)
# ==============================================================================
# [1. Database - Postgres]
EXTERNAL_DB_HOST=""
EXTERNAL_DB_PORT="5432"
EXTERNAL_DB_USER="postgres"
EXTERNAL_DB_PASSWORD=""
EXTERNAL_DB_NAME="lobechat"

# [2. Cache - Redis]
EXTERNAL_REDIS_URL=""  # Example: redis://192.168.1.100:6379

# [3. Storage - S3]
EXTERNAL_S3_ENDPOINT=""
EXTERNAL_S3_BUCKET="lobechat"
EXTERNAL_S3_ACCESS_KEY=""
EXTERNAL_S3_SECRET_KEY=""

# [4. Auth - Casdoor]
EXTERNAL_CASDOOR_ISSUER=""
EXTERNAL_CASDOOR_ID=""
EXTERNAL_CASDOOR_SECRET=""

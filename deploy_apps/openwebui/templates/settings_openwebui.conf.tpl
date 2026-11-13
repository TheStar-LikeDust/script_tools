# Open WebUI Settings
INSTANCE_NAME="{{INSTANCE_NAME}}"
IMAGE="ghcr.io/open-webui/open-webui:main"
DOCKER_NETWORK=""

# Host Port
OPENWEBUI_PORT="{{OPENWEBUI_PORT}}"
OPENWEBUI_PUBLISH_PORT="true"

# JWT Secret (Auto-generated)
WEBUI_SECRET_KEY='{{WEBUI_SECRET_KEY}}'

# Leave DB_HOST empty to keep the existing SQLite database in the local data dir.
# Changing to PostgreSQL does not migrate SQLite data.
# Fill all DB_* values for an administrator-provisioned database/account.
DB_HOST=""
DB_PORT="5432"
DB_NAME="openwebui"
DB_USER="openwebui"
DB_PASSWORD=''
DB_SSLMODE="disable"

# Optional external Redis and object storage; provision them independently.
# URI credentials must be percent-encoded.
REDIS_URL=''
STORAGE_PROVIDER="local"
S3_ENDPOINT_URL=""
S3_ACCESS_KEY_ID=''
S3_SECRET_ACCESS_KEY=''
S3_BUCKET_NAME=""
S3_REGION_NAME="us-east-1"

# Set False only when environment settings should override persisted UI settings.
ENABLE_PERSISTENT_CONFIG="True"

# Optional: External LLM APIs
OLLAMA_BASE_URL="http://host.docker.internal:11434"
OPENAI_API_BASE_URL="https://api.openai.com/v1"
OPENAI_API_KEY=""
OPENAI_API_BASE_URLS=""
OPENAI_API_KEYS=""

# Initial Admin User (Applied only when database is empty)
WEBUI_ADMIN_EMAIL="{{WEBUI_ADMIN_EMAIL}}"
WEBUI_ADMIN_PASSWORD="{{WEBUI_ADMIN_PASSWORD}}"
WEBUI_ADMIN_NAME="{{WEBUI_ADMIN_NAME}}"

# ==========================================
# Advanced Settings
# ==========================================

# Optional: HuggingFace Token (Bypass download limits for RAG models)
HF_TOKEN=""

# CORS Origins ('*' allows all, not safe for production)
CORS_ALLOW_ORIGIN="*"

# User Agent for Web Search (Spoof real browser to avoid blocks)
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

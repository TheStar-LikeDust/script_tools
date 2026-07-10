# LibreChat Settings
INSTANCE_NAME="{{INSTANCE_NAME}}"

# Official LibreChat repository used by cli.sh init.
LIBRECHAT_REPO_URL="https://github.com/danny-avila/LibreChat.git"

# Host Port
# The official compose files may still define their own published port mapping.
# Keep this aligned with any docker-compose.override.yml you add inside the checkout.
LIBRECHAT_PORT="3080"

# Browser-facing URLs
DOMAIN_CLIENT="http://localhost:${LIBRECHAT_PORT}"
DOMAIN_SERVER="http://localhost:${LIBRECHAT_PORT}"
ADMIN_PANEL_URL="http://admin.localhost"
ADMIN_PANEL_SESSION_COOKIE_SECURE="false"

# Security Keys (Auto-generated)
JWT_SECRET="{{JWT_SECRET}}"
JWT_REFRESH_SECRET="{{JWT_REFRESH_SECRET}}"
CREDS_KEY="{{CREDS_KEY}}"
CREDS_IV="{{CREDS_IV}}"
MEILI_MASTER_KEY="{{MEILI_MASTER_KEY}}"
ADMIN_PANEL_SESSION_SECRET="{{ADMIN_PANEL_SESSION_SECRET}}"

# Registration and Login
ALLOW_EMAIL_LOGIN="true"
ALLOW_REGISTRATION="true"
ALLOW_UNVERIFIED_EMAIL_LOGIN="true"

# Search / RAG
SEARCH="true"
RAG_PORT="8000"
EMBEDDINGS_PROVIDER="openai"
EMBEDDINGS_MODEL="text-embedding-3-small"

# Common AI Provider Keys
OPENAI_API_KEY=""
ANTHROPIC_API_KEY=""
GOOGLE_KEY=""
OPENROUTER_KEY=""
DEEPSEEK_API_KEY=""
GROQ_API_KEY=""
MISTRAL_API_KEY=""
PERPLEXITY_API_KEY=""
TOGETHERAI_API_KEY=""

# Optional outbound proxy
PROXY=""
HTTP_PROXY=""
HTTPS_PROXY=""
NO_PROXY="localhost,127.0.0.1,::1,mongodb,chat-mongodb,meilisearch,chat-meilisearch,rag_api,vectordb,host.docker.internal"
http_proxy=""
https_proxy=""
no_proxy="localhost,127.0.0.1,::1,mongodb,chat-mongodb,meilisearch,chat-meilisearch,rag_api,vectordb,host.docker.internal"

# UI
APP_TITLE="LibreChat"
HELP_AND_FAQ_URL="https://librechat.ai"

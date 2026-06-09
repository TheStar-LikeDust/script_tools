# Open WebUI Settings
INSTANCE_NAME="{{INSTANCE_NAME}}"

# Host Port
OPENWEBUI_PORT="{{OPENWEBUI_PORT}}"

# JWT Secret (Auto-generated)
WEBUI_SECRET_KEY="{{WEBUI_SECRET_KEY}}"

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

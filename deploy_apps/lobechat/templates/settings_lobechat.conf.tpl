# Minimal LobeHub Server DB deployment: app + bundled PostgreSQL.
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
# Optional registration allowlist: your email or domain; empty allows everyone.
AUTH_ALLOWED_EMAILS=""

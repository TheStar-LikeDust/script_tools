# New API Settings

# === New API ===
INSTANCE_NAME="{{INSTANCE_NAME}}"
NEWAPI_PORT="{{NEWAPI_PORT}}"
TZ="Asia/Shanghai"

# Record and show error logs in the web console
ERROR_LOG_ENABLED="true"

# Encrypts sensitive DB content (e.g. channel keys). NEVER change after first
# start: already-encrypted data cannot be decrypted with a new secret.
CRYPTO_SECRET="{{CRYPTO_SECRET}}"

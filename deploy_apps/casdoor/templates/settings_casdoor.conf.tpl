# Casdoor Settings

# === Casdoor ===
INSTANCE_NAME="{{INSTANCE_NAME}}"
CASDOOR_PORT="{{CASDOOR_PORT}}"
# Application database Casdoor uses (auto-created on first run)
CASDOOR_DB_NAME="casdoor"

# Bundled DB switch:
#   true  -> bundle a paradedb (delegated to deploy/paradedb; see casdoor_paradedb.conf)
#   false -> connect to the external database configured below
WITH_BUNDLED_DB="{{WITH_BUNDLED_DB}}"

# === External Database (used ONLY when WITH_BUNDLED_DB=false) ===
EXT_DB_HOST=""
EXT_DB_PORT="5432"
EXT_DB_USER="postgres"
EXT_DB_PASSWORD=""
# Bootstrap DB to connect to for creating CASDOOR_DB_NAME (usually 'postgres')
EXT_DB_NAME="postgres"

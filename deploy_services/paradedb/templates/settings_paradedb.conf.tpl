# ParadeDB settings (Bash syntax). Init fills empty fields from flags or defaults.
# Existing nonempty fields are preserved, including passwords.
INSTANCE_NAME=''
IMAGE=''

# Optional existing shared Docker network; empty uses a private Compose network.
DOCKER_NETWORK=""

# Host Port
DB_PORT=''
# Set false when only other containers need database access.
DB_PUBLISH_PORT=''

# Database Credentials
DB_USER=''
DB_PASSWORD=''
DB_NAME=''

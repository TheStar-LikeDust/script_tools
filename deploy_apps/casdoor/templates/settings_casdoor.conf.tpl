# Casdoor Settings
INSTANCE_NAME="{{INSTANCE_NAME}}"
CASDOOR_PORT="{{CASDOOR_PORT}}"
IMAGE="casbin/casdoor:latest"

# Join an existing shared network, or leave empty for a private Compose network.
DOCKER_NETWORK=""

# An administrator must create this database and its dedicated account first.
# On a shared network use the database INSTANCE_NAME and container port 5432.
# For a remote server use its reachable hostname/IP and published port.
DB_HOST=""
DB_PORT="5432"
DB_NAME="casdoor"
DB_USER="casdoor"
DB_PASSWORD=''
DB_SSLMODE="disable"

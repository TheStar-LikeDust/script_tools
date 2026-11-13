# Casdoor Settings
INSTANCE_NAME="{{INSTANCE_NAME}}"
CASDOOR_PORT="{{CASDOOR_PORT}}"
IMAGE="casbin/casdoor:latest"

# Join an existing shared network, or leave empty for a private Compose network.
DOCKER_NETWORK=""

# ParadeDB CLI owns database settings, credentials and the generated DSN.
# Relative paths resolve beside this app settings file.
PARADEDB_CONF="settings_casdoor_paradedb.conf"

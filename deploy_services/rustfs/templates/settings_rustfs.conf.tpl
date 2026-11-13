# RustFS settings (Bash syntax; quote literal secrets with single quotes).
INSTANCE_NAME="{{INSTANCE_NAME}}"
IMAGE=""
RUSTFS_INIT_IMAGE=""

# Optional shared Docker network. Empty uses the Compose project's private network.
DOCKER_NETWORK=""

# Host ports and publication switch; container ports remain 9000 and 9001.
RUSTFS_PORT=""
RUSTFS_ADMIN_PORT=""
RUSTFS_PUBLISH_PORTS=""

# Root credentials used only by this RustFS instance and resource initialization.
RUSTFS_ACCESS_KEY=''
RUSTFS_SECRET_KEY=''

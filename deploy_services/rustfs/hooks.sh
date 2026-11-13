#!/usr/bin/env bash
# RustFS rendering, filesystem preparation and application resource initialization.

export_compose_env() {
    local print_exports="${1:-false}" key
    RUSTFS_INSTANCE_NAME="$INSTANCE_NAME"
    RUSTFS_IMAGE="$IMAGE"
    RUSTFS_INIT_IMAGE="${RUSTFS_INIT_IMAGE:-rustfs/rc:latest}"
    RUSTFS_DOCKER_NETWORK="$DOCKER_NETWORK"
    RUSTFS_ENDPOINT="http://${INSTANCE_NAME}:9000"
    for key in RUSTFS_INSTANCE_NAME RUSTFS_IMAGE RUSTFS_INIT_IMAGE RUSTFS_DOCKER_NETWORK \
        RUSTFS_PORT RUSTFS_ADMIN_PORT RUSTFS_PUBLISH_PORTS RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY RUSTFS_ENDPOINT; do
        export "$key"
        if [ "$print_exports" = true ]; then printf 'export %s=%q\n' "$key" "${!key}"; fi
    done
}

render_service() {
    local service_name="${1:-rustfs}"
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[ERROR] Invalid Compose service name: $service_name" >&2
        return 1
    fi
    sed "s/{{SERVICE_NAME}}/$service_name/" "$TPL_DIR/compose.yaml.tpl"
    if [ "$RUSTFS_PUBLISH_PORTS" = true ]; then
        cat <<'YAML'
    ports:
      - "${RUSTFS_PORT:?RUSTFS_PORT is required}:9000"
      - "${RUSTFS_ADMIN_PORT:?RUSTFS_ADMIN_PORT is required}:9001"
YAML
    fi
}

rustfs_uid_gid() (
    local probe_name="" passwd_dir uid_gid
    passwd_dir="$(mktemp -d)"
    trap '[ -z "$probe_name" ] || docker rm -f "$probe_name" >/dev/null; rm -f -- "$passwd_dir/passwd"; rmdir -- "$passwd_dir"' EXIT
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        docker pull "$IMAGE" >/dev/null
    fi
    probe_name="$(docker create "$IMAGE")"
    docker cp "$probe_name:/etc/passwd" "$passwd_dir/passwd" >/dev/null
    uid_gid="$(awk -F: '$1 == "rustfs" { print $3 ":" $4; exit }' "$passwd_dir/passwd")"
    [ -n "$uid_gid" ] || { echo "[ERROR] RustFS image has no rustfs user." >&2; return 1; }
    printf '%s' "$uid_gid"
)

ensure_data_owner() {
    local data_dir="$1" uid_gid
    mkdir -p "$data_dir"
    uid_gid="$(rustfs_uid_gid)"
    if [ "$(stat -c '%u:%g' "$data_dir")" != "$uid_gid" ]; then
        printf '[INFO] [RustFS] Setting data directory ownership to %s.\n' "$uid_gid" >&2
        chown -R "$uid_gid" "$data_dir"
    fi
}

initialize_resources() (
    umask 077
    local container_info running project service data_dir resource_dir temp_dir policy_name
    [[ "$RESOURCE_OWNER" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "[ERROR] --owner must be a valid instance name." >&2; exit 2; }
    [[ "$RESOURCE_BUCKET" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || { echo "[ERROR] --bucket must use 3-63 lowercase letters, digits or hyphens." >&2; exit 2; }
    [[ "$RESOURCE_ACCESS_KEY" =~ ^[A-Za-z0-9]{3,20}$ ]] || { echo "[ERROR] --access-key must use 3-20 letters or digits." >&2; exit 2; }
    [ "${#RESOURCE_SECRET_KEY}" -ge 8 ] || { echo "[ERROR] --secret-key must contain at least 8 characters." >&2; exit 2; }
    if [[ "$RESOURCE_SECRET_KEY" == *$'\n'* || "$RESOURCE_SECRET_KEY" == *$'\r'* || "$RESOURCE_ENDPOINT" == *$'\n'* || "$RESOURCE_ENDPOINT" == *$'\r'* ]]; then
        echo "[ERROR] Resource credentials and endpoint must be single-line values." >&2
        exit 2
    fi
    [ "$RESOURCE_ACCESS_KEY" != "$RUSTFS_ACCESS_KEY" ] || { echo "[ERROR] App credentials must differ from RustFS root credentials." >&2; exit 2; }

    container_info="$(docker container inspect --format '{{.State.Running}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$INSTANCE_NAME")"
    IFS='|' read -r running project service data_dir <<< "$container_info"
    if [ "$running" != true ] || [ "$service" != rustfs ] || { [ "$project" != "$RESOURCE_OWNER" ] && [ "$project" != "$INSTANCE_NAME" ]; }; then
        echo "[ERROR] The configured RustFS container is not running in the requested Compose project." >&2
        exit 1
    fi
    [ -n "$data_dir" ] || { echo "[ERROR] The RustFS container has no /data mount." >&2; exit 1; }
    resource_dir="$data_dir/.resources"
    mkdir -p "$resource_dir"
    temp_dir="$(mktemp -d)"
    trap 'rm -f -- "$temp_dir/environment" "$temp_dir/policy.json"; rmdir -- "$temp_dir"' EXIT
    policy_name="app-$(printf '%s\n%s' "$RESOURCE_OWNER" "$RESOURCE_BUCKET" | sha256sum | cut -c 1-24)"
    {
        printf 'RUSTFS_ENDPOINT=%s\n' "${RESOURCE_ENDPOINT:-http://127.0.0.1:9000}"
        printf 'RUSTFS_ROOT_ACCESS_KEY=%s\nRUSTFS_ROOT_SECRET_KEY=%s\n' "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY"
        printf 'RUSTFS_RESOURCE_OWNER=%s\nRUSTFS_RESOURCE_BUCKET=%s\n' "$RESOURCE_OWNER" "$RESOURCE_BUCKET"
        printf 'RUSTFS_RESOURCE_ACCESS_KEY=%s\nRUSTFS_RESOURCE_SECRET_KEY=%s\n' "$RESOURCE_ACCESS_KEY" "$RESOURCE_SECRET_KEY"
        printf 'RUSTFS_RESOURCE_SECRET_FINGERPRINT=%s\n' "$(printf '%s' "$RESOURCE_SECRET_KEY" | sha256sum | cut -d ' ' -f 1)"
        printf 'RUSTFS_RESOURCE_POLICY=%s\n' "$policy_name"
    } > "$temp_dir/environment"
    cat > "$temp_dir/policy.json" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::$RESOURCE_BUCKET"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:PutObject", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::$RESOURCE_BUCKET/*"]
    }
  ]
}
POLICY

    docker run --rm -i --user 0:0 --network "container:$INSTANCE_NAME" \
        --env-file "$temp_dir/environment" --env XDG_CONFIG_HOME=/tmp/rc-config \
        --volume "$resource_dir:/resources" --volume "$temp_dir/policy.json:/tmp/policy.json:ro" \
        --entrypoint /bin/sh "$RUSTFS_INIT_IMAGE" -s >&2 <<'SH'
set -eu
umask 077

# rc may use a generic status for a missing bucket; match that explicit error too.
resource_exists() {
    if "$@" >/dev/null 2>/tmp/lookup-error; then return 0; else result=$?; fi
    if [ "$result" -eq 5 ] || grep -Fqi 'Bucket not found:' /tmp/lookup-error; then return 1; fi
    cat /tmp/lookup-error >&2
    exit "$result"
}

rc alias set local "$RUSTFS_ENDPOINT" "$RUSTFS_ROOT_ACCESS_KEY" "$RUSTFS_ROOT_SECRET_KEY" >/dev/null
attempt=0
until rc ready local --timeout 2 >/dev/null 2>/tmp/ready-error; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        cat /tmp/ready-error >&2
        echo "[ERROR] RustFS did not become ready; resolve the error, then run start again." >&2
        exit 1
    fi
    sleep 2
done
rc ls local/ >/dev/null

bucket_exists=false
user_exists=false
policy_exists=false
if resource_exists rc ls "local/$RUSTFS_RESOURCE_BUCKET"; then bucket_exists=true; fi
if resource_exists rc admin user info local "$RUSTFS_RESOURCE_ACCESS_KEY"; then user_exists=true; fi
if resource_exists rc admin policy info local "$RUSTFS_RESOURCE_POLICY"; then policy_exists=true; fi

marker="/resources/$RUSTFS_RESOURCE_POLICY"
printf '%s\n%s\n%s\n%s\n' "$RUSTFS_RESOURCE_OWNER" "$RUSTFS_RESOURCE_BUCKET" \
    "$RUSTFS_RESOURCE_ACCESS_KEY" "$RUSTFS_RESOURCE_SECRET_FINGERPRINT" > /tmp/requested-owner
if [ -f "$marker" ]; then
    if ! cmp -s "$marker" /tmp/requested-owner; then
        echo "[ERROR] RustFS ownership marker does not match the requested credentials." >&2
        exit 1
    fi
else
    if [ "$bucket_exists" = true ] || [ "$user_exists" = true ] || [ "$policy_exists" = true ]; then
        echo "[ERROR] A named RustFS resource exists without an ownership marker; refusing to adopt it." >&2
        exit 1
    fi
    cp /tmp/requested-owner "$marker.pending"
    mv "$marker.pending" "$marker"
fi

if [ "$bucket_exists" = false ]; then rc mb "local/$RUSTFS_RESOURCE_BUCKET"; fi
if [ "$user_exists" = false ]; then rc admin user add local "$RUSTFS_RESOURCE_ACCESS_KEY" "$RUSTFS_RESOURCE_SECRET_KEY"; fi
if [ "$policy_exists" = false ]; then rc admin policy create local "$RUSTFS_RESOURCE_POLICY" /tmp/policy.json; fi
rc admin user info local "$RUSTFS_RESOURCE_ACCESS_KEY" --json > /tmp/user-info.json
if ! jq -e --arg policy "$RUSTFS_RESOURCE_POLICY" '[.. | strings | split(",")[]] | index($policy) != null' /tmp/user-info.json >/dev/null; then
    rc admin policy attach local "$RUSTFS_RESOURCE_POLICY" --user "$RUSTFS_RESOURCE_ACCESS_KEY"
fi
rc alias set app "$RUSTFS_ENDPOINT" "$RUSTFS_RESOURCE_ACCESS_KEY" "$RUSTFS_RESOURCE_SECRET_KEY" >/dev/null
rc ls "app/$RUSTFS_RESOURCE_BUCKET" >/dev/null
printf '[SUCCESS] RustFS resources ready: %s\n' "$RUSTFS_RESOURCE_BUCKET"
SH
)

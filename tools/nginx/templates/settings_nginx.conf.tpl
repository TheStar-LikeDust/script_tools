# Nginx Gateway Settings

# Site config filename in nginx conf.d (auto-generated on first start)
INSTANCE_NAME="nginx_XXXX"

# Public hostname; use _ to match any host
SERVER_NAME="_"

# Public port nginx listens on (governed by UFW as a normal host process)
LISTEN_PORT="80"

# Upstream app's host port (e.g. newapi's NEWAPI_PORT); proxied as 127.0.0.1:UPSTREAM_PORT
UPSTREAM_PORT="3000"

# The ONLY path prefix exposed publicly; everything else returns 404
ALLOW_PREFIX="/v1/"

server {
    listen {{LISTEN_PORT}};
    server_name {{SERVER_NAME}};

    # Only the whitelisted prefix is reachable from the public port.
    location {{ALLOW_PREFIX}} {
        proxy_pass http://127.0.0.1:{{UPSTREAM_PORT}};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # SSE / streaming responses
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 600s;
    }

    # Web UI (/) and management API (/api/) are NOT exposed here.
    location / { return 404; }
}

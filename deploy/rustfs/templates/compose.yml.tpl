services:
  rustfs:
    image: rustfs/rustfs:latest
    container_name: {{INSTANCE_NAME}}_rustfs
    restart: unless-stopped
    ports:
      - "{{RUSTFS_PORT}:9000"
      - "{{RUSTFS_ADMIN_PORT}:9001"
    environment:
      RUSTFS_CONSOLE_ENABLE: "true"
      RUSTFS_ACCESS_KEY: "{{RUSTFS_ACCESS_KEY}}"
      RUSTFS_SECRET_KEY: "{{RUSTFS_SECRET_KEY}}"
    volumes:
      - ./data/{{INSTANCE_NAME}}_data:/data
    healthcheck:
      test: ['CMD-SHELL', 'wget -qO- http://localhost:9000/health >/dev/null 2>&1 || exit 1']
      interval: 5s
      timeout: 3s
      retries: 30
    command:
      ['--access-key', '{{RUSTFS_ACCESS_KEY}}', '--secret-key', '{{RUSTFS_SECRET_KEY}}', '/data']
    networks:
      - default

  rustfs-init:
    image: minio/mc:latest
    container_name: {{INSTANCE_NAME}}_init
    depends_on:
      rustfs:
        condition: service_healthy
    entrypoint: /bin/sh
    command: >
      -c '
      set -eux;
      echo "Waiting for RustFS...";
      mc alias set rustfs "http://rustfs:9000" "{{RUSTFS_ACCESS_KEY}}" "{{RUSTFS_SECRET_KEY}}";
      mc mb "rustfs/{{RUSTFS_INIT_BUCKET}}" --ignore-existing;
      mc anonymous set public "rustfs/{{RUSTFS_INIT_BUCKET}}";
      echo "RustFS initialization completed."
      '
    restart: "no"
    networks:
      - default

networks:
  default:
    name: {{NETWORK_NAME}}

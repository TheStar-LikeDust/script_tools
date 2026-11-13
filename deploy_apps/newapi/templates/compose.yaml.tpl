  newapi:
    image: "${NEWAPI_IMAGE:?NEWAPI_IMAGE is required}"
    container_name: "${NEWAPI_INSTANCE_NAME:?NEWAPI_INSTANCE_NAME is required}"
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      SQL_DSN: "${PARADEDB_DSN:?PARADEDB_DSN is required}"
      REDIS_CONN_STRING: "${REDIS_URL:?REDIS_URL is required}"
      CRYPTO_SECRET: "${NEWAPI_CRYPTO_SECRET:?NEWAPI_CRYPTO_SECRET is required}"
      TZ: "${NEWAPI_TZ:-Asia/Shanghai}"
      ERROR_LOG_ENABLED: "${NEWAPI_ERROR_LOG_ENABLED:-true}"
    volumes:
      - "./data/${NEWAPI_INSTANCE_NAME}_data:/data"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/status >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

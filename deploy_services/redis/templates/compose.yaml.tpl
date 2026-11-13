  {{SERVICE_NAME}}:
    image: "${REDIS_IMAGE:-redis:7-alpine}"
    container_name: "${REDIS_INSTANCE_NAME:?REDIS_INSTANCE_NAME is required}"
    restart: unless-stopped
    volumes:
      - "./data/${REDIS_INSTANCE_NAME}_data:/data"
    command: ["redis-server", "--save", "60", "1000", "--appendonly", "yes"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

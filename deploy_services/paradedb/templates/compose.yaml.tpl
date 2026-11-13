  '{{SERVICE_NAME}}':
    image: "${PARADEDB_IMAGE:?PARADEDB_IMAGE is required}"
    container_name: "${PARADEDB_INSTANCE_NAME:?PARADEDB_INSTANCE_NAME is required}"
    restart: unless-stopped
    environment:
      POSTGRES_USER: "${PARADEDB_DB_USER:?PARADEDB_DB_USER is required}"
      POSTGRES_PASSWORD: "${PARADEDB_DB_PASSWORD:?PARADEDB_DB_PASSWORD is required}"
      POSTGRES_DB: "${PARADEDB_DB_NAME:?PARADEDB_DB_NAME is required}"
    volumes:
      - "./data/${PARADEDB_INSTANCE_NAME}_data:/var/lib/postgresql/data"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\""]
      interval: 5s
      timeout: 5s
      retries: 5

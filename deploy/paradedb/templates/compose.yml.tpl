services:
  paradedb:
    image: paradedb/paradedb:latest-pg17
    container_name: {{INSTANCE_NAME}}
    restart: unless-stopped
    ports:
      - "{{DB_PORT}:5432"
    environment:
      POSTGRES_USER: "{{DB_USER}}"
      POSTGRES_PASSWORD: "{{DB_PASSWORD}}"
      POSTGRES_DB: "{{DB_NAME}}"
    volumes:
      - ./data/{{INSTANCE_NAME}}_data:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U {{DB_USER}}']
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - default

networks:
  default:
    name: {{NETWORK_NAME}}

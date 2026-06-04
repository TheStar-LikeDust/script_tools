services:
  redis:
    image: redis:7-alpine
    container_name: {{INSTANCE_NAME}}
    restart: unless-stopped
    ports:
      - "{{REDIS_PORT}}:6379"
    command: redis-server --save 60 1000 --appendonly yes
    volumes:
      - ./data/{{INSTANCE_NAME}}_data:/data
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 5s
      timeout: 3s
      retries: 5
    networks:
      - default

networks:
  default:
    name: {{NETWORK_NAME}}

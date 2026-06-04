services:
  lobechat:
    image: lobehub/lobehub:latest
    container_name: {{INSTANCE_NAME}}
    restart: unless-stopped
    ports:
      - "{{LOBECHAT_PORT}}:3210"
    environment:
      - "DATABASE_URL=postgresql://{{DB_USER}}:{{DB_PASSWORD}}@{{DB_HOST}}:{{DB_PORT}}/{{DB_NAME}}"
      - "INTERNAL_APP_URL=http://localhost:3210"
      - "KEY_VAULTS_SECRET={{KEY_VAULTS_SECRET}}"
      - "AUTH_SECRET={{AUTH_SECRET}}"
      
      # S3
      - "S3_ENDPOINT={{S3_ENDPOINT}}"
      - "S3_BUCKET={{S3_BUCKET}}"
      - "S3_ACCESS_KEY_ID={{S3_ACCESS_KEY}}"
      - "S3_SECRET_ACCESS_KEY={{S3_SECRET_KEY}}"
      - "S3_ENABLE_PATH_STYLE=1"
      - "LLM_VISION_IMAGE_USE_BASE64=1"
      
      # Redis
      - "REDIS_URL={{REDIS_URL}}"
      - "REDIS_PREFIX={{INSTANCE_NAME}}"
      
      # SSO Auth (Casdoor)
      - "NEXT_AUTH_SSO_PROVIDERS=casdoor"
      - "AUTH_CASDOOR_ISSUER={{CASDOOR_ISSUER}}"
      - "AUTH_CASDOOR_ID={{CASDOOR_ID}}"
      - "AUTH_CASDOOR_SECRET={{CASDOOR_SECRET}}"
    volumes:
      - ./data/{{INSTANCE_NAME}}_data:/app/data
    networks:
      - default

networks:
  default:
    name: {{NETWORK_NAME}}

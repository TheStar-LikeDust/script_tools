services:
  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: {{INSTANCE_NAME}}
    ports:
      - "{{OPENWEBUI_PORT}}:8080"
    volumes:
      - ./data/{{INSTANCE_NAME}}_data:/app/backend/data
    environment:
      - WEBUI_SECRET_KEY={{WEBUI_SECRET_KEY}}
      - OLLAMA_BASE_URL={{OLLAMA_BASE_URL}}
      - OPENAI_API_BASE_URL={{OPENAI_API_BASE_URL}}
      - OPENAI_API_KEY={{OPENAI_API_KEY}}
      - HF_TOKEN={{HF_TOKEN}}
      - CORS_ALLOW_ORIGIN={{CORS_ALLOW_ORIGIN}}
      - USER_AGENT="${USER_AGENT}"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: always

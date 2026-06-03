services:
  casdoor:
    image: casbin/casdoor:latest
    container_name: {{INSTANCE_NAME}}
    restart: unless-stopped
    ports:
      - "{{CASDOOR_PORT}:8000"
    environment:
      RUNNING_IN_DOCKER: "true"
    volumes:
      - ./casdoor.conf:/conf/app.conf
      - ./data/{{INSTANCE_NAME}}_data:/data
    networks:
      - default

networks:
  default:
    name: {{NETWORK_NAME}}

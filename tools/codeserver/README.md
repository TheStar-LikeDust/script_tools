# Code-Server

This is a pure host-level development tool environment configuration running directly on the physical machine, non-Dockerized.

## Common Commands

```bash
# Initialize configuration
bash cli.sh init

# Install code-server
bash cli.sh install

# Run in foreground (blocking, suitable for debugging or temporary use)
bash cli.sh run

# Run in background via tmux (suitable for long-term background execution)
bash cli.sh start

# Stop background tmux session
bash cli.sh stop

# Check background running status
bash cli.sh status
```

## Docker Alternative Note

If you must use Docker to deploy `code-server` due to environment constraints, here is an alternative `fastrun` command for reference. **This script does not support Docker deployment by default.**

```bash
docker volume create code-server-config
docker run -d \
  --name code-server \
  -p 55:8080 \
  -v /root/rtw:/home/coder/rtw \
  -v /root/codeserver_config/config:/home/coder/.config \
  -v /opt/anaconda3:/opt/anaconda3 \
  -v /root/codeserver_config/local_extensions:/home/coder/.local/share/code-server/extensions \
  -e PASSWORD="878867" \
  -u "$(id -u):$(id -g)" \
  -e "DOCKER_USER=$USER" \
  codercom/code-server:latest
```

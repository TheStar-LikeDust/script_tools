# Code-Server 部署 (Deploy)

## 1. 简介

> 宿主机级别的网页端 VSCode 环境，通过 tmux 在后台运行。

`install` 安装 code-server 与 tmux 并创建缺失的实例配置；`start/stop` 管理对应 tmux 会话；`rm` 只删除本实例设置和脚本生成的 `config.yaml`，保留用户数据和已安装软件。

## 2. 核心配置项

### settings_codeserver.conf

- `SESSION_NAME`：tmux 会话名，默认生成时间戳后缀；多实例建议显式指定名称。
- `HOST`：监听地址，默认 `127.0.0.1`。
- `PORT`：监听端口，默认 `8080`。
- `PASSWORD`：网页端认证密码，首次生成时随机设置。
- `CONFIG_DIR`：生成 `config.yaml` 的目录，必须是 settings 所在目录内的相对路径。
- `USER_DATA_DIR`：用户数据目录，必须是 settings 所在目录内的相对路径。

## 3. 备注

- `install` 依赖 Debian/Ubuntu 的 `apt-get` 和 code-server 官方安装脚本；普通用户运行时，脚本通过 `sudo` 安装 tmux。
- `install` 不会启用服务；`start` 要求 code-server 和 tmux 已安装。
- settings 与生成的 `config.yaml` 使用仅当前用户可读写的权限，文件中包含登录密码。
- 配置路径中的绝对路径和 `..` 路径会被拒绝，避免清理越出实例目录。
- `CONFIG_DIR` 与 `USER_DATA_DIR` 不可重叠，避免 `rm` 清理生成配置时触及用户数据。
- `--conf PATH` 的父目录须已存在；`--name NAME` 仅在 `install` 首次生成 settings 时生效。
- `rm` 删除当前 `--conf` 指向的 settings 和 `CONFIG_DIR/config.yaml`，保留 `USER_DATA_DIR`、其他配置文件和宿主机软件。

## 4. 快速执行

```bash
cd tools/codeserver
bash cli.sh install
# Review settings_codeserver.conf.
bash cli.sh start
bash cli.sh stop
# Stop the session and remove this instance's settings and generated config.
bash cli.sh rm
```

## 5. 命令解释

#### install

安装 code-server 与 tmux，并在 settings 不存在时生成随机密码和实例名。已有 settings 不会被覆盖。

#### start

按 settings 生成 `CONFIG_DIR/config.yaml`，然后创建后台 tmux 会话。已存在同名会话时不重复启动。

#### stop

停止 settings 中的 tmux 会话；不删除 settings 或数据。

#### rm

停止会话并删除当前 settings 与脚本生成的 `config.yaml`。保留用户数据、目录中的其他文件、code-server 和 tmux 软件包。

## 6. 复制恢复

迁移时停止会话并复制脚本、templates、settings 及 `USER_DATA_DIR`。目标机运行 `install` 准备软件，再运行 `start` 生成 `config.yaml` 并恢复服务。

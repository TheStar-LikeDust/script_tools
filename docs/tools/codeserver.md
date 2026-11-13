# Code-Server 部署 (Deploy)

## 1. 简介

> 宿主机级别的网页端 VSCode 环境，支持在浏览器中直接进行开发。

code-server 直接运行在宿主机上，用 tmux 会话保持后台运行。脚本支持 `init/start/up/stop/rm/purge/reset` 和 `--conf/--name`，不使用 Compose，也没有镜像 `update` 命令。

## 2. 核心配置项

### settings_codeserver.conf

- `SESSION_NAME`: Tmux 会话唯一名称，决定进程的隔离与管理（默认时间戳后缀，如 `codeserver_8421`）。
- `HOST`: 监听 IP（默认 `127.0.0.1`，需公网访问可改为 `0.0.0.0`）。
- `PORT`: 服务监听端口（默认 `8080`）。
- `PASSWORD`: 访问网页环境的认证密码。
- `CONFIG_DIR`: 配置文件存放的相对目录路径（默认 `./data/config`）。
- `USER_DATA_DIR`: 用户运行数据存放的相对目录路径（默认 `./data/user_data`）。

## 3. 备注

- 进程受 tmux 约束：停止服务等价于销毁对应的 tmux 会话。
- 网络隔离差异：非 Docker 环境，不涉及跨容器的网络栈互通机制。
- `init` 只生成缺失 settings、准备目录并在缺少 code-server 时安装；config.yaml 在 `start` 时根据 settings 生成。
- settings 修改后需先 `stop` 再 `start`；已有同名 tmux 会话时 `start` 会跳过。
- `--conf PATH` 的父目录须已存在，`CONFIG_DIR` 与 `USER_DATA_DIR` 按该目录解析相对路径；`--name NAME` 只在首次生成 settings 时写入会话名。同目录多个配置默认共用数据路径，多开时应使用独立配置目录或不同相对路径。

## 4. 快速执行

```bash
cd tools/codeserver

# Generate settings, then edit settings_codeserver.conf before starting.
bash cli.sh init
bash cli.sh start

# Use init + start when settings are ready.
bash cli.sh up

# Stop the session; rm has the same behavior.
bash cli.sh stop
bash cli.sh rm
# DANGER: permanently delete configured local data directories.
bash cli.sh purge
# DANGER: also delete settings*.conf in the configuration directory.
bash cli.sh reset
```

## 5. 命令解释

以下代码展示 CLI 内部操作，变量由 settings 和脚本路径计算得到；日常使用 `bash cli.sh <命令>`。

#### init

生成缺失的 settings 和数据目录；如缺少 code-server，执行官方安装脚本。此步骤不生成 config.yaml，也不安装 tmux。

```bash
curl -fsSL https://code-server.dev/install.sh | sh
```

#### start

要求 tmux 已安装；没有同名会话时生成 config.yaml，再创建后台会话启动 code-server。

```bash
tmux new-session -d -s "$SESSION_NAME" "code-server --config \"$abs_config_dir/config.yaml\" --user-data-dir \"$abs_user_data_dir\""
```

#### up

组合执行 `init` 与 `start` 的命令，提供一键式拉起体验。

```bash
do_init && do_start
```

#### stop

查找并强制终结当前实例对应的 tmux 守护会话。

```bash
tmux kill-session -t "$SESSION_NAME"
```

#### rm

与 `stop` 逻辑一致。因宿主机直接运行，无虚拟容器残留需清理。

```bash
do_stop
```

#### purge

中断会话后，删除当前配置指定的 CONFIG_DIR 和 USER_DATA_DIR，保留 settings。

```bash
rm -rf "$abs_config_dir"
rm -rf "$abs_user_data_dir"
```

#### reset

执行 purge 后，删除配置目录中的全部 `settings*.conf` 文件；同目录内其他实例的 settings 也会被匹配。自定义配置文件名若不符合该模式则不会删除。

```bash
do_purge
rm -f "$CONF_DIR"/settings*.conf
```

## 6. 复制恢复

停止 tmux 会话后，复制脚本、templates、settings 和配置指定的数据目录。目标机器需准备 code-server 与 tmux，再执行 `start` 重新生成 config.yaml；复制目录不会安装宿主机程序。

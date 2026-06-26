# Code-Server 部署 (Deploy)

## 1. 简介

> 宿主机级别的网页端 VSCode 环境，支持在浏览器中直接进行开发。

该服务直接运行在宿主物理机上，非 Docker 化。部署脚本集成了官方下载指令，并使用 tmux 作为守护进程进行后台隔离运行。支持与其他基于 Docker 的服务使用相同的生命周期命令集与沙箱化目录隔离机制。

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

## 4. 快速执行

```bash
cd tools/codeserver

# 常规分步拉起（推荐）：先生成配置、按需修改 settings_codeserver.conf 后再启动
bash cli.sh init
bash cli.sh start

# 快捷拉起：跳过配置确认直接启动
bash cli.sh up

# 停止 / 删除 / 销毁
bash cli.sh stop
bash cli.sh rm
bash cli.sh purge
```

## 5. 命令解释

#### init
生成 `settings_codeserver.conf` 核心配置与相关的 `config.yaml` 文件；如缺失依赖将自动执行下载安装。
```bash
curl -fsSL https://code-server.dev/install.sh | sh
```

#### start
检测 tmux 工具并在后台创建独立会话，以守护模式拉起进程。
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
中断会话后，彻底删除以配置文件所在目录为锚点派生的所有数据资源。
```bash
rm -rf "$abs_config_dir"
rm -rf "$abs_user_data_dir"
```

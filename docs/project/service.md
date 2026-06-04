# 服务设计理念 (Service Design)

本文件说明“一个服务 / 一个目录”如何组织与部署，以 `deploy_apps/openwebui` 的实现为基准范例。

## 1. 目录即服务 (Service as a Directory)

一个服务运行所需的全部元素都内聚在它专属的文件夹里：控制脚本 `cli.sh`、配置模板 `templates/*.tpl`、生成的 `settings.conf`、持久化数据 `./data`。迁移或备份只需打包拷贝这一个目录。

源文件与生成物的区分：

- 源文件（纳入版本管理）：`cli.sh`、`templates/*.tpl`、该服务的说明文档。
- 生成物（不提交，由 `.gitignore` 忽略）：`settings.conf`、`compose.yml`（若有）、Casdoor 的 `config/app.conf`、各服务的 `data/`。

`settings.conf` 含随机密钥/密码，属于本地资产：既不提交，也不会被 `purge` 删除；迁移时与 `data/` 一起打包。

## 2. 三层架构

- `deploy/`：原子基础服务（如 ParadeDB、RustFS、Redis），可独立部署、启停、销毁，通过 `INSTANCE_NAME` 与端口多开隔离。
- `deploy_apps/`：复合应用（如 LobeChat、Open WebUI），通过向下级联调用组装底层原子服务，配置上提供“内置隔离组装”与“连接外部已有服务”两种分支。
- `tools/`：宿主机（非 docker 级）的开发环境与工具（如 code-server、tmux）。

## 3. 编排方式：单容器优先用原生 docker run

容器编排按服务复杂度二选一，并以原生 docker run 为首选：

- 单容器服务（首选）：直接用原生 `docker run` 管理，不依赖 docker compose，只需装了 `docker`。容器配置（端口、挂载、环境变量、`--add-host`、`--restart`）直接写在 `cli.sh` 的 `do_start` 里。范例：`deploy_apps/openwebui`。
- 多服务应用：用 `docker compose` 做编排、网络与启动顺序（如 `lobechat`：DB + Redis + S3 + Casdoor + 主程序 + 自定义网络）。

reason why 偏向 docker run：

- 依赖更少：只要 docker，不需要 compose 插件。
- 更透明、可复现：启动命令就摆在 `cli.sh` 里。想手动调试时，照着 `source settings.conf` 后直接 `docker run` 即可，行为与脚本一致。
- 去除渲染脆弱性：单容器无需 `compose.yml.tpl`，少一层 `sed` 模板渲染。

注意：`compose.yml` / `compose.yml.tpl` 不是“目录即服务”的必备资产，仅多服务模式才需要。项目的长期方向是尽量减少乃至取消对 compose 的依赖。

## 4. 配置注入：source + -e 透传，不用 --env-file

单容器服务的配置注入约定：`cli.sh` 先 `set -a; source settings.conf; set +a`，再用 `docker run -e VAR` 透传同名环境变量给容器。

reason why：

- 不用 `--env-file`：`docker run --env-file` 不会剥除引号，含空格或斜杠的值（如 `USER_AGENT`）会把引号当成值的一部分，出错。
- 不用 `sed` 把变量渲染进 compose/命令：含特殊字符的值在 `sed` 替换里极易转义出错。
- 用 bash `source`：bash 能正确解析引号与空格，`settings.conf` 本身就是一个可被人手动 `source` 的纯净文件，保证脚本与手动运行行为一致。

## 5. 实例命名与多开隔离 (INSTANCE_NAME)

实例名由 `cli.sh init` 首次生成 `settings.conf` 时分配，采用时间戳后缀，保证同机多开不冲突：

- 独立部署：`<服务名>_<4位时间戳>`，如 `paradedb_8421`。
- 被 app 级联部署：上层通过 `export APP_PREFIX="${INSTANCE_NAME}"` 注入前缀，底层命名为 `<服务名>_<APP_PREFIX>_<4位时间戳>`，如 `paradedb_lobechat_8421_9032`。

派生命名约定：

- 容器名：直接等于 `INSTANCE_NAME`。
- 持久化目录：`./data/${INSTANCE_NAME}_data`。
- compose 项目名（仅 compose 模式适用）：`${INSTANCE_NAME}_proj`。

另外，`do_init` / `do_start` 会 `mkdir -p ./data/${INSTANCE_NAME}_data` 预建挂载目录，避免 Docker 以 root 身份自动创建导致权限问题。

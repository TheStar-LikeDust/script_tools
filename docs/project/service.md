# 服务设计理念 (Service Design)

本文件说明“一个服务 / 一个目录”如何组织与部署，以 `deploy_apps/openwebui` 的实现为基准范例。

## 1. 目录即服务 (Service as a Directory)

一个服务运行所需的全部元素都内聚在它专属的文件夹里：控制脚本 `cli.sh`、配置模板 `templates/*.tpl`、生成的 `settings.conf`、持久化数据 `./data`。迁移或备份只需打包拷贝这一个目录。

源文件与生成物的区分：

- 源文件（纳入版本管理）：`cli.sh`、`templates/*.tpl`、该服务的说明文档。
- 生成物（不提交，由 `.gitignore` 忽略）：`settings.conf`、被嵌入子服务的渲染配置（如 `settings_paradedb.conf`）、Casdoor 渲染的 `app.conf`（位于 `data/<INSTANCE_NAME>_config/`）、各服务的 `data/`。

`settings.conf` 含随机密钥/密码，属于本地资产：既不提交，也不会被 `purge` 删除；迁移时与 `data/` 一起打包。

## 2. 三层架构

- `deploy/`：原子基础服务（如 ParadeDB、RustFS、Redis），可独立部署、启停、销毁，通过 `INSTANCE_NAME` 与端口多开隔离。
- `deploy_apps/`：复合应用（如 LobeChat、Open WebUI），通过向下级联调用组装底层原子服务，配置上提供“内置隔离组装”与“连接外部已有服务”两种分支。
- `tools/`：宿主机（非 docker 级）的开发环境与工具（如 code-server、tmux）。

## 3. 编排方式：全面使用原生 docker run

容器编排全部使用原生 docker run，不依赖 docker compose，按服务复杂度分两类：

- 单容器服务：直接用原生 `docker run` 管理，只需装了 `docker`。容器配置（端口、挂载、环境变量、`--network`、`--restart`）直接写在 `cli.sh` 的 `do_start` 里。范例：`deploy_apps/openwebui`。
- 自带依赖的集合服务：主体 + 一个或多个附带依赖时，用 docker run + 委托式级联组装（见第 6 节）。上层在 `do_start` 里创建一个 app 级 user-defined network，把附带容器 `docker network connect` 进来，彼此按容器名互通。范例：`deploy_apps/casdoor`（casdoor + 附带 paradedb）、`deploy_apps/lobechat`（LobeChat + 级联 paradedb/redis/rustfs 与同级 casdoor）。

reason why 偏向 docker run：

- 依赖更少：只要 docker，不需要 compose 插件。
- 更透明、可复现：启动命令就摆在 `cli.sh` 里。想手动调试时，照着 `source settings.conf` 后直接 `docker run` 即可，行为与脚本一致。
- 去除渲染脆弱性：无需 `compose.yml.tpl`，少一层 `sed` 模板渲染。

注意：项目已全面去除 docker compose，不再使用 `compose.yml` / `compose.yml.tpl`；所有服务（含多依赖的 lobechat）都用 docker run + 委托式级联。

## 4. 配置注入：source + -e 透传，不用 --env-file

单容器服务的配置注入约定：`cli.sh` 先 `set -a; source settings.conf; set +a`，再用 `docker run -e VAR` 透传同名环境变量给容器。

reason why：

- 不用 `--env-file`：`docker run --env-file` 不会剥除引号，含空格或斜杠的值（如 `USER_AGENT`）会把引号当成值的一部分，出错。
- 不用 `sed` 把变量渲染进 compose/命令：含特殊字符的值在 `sed` 替换里极易转义出错。
- 用 bash `source`：bash 能正确解析引号与空格，`settings.conf` 本身就是一个可被人手动 `source` 的纯净文件，保证脚本与手动运行行为一致。

## 5. 实例命名与多开隔离 (INSTANCE_NAME)

实例名由 `cli.sh init` 首次生成 `settings.conf` 时分配，采用时间戳后缀，保证同机多开不冲突：

- 独立部署：`<服务名>_<4位时间戳>`，如 `paradedb_8421`。
- 被 app 委托部署：上层用 `--name` 显式指定底层实例名（见第 6 节），通常取 `<服务名>_<上层实例名>`，如 `paradedb_casdoor_3953`（与上层共享时间戳，单一来源、可读）。

派生命名约定：

- 容器名：直接等于 `INSTANCE_NAME`。
- 持久化目录：`<配置文件所在目录>/data/${INSTANCE_NAME}_data`（默认即服务自身目录下的 `./data`）。
- 渲染配置目录（如 Casdoor 的 app.conf）：`data/${INSTANCE_NAME}_config`，与数据目录平级，避免配置混入运行数据。

另外，`do_init` / `do_start` 会 `mkdir -p` 预建挂载目录，避免 Docker 以 root 身份自动创建导致权限问题。

## 6. 委托式级联与基础服务通用参数 (--conf / --name)

集合服务（如 `casdoor`）不复制底层服务逻辑，而是把底层 `cli.sh` 当函数调用，这就是“委托式级联”。为支持被嵌入，基础服务的 `cli.sh` 提供两个通用参数：

- `--conf PATH`：指定该实例的 `settings.conf` 位置（默认 `<脚本目录>/settings.conf`）。数据目录由该配置文件所在目录推导为 `<dir-of-conf>/data/<INSTANCE_NAME>_data`。上层借此把底层的配置与数据都收纳进自己的目录。
- `--name NAME`：`init` 时写入的完整实例名（默认自动 `<服务名>_<4位时间戳>`）。上层借此给底层一个可读、与自身关联的名字。

委托约定（以 casdoor 嵌入 paradedb 为例）：

- 渲染：上层在自身目录下渲染底层配置（如 `settings_paradedb.conf`），随后 `bash ../../deploy/paradedb/cli.sh <cmd> --conf <该配置> --name paradedb_<上层实例名>`。
- 生命周期：上层的 `init/start/stop/rm/purge/status` 逐条转发给底层，保证级联整体的幂等与一致清理。
- 网络：上层 `start` 时 `docker network create` 一个 app 级 user-defined network，把底层容器 `docker network connect` 进来，二者按容器名 + 内部端口直连。基础服务自身保持网络无关——它的 `settings.conf` 不固化网络名，由上层负责组网。

reason why 委托而非 compose：底层逻辑只在一处维护（基础服务的 `cli.sh`），上层零重复；同时延续“单容器优先 docker run”，避免为附带一个依赖就引入 compose。

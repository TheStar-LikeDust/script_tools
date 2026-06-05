# Casdoor

## 服务简介

Casdoor 是一个支持 OAuth 2.0 / OIDC / SAML / CAS 的 UI 优先型身份与访问管理（IAM）平台，承担统一用户认证、单点登录（SSO）与权限中心的角色。它使用 `casbin/casdoor` 镜像，单容器即可运行，本身不存储业务数据，**强依赖一个 PostgreSQL**。

与基础服务一样，Casdoor 用原生 `docker run` 管理，不依赖 docker compose。

## 两种部署模式

`init` 时二选一，由 `settings.conf` 的 `WITH_BUNDLED_DB` 开关记录，`start` 据此决定是否附带拉起数据库：

- **附带数据库（默认）**：`bash cli.sh init`。Casdoor 顺带「附带执行」一套 `deploy/paradedb` 的 cli 命令，在**本目录**托管一个 paradedb 实例（命名 `paradedb_casdoor_<时间戳>`，与 casdoor 共享时间戳）。Casdoor 自身不管理任何 PG 设置——端口、密码等全部由 paradedb 的 cli 与它自己的配置文件 `casdoor_paradedb.conf` 负责，Casdoor 只在渲染 `app.conf` 时读回连接信息。
- **外部数据库**：`bash cli.sh init --external`。不附带 paradedb，连接你在 `settings.conf` 的 `EXT_DB_*` 里填写的外部 PG（如云数据库）。

> **委托关系**：附带模式本质是把 `deploy/paradedb/cli.sh` 当函数调用：`init/start/stop/rm/purge/status` 都会带上 `--conf casdoor_paradedb.conf` 转发给它，详见 `docs/paradedb.md` 的「作为子服务嵌入」。

> **运行期连通**：不建共享 docker 网络。Casdoor 容器加 `--add-host host.docker.internal:host-gateway`，通过宿主机发布端口连到数据库（附带模式连 paradedb 的发布端口；外部模式连你填的地址）。

> **关于 `casdoor` 数据库**：`app.conf` 的 `dataSourceName` 连接的是 bootstrap 库（通常 `postgres`），`dbName` 才是 Casdoor 实际使用的应用库（默认 `casdoor`）。首次启动时 Casdoor 自动创建该应用库并初始化表结构。

## 配置文件

附带模式下目录里有两个配置文件（均为生成物，已被 `.gitignore` 忽略）：

`settings.conf`（Casdoor 自身，你主要编辑这个）：

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `casdoor_8421`），决定容器名与数据目录。
- `CASDOOR_PORT`: 对外暴露的 Web UI / API 端口（容器内 `8000`）。
- `CASDOOR_DB_NAME`: Casdoor 使用的应用库名（默认 `casdoor`，自动创建）。
- `WITH_BUNDLED_DB`: `true` 附带 paradedb / `false` 用外部库。
- `EXT_DB_HOST` / `EXT_DB_PORT` / `EXT_DB_USER` / `EXT_DB_PASSWORD` / `EXT_DB_NAME`: 仅外部模式使用，`EXT_DB_NAME` 为 bootstrap 库（通常 `postgres`）。

`casdoor_paradedb.conf`（附带模式下由 paradedb cli 生成，你一般不用动）：含该 paradedb 实例的 `INSTANCE_NAME`、`DB_PORT`、`DB_USER`、`DB_PASSWORD`、`DB_NAME`。

## 快速执行

```bash
cd deploy_apps/casdoor

# 附带数据库，一键拉起（init + start，会同时起 paradedb 与 casdoor）
bash cli.sh up

# 或分步
bash cli.sh init
bash cli.sh start

# 使用外部数据库：先 init 生成配置，填好 settings.conf 的 EXT_DB_*，再 start
bash cli.sh init --external
bash cli.sh start
```

## 命令解释

路径锚定：脚本运行时计算自身所在目录 `SCRIPT_DIR`，配置/数据均在该目录下，配置里不写死绝对路径，便于整体复制/移动。附带的 paradedb 通过 `--conf "$SCRIPT_DIR/casdoor_paradedb.conf"` 调用，数据落在 `$SCRIPT_DIR/data/` 下。

### `init`（可选 `--external`）

生成 `settings.conf`（仅首次）；附带模式下委托 paradedb 生成 `casdoor_paradedb.conf` 与其数据目录；再读回连接渲染 `config/app.conf`，并预建 casdoor 数据目录。不启动容器。

```bash
# 1) casdoor 自身配置（仅首次）
sed -e "s/{{INSTANCE_NAME}}/casdoor_<时间戳>/g" \
    -e "s/{{CASDOOR_PORT}}/<随机端口>/g" \
    -e "s/{{WITH_BUNDLED_DB}}/true/g" \
    "$SCRIPT_DIR/templates/settings.conf.tpl" > settings.conf

# 2) 委托 paradedb（附带模式）——配置与数据都落在 casdoor 目录
bash ../../deploy/paradedb/cli.sh init \
    --conf "$SCRIPT_DIR/casdoor_paradedb.conf" \
    --name "paradedb_casdoor_<时间戳>"

# 3) 读回 DB 连接渲染 app.conf（dbname=bootstrap 库, dbName=casdoor 应用库）
sed -e "s#{{CASDOOR_DB_USER}}#postgres#g" \
    -e "s#{{CASDOOR_DB_PASSWORD}}#<paradedb 随机密码>#g" \
    -e "s#{{CASDOOR_DB_HOST}}#host.docker.internal#g" \
    -e "s#{{CASDOOR_DB_PORT}}#<paradedb 发布端口>#g" \
    -e "s#{{CASDOOR_DB_BOOTSTRAP}}#postgres#g" \
    -e "s#{{CASDOOR_DB_NAME}}#casdoor#g" \
    "$SCRIPT_DIR/templates/app.conf.tpl" > config/app.conf

mkdir -p "$SCRIPT_DIR/data/${INSTANCE_NAME}_data"
```

### `start`

先重渲 `app.conf`（让 `settings.conf` 的改动生效）；附带模式下先起 paradedb 并等其健康，再起 casdoor。

```bash
# 附带模式：先拉起数据库并等健康
bash ../../deploy/paradedb/cli.sh start --conf "$SCRIPT_DIR/casdoor_paradedb.conf"

# 起 casdoor（已存在则仅 docker start）
docker run -d \
    --name "${INSTANCE_NAME}" \
    -p "${CASDOOR_PORT}:8000" \
    --add-host host.docker.internal:host-gateway \
    -e RUNNING_IN_DOCKER=true \
    -v "$SCRIPT_DIR/config/app.conf:/conf/app.conf" \
    -v "$SCRIPT_DIR/data/${INSTANCE_NAME}_data:/data" \
    --restart unless-stopped \
    casbin/casdoor:latest
```

### `up`

先 `init` 再 `start`。

### `stop`

停止 casdoor；附带模式下再停 paradedb。

```bash
docker stop "${INSTANCE_NAME}"
bash ../../deploy/paradedb/cli.sh stop --conf "$SCRIPT_DIR/casdoor_paradedb.conf"   # 附带模式
```

### `rm`

删除容器，保留数据与配置；附带模式下连带删除 paradedb 容器。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
bash ../../deploy/paradedb/cli.sh rm --conf "$SCRIPT_DIR/casdoor_paradedb.conf"      # 附带模式
```

### `purge`

删除容器并删除本地数据目录，保留配置；附带模式下连带 `purge` paradedb（删 PG 容器与其数据，保留 `casdoor_paradedb.conf`）。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
rm -rf "$SCRIPT_DIR/data/${INSTANCE_NAME}_data"
bash ../../deploy/paradedb/cli.sh purge --conf "$SCRIPT_DIR/casdoor_paradedb.conf"   # 附带模式
```

### `status`

显示 casdoor 容器状态；附带模式下再显示 paradedb 状态。

### 无参 / 未知参数

打印 Usage 帮助。

## 其他补充

- **镜像版本**：当前固定 `casbin/casdoor:latest`，需可复现可锁定具体标签。
- **外部反代**：可在 Docker 外层嵌套 Nginx 实现域名与 HTTPS。
- **依赖 repo 结构**：附带模式通过相对路径 `../../deploy/paradedb` 定位 paradedb 脚本（脚本为共享代码）；casdoor 目录里的配置与数据是可随目录迁移的资产，整体搬迁请连同 repo 一起。

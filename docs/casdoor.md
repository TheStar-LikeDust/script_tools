# Casdoor 部署 (Deploy)

## 1. 简介

> Casdoor 是一个支持 OAuth 2.0 / OIDC / SAML / CAS 的 UI 优先型身份与访问管理（IAM）平台，作为多应用架构的统一认证入口，提供开箱即用的集中式登录页、用户管理看板以及单点登录（SSO）与细粒度权限控制。

它使用 `casbin/casdoor` 镜像，单容器即可运行，本身不存储业务数据，强依赖一个 PostgreSQL。

## 2. 部署特性

`init` 时二选一，由 `settings.conf` 的 `WITH_BUNDLED_DB` 开关记录，`start` 据此决定是否附带拉起数据库：

- 附带数据库（默认）：`bash cli.sh init`。Casdoor 顺带「附带执行」一套 `deploy/paradedb` 的 cli 命令，在本目录托管一个 paradedb 实例（命名 `paradedb_casdoor_<时间戳>`，与 casdoor 共享时间戳）。Casdoor 自身不管理任何 PG 设置——端口、密码等全部由 paradedb 的 cli 与它自己的配置文件 `settings_paradedb.conf` 负责，Casdoor 只在渲染 `app.conf` 时读回连接信息。
- 外部数据库：`bash cli.sh init --external`。不附带 paradedb，连接在 `settings.conf` 的 `EXT_DB_*` 里填写的外部 PG（如云数据库）。

> 委托关系：附带模式本质是把 `deploy/paradedb/cli.sh` 当函数调用：`init/start/stop/rm/purge/status` 都会带上 `--conf settings_paradedb.conf` 转发给它，详见 `docs/paradedb.md` 的「作为子服务嵌入」。

> 运行期连通（附带模式）：`start` 时创建一个 app 级 user-defined network `${INSTANCE_NAME}_net`，把附带的 paradedb 容器 `docker network connect` 进来，casdoor 也以 `--network` 加入；二者通过容器名 + 内部端口 5432 直连。这样绕开 Linux 上 `host-gateway` / 宿主机防火墙导致的连接超时。网络概念只存在于 app 集合服务，基础服务 `deploy/paradedb` 保持网络无关。

> 运行期连通（外部模式）：不加自定义网络，casdoor 走默认 bridge，直接连 `EXT_DB_*` 指向的外部地址。

> 关于 `casdoor` 数据库：`app.conf` 的 `dataSourceName` 连接的是 bootstrap 库（通常 `postgres`），`dbName` 才是 Casdoor 实际使用的应用库（默认 `casdoor`）。首次启动时 Casdoor 自动创建该应用库并初始化表结构。

## 3. 核心配置项 (settings.conf)

附带模式下目录里有两个配置文件（均为生成物，已被 `.gitignore` 忽略）：

`settings.conf`（Casdoor 自身，主要编辑此文件）：

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `casdoor_8421`），决定容器名与数据目录。
- `CASDOOR_PORT`: 对外暴露的 Web UI / API 端口（容器内 `8000`）。
- `CASDOOR_DB_NAME`: Casdoor 使用的应用库名（默认 `casdoor`，自动创建）。
- `WITH_BUNDLED_DB`: `true` 附带 paradedb / `false` 用外部库。
- `EXT_DB_HOST` / `EXT_DB_PORT` / `EXT_DB_USER` / `EXT_DB_PASSWORD` / `EXT_DB_NAME`: 仅外部模式使用，`EXT_DB_NAME` 为 bootstrap 库（通常 `postgres`）。

`settings_paradedb.conf`（附带模式下由 paradedb cli 生成，一般无需修改）：含该 paradedb 实例的 `INSTANCE_NAME`、`DB_PORT`、`DB_USER`、`DB_PASSWORD`、`DB_NAME`。

## 4. 备注

- `app.conf` 是什么 / 放哪：它是喂给 casdoor 程序本体的 INI 配置（生成物，由 `settings.conf` + DB 连接渲染而来），落在该实例的独立配置目录 `data/casdoor_<时间戳>_config/app.conf`，与运行数据目录 `data/casdoor_<时间戳>_data/` 平级并列、互不混淆，启动时挂载为容器内 `/conf/app.conf`。与 `settings.conf`（本 cli 的配置）、`settings_paradedb.conf`（附带库的配置）职责不同。
- app.conf 会被覆盖：`start` 每次按 `settings.conf` 重渲 app.conf（截断重写、保持 inode，不会断开正在使用的 bind mount）。`_config` 只放 app.conf、`_data` 只放 casdoor 运行数据，容器内分别挂为 `/conf/app.conf` 与 `/data`；`purge` 会同时删除这两个目录，但保留根目录的 `settings.conf` / `settings_paradedb.conf`。请勿手改 app.conf，要调整改 `settings.conf`。

## 5. 快速执行

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

## 6. 命令解释

路径锚定：脚本运行时计算自身所在目录 `SCRIPT_DIR`，配置/数据均在该目录下，配置里不写死绝对路径，便于整体复制/移动。附带的 paradedb 通过 `--conf "$SCRIPT_DIR/settings_paradedb.conf"` 调用，数据落在 `$SCRIPT_DIR/data/` 下。

注：`--external` 是 init-only 开关，只在 `init`/`up` 解析并写入 `settings.conf` 的 `WITH_BUNDLED_DB`；其余命令一律读 `settings.conf`，无需也不接受该 flag。

### `init`（可选 `--external`）

生成 `settings.conf`（仅首次）；附带模式下委托 paradedb 生成 `settings_paradedb.conf` 与其数据目录；再读回连接渲染 `data/casdoor_<时间戳>_config/app.conf`，并预建 casdoor 数据目录。不启动容器。

```bash
# 1) casdoor 自身配置（仅首次）
sed -e "s/{{INSTANCE_NAME}}/casdoor_<时间戳>/g" \
    -e "s/{{CASDOOR_PORT}}/<随机端口>/g" \
    -e "s/{{WITH_BUNDLED_DB}}/true/g" \
    "$SCRIPT_DIR/templates/settings.conf.tpl" > settings.conf

# 2) 委托 paradedb（附带模式）——配置与数据都落在 casdoor 目录
bash ../../deploy/paradedb/cli.sh init \
    --conf "$SCRIPT_DIR/settings_paradedb.conf" \
    --name "paradedb_casdoor_<时间戳>"

# 3) 读回 DB 连接渲染 app.conf（附带模式：host=paradedb 容器名, port=5432 内部端口）
sed -e "s#{{CASDOOR_DB_USER}}#postgres#g" \
    -e "s#{{CASDOOR_DB_PASSWORD}}#<paradedb 随机密码>#g" \
    -e "s#{{CASDOOR_DB_HOST}}#paradedb_casdoor_<时间戳>#g" \
    -e "s#{{CASDOOR_DB_PORT}}#5432#g" \
    -e "s#{{CASDOOR_DB_BOOTSTRAP}}#postgres#g" \
    -e "s#{{CASDOOR_DB_NAME}}#casdoor#g" \
    "$SCRIPT_DIR/templates/app.conf.tpl" > "$SCRIPT_DIR/data/${INSTANCE_NAME}_config/app.conf"
```

### `start`

先重渲 `app.conf`（让 `settings.conf` 的改动生效）；附带模式下先起 paradedb 并等其健康，再起 casdoor。

```bash
# 附带模式：建网络 -> 起库 -> 把库接入网络 -> 等健康
docker network inspect "${INSTANCE_NAME}_net" >/dev/null 2>&1 || docker network create "${INSTANCE_NAME}_net"
bash ../../deploy/paradedb/cli.sh start --conf "$SCRIPT_DIR/settings_paradedb.conf"
docker network connect "${INSTANCE_NAME}_net" "paradedb_${INSTANCE_NAME}"

# 起 casdoor（附带模式带 --network；外部模式无此参数；已存在则仅 docker start）
docker run -d \
    --name "${INSTANCE_NAME}" \
    --network "${INSTANCE_NAME}_net" \
    -p "${CASDOOR_PORT}:8000" \
    -e RUNNING_IN_DOCKER=true \
    -v "$SCRIPT_DIR/data/${INSTANCE_NAME}_config/app.conf:/conf/app.conf" \
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
bash ../../deploy/paradedb/cli.sh stop --conf "$SCRIPT_DIR/settings_paradedb.conf"   # 附带模式
```

### `rm`

删除容器，保留数据与配置；附带模式下连带删除 paradedb 容器与 app 网络。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
bash ../../deploy/paradedb/cli.sh rm --conf "$SCRIPT_DIR/settings_paradedb.conf"      # 附带模式
docker network rm "${INSTANCE_NAME}_net"                                             # 附带模式
```

### `purge`

删除容器并删除本地数据目录，保留配置；附带模式下连带 `purge` paradedb（删 PG 容器与其数据，保留 `settings_paradedb.conf`）并删除 app 网络。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
rm -rf "$SCRIPT_DIR/data/${INSTANCE_NAME}_data" "$SCRIPT_DIR/data/${INSTANCE_NAME}_config"
bash ../../deploy/paradedb/cli.sh purge --conf "$SCRIPT_DIR/settings_paradedb.conf"   # 附带模式
docker network rm "${INSTANCE_NAME}_net"                                             # 附带模式
```

### `status`

显示 casdoor 容器状态；附带模式下再显示 paradedb 状态。

### 无参 / 未知参数

打印 Usage 帮助。

## 7. 其他补充

- 镜像版本：当前固定 `casbin/casdoor:latest`，需可复现可锁定具体标签。
- 外部反代：可在 Docker 外层嵌套 Nginx 实现域名与 HTTPS。
- 依赖 repo 结构：附带模式通过相对路径 `../../deploy/paradedb` 定位 paradedb 脚本（脚本为共享代码）；casdoor 目录里的配置与数据是可随目录迁移的资产，整体搬迁请连同 repo 一起。

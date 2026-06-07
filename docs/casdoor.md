# Casdoor 部署 (Deploy)

## 1. 简介

> Casdoor 是一个支持 OAuth 2.0 / OIDC / SAML / CAS 的 UI 优先型身份与访问管理（IAM）平台，作为多应用架构的统一认证入口，提供开箱即用的集中式登录页、用户管理看板以及单点登录（SSO）与细粒度权限控制。

它本身不存储业务数据，强依赖 PostgreSQL。部署时提供分歧路由：默认 `init` 会通过级联机制拉起并动态组网专属的 ParadeDB 实例；使用 `init --external` 则彻底剥离内部数据库依赖，转为连接外部目标库。

## 2. 核心配置项

### settings.conf

- `INSTANCE_NAME`: 实例名（时间戳后缀，如 `casdoor_8421`），决定容器名与数据目录。
- `CASDOOR_PORT`: 对外暴露的 Web UI / API 端口（容器内 `8000`）。
- `CASDOOR_DB_NAME`: Casdoor 使用的应用库名（默认 `casdoor`，自动创建）。
- `WITH_BUNDLED_DB`: `true` 附带 paradedb / `false` 用外部库。
- `EXT_DB_HOST` / `EXT_DB_PORT` / `EXT_DB_USER` / `EXT_DB_PASSWORD` / `EXT_DB_NAME`: 仅外部模式使用，`EXT_DB_NAME` 为 bootstrap 库（通常 `postgres`）。

### settings_paradedb.conf

- 包含附带的 paradedb 实例的连接凭证。

## 3. 备注

- 内部配置覆写机制：除部署层面的 `settings.conf` 外，每次执行 `start` 还会动态渲染出供 Casdoor 程序本体读取的 INI 配置，落盘在专属目录 `data/<实例名>_config/app.conf` 并挂载入容器。请勿手动修改此 `app.conf`，所有相关配置调整必须在根目录的 `settings.conf` 中进行。

## 4. 快速执行

```bash
cd deploy_apps/casdoor

# 常规分步拉起（推荐）：先生成配置、按需修改 settings.conf 后再启动
bash cli.sh init
bash cli.sh start

# 附带数据库，一键拉起（跳过配置直接启动，会同时起 paradedb 与 casdoor）
bash cli.sh up

# 使用外部数据库：先 init 生成配置，填好 settings.conf 的 EXT_DB_*，再 start
bash cli.sh init --external
bash cli.sh start

# 停止运行
bash cli.sh stop

# 销毁容器（保留配置与 data/ 数据目录）
bash cli.sh rm

# 危险操作：彻底销毁容器，并删除挂载的 data/ 数据目录
bash cli.sh purge
```

## 5. 命令解释

注：`--external` 是 init-only 开关，只在 `init`/`up` 阶段解析并写入 `settings.conf` 的 `WITH_BUNDLED_DB` 项；其余生命周期命令一律从 `settings.conf` 读取，无需也不接受该 flag。

#### init（可选 `--external`）

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

#### start

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

#### up

先 `init` 再 `start`。

#### stop

停止 casdoor；附带模式下再停 paradedb。

```bash
docker stop "${INSTANCE_NAME}"
bash ../../deploy/paradedb/cli.sh stop --conf "$SCRIPT_DIR/settings_paradedb.conf"   # 附带模式
```

#### rm

删除容器，保留数据与配置；附带模式下连带删除 paradedb 容器与 app 网络。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
bash ../../deploy/paradedb/cli.sh rm --conf "$SCRIPT_DIR/settings_paradedb.conf"      # 附带模式
docker network rm "${INSTANCE_NAME}_net"                                             # 附带模式
```

#### purge

删除容器并删除本地数据目录，保留配置；附带模式下连带 `purge` paradedb（删 PG 容器与其数据，保留 `settings_paradedb.conf`）并删除 app 网络。

```bash
docker stop "${INSTANCE_NAME}"; docker rm "${INSTANCE_NAME}"
rm -rf "$SCRIPT_DIR/data/${INSTANCE_NAME}_data" "$SCRIPT_DIR/data/${INSTANCE_NAME}_config"
bash ../../deploy/paradedb/cli.sh purge --conf "$SCRIPT_DIR/settings_paradedb.conf"   # 附带模式
docker network rm "${INSTANCE_NAME}_net"                                             # 附带模式
```

#### status

显示 casdoor 容器状态；附带模式下再显示 paradedb 状态。

#### 无参 / 未知参数

打印 Usage 帮助。

## 6. 其他补充

- 镜像版本：当前固定 `casbin/casdoor:latest`，需可复现可锁定具体标签。
- 外部反代：可在 Docker 外层嵌套 Nginx 实现域名与 HTTPS。
- 依赖 repo 结构：附带模式通过相对路径 `../../deploy/paradedb` 定位 paradedb 脚本（脚本为共享代码）；casdoor 目录里的配置与数据是可随目录迁移的资产，整体搬迁请连同 repo 一起。

# Casdoor 部署 (Deploy)

## 1. 简介

> Casdoor 是支持 OAuth 2.0、OIDC、SAML 等协议的身份与访问管理平台。

本目录通过 Docker Compose 仅部署 Casdoor。PostgreSQL 必须独立启动，由管理员预建 Casdoor 专用数据库和账号；应用命令不创建、启停或清理数据库。

## 2. 核心配置项

### settings_casdoor.conf

- `INSTANCE_NAME`：Compose 项目名、容器名及本地数据目录前缀，只允许小写字母、数字、下划线和连字符，以字母或数字开头。
- `IMAGE`：默认 `casbin/casdoor:latest`，可指定固定标签。
- `CASDOOR_PORT`：宿主机 Web 端口，容器内部固定 `8000`。
- `DOCKER_NETWORK`：管理员已创建的共享网络名；留空时使用本项目私有网络。
- `DB_HOST` / `DB_PORT`：PostgreSQL 地址和端口，端口默认 `5432`。
- `DB_NAME`：预先创建的专用业务库，默认 `casdoor`；本脚本支持以字母或下划线开头、仅含字母、数字和下划线的库名。
- `DB_USER` / `DB_PASSWORD`：该业务库的专用账号和密码；不得填写共用的数据库超级账号。
- `DB_SSLMODE`：PostgreSQL SSL 模式，默认 `disable`；远程接入按服务端配置调整。

### data/<INSTANCE_NAME>_config/app.conf

Casdoor 程序读取的 INI 配置，包含数据库凭据，以 `600` 权限保存并只读挂载到 `/conf/app.conf`。`start` / `update` 从 settings 重新生成，需长期保留的调整应写入 settings 或 `templates/app.conf.tpl`。

## 3. 备注

- `init` 先生成缺失的 settings，再生成 `settings_casdoor.compose.yaml`，不要求当时已填数据库地址，也不连接数据库。自定义 `--conf` 时，YAML 使用相同文件名前缀。
- `start` / `update` 要求完整的 `DB_*`，数据库与账号须预先创建；`init` 不覆盖已有 settings，也不自动补写字段。
- 数据库 DSN 使用 PostgreSQL 单引号规则转义，再单独处理模板替换转义，支持密码中的空格、引号、反斜线和 `$`；所有连接项必须为单行。settings 仍是 Bash 语法，例如字面值 `$` 应放在单引号中。
- `app.conf` 内容摘要作为 Compose label，配置变化后再执行 `start` 会触发重建。YAML 只保存变量引用，密码不会直接写入 YAML。
- 本应用的本地数据位于 `./data/<INSTANCE_NAME>_data`，业务数据库另由 PostgreSQL 服务目录管理。`purge` 不会清空 Casdoor 的外部数据库，因此不等于重新安装账号系统。
- 同名容器属于其他 Compose 项目或服务时，CLI 拒绝操作；不同部署使用唯一实例名。

## 4. 快速执行

先由管理员启动数据库、建库建号并配置共享网络，再初始化应用：

```bash
cd deploy_apps/casdoor
bash cli.sh init
# Fill DB_* and DOCKER_NETWORK in settings_casdoor.conf.
bash cli.sh start
```

同机共享网络示例（`shared_pg` 是数据库的 `INSTANCE_NAME`）：

```bash
DOCKER_NETWORK='shared_services'
DB_HOST='shared_pg'
DB_PORT='5432'
DB_NAME='casdoor'
DB_USER='casdoor'
DB_PASSWORD='replace-with-the-existing-password'
DB_SSLMODE='disable'
```

管理员预先执行 `docker network create shared_services`，数据库 settings 也需配置 `DOCKER_NETWORK='shared_services'` 并应用配置。使用数据库容器名和内部端口 `5432`；容器内的 `localhost` 指向 Casdoor 自身，不能用它连接另一个数据库容器。

远程服务示例：

```bash
DOCKER_NETWORK=''
DB_HOST='postgres.example.com'
DB_PORT='5432'
DB_NAME='casdoor'
DB_USER='casdoor'
DB_PASSWORD='replace-with-the-existing-password'
DB_SSLMODE='require'
```

远程端口需填写服务实际对外监听端口，地址应可从应用容器访问；SSL 模式和 CA 校验要求需与数据库服务一致。

```bash
# Use init + start when settings are ready.
bash cli.sh up
# Pull and apply the configured image.
bash cli.sh update
bash cli.sh stop
bash cli.sh rm
# DANGER: delete local app data; preserve the external database.
bash cli.sh purge
# DANGER: also delete this app's settings, YAML and generated app.conf.
bash cli.sh reset
```

## 5. 命令解释

以下为日常入口；Compose 调用均由 CLI 带上配置目录、项目名、YAML 路径及导出的 settings 变量。

#### init

生成缺失 settings、刷新 Compose YAML 并预建应用数据目录，保留已有 settings；不启动容器。

```bash
bash cli.sh init
```

#### start

验证数据库字段、生成 app.conf 和 YAML，再执行本项目 `docker compose up -d`。

```bash
bash cli.sh start
```

#### up

依次执行 `init` 和 `start`；新配置未填数据库字段时启动会明确报错。

```bash
bash cli.sh up
```

#### update

刷新应用配置，执行本项目 `docker compose pull` 和 `docker compose up -d`，保留配置及数据。

```bash
bash cli.sh update
```

#### stop

执行本项目 `docker compose stop`，只停止 Casdoor。

```bash
bash cli.sh stop
```

#### rm

执行本项目 `docker compose down`，保留配置和 bind mount 数据，不删除共享网络。

```bash
bash cli.sh rm
```

#### purge

执行 `rm` 后，只通过一次性 root 容器删除 `data/<INSTANCE_NAME>_data`；保留 app.conf、settings 和全部数据库资产。

```bash
bash cli.sh purge
```

#### reset

执行 `purge` 后，只删除当前 `--conf` 文件、对应 YAML 和 `data/<INSTANCE_NAME>_config/app.conf`，不扫描删除其他配置。

```bash
bash cli.sh reset
```

#### network ls

只读展示所配置网络及连接容器，不创建、连接或删除网络。

```bash
bash cli.sh network ls
```

`--conf PATH` 指定配置及数据落点，父目录需预先存在；`--name NAME` 只在首次生成 settings 时生效。CLI 和模板仍从脚本目录读取。

## 6. 升级、备份与复制恢复

`update` 按 settings 中的 `IMAGE` 拉取并应用镜像；默认 `latest` 是滚动标签，可用具体版本或 digest 固定部署。升级前备份应用配置和业务数据库，数据库初始化及结构变更由 Casdoor 镜像执行，CLI 不执行建库 SQL。

停止服务或完成一致性备份后，复制包含 CLI、hooks、templates、settings、生成 YAML、`data/<INSTANCE_NAME>_config/app.conf` 和本地数据的应用目录。数据库从其服务目录独立备份和恢复，不能仅复制应用目录恢复账号与组织数据。

目标机器准备共享网络，保持实例名与数据目录名对应，填写可达的数据库地址及专用凭证后运行 `start`。该命令会从 settings 和模板重建 app.conf，长期配置调整须保存在 settings 或模板内。使用外置 `--conf` 时同时携带对应脚本和模板。

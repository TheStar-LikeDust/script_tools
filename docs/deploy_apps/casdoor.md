# Casdoor 部署 (Deploy)

## 1. 简介

> Casdoor 是支持 OAuth 2.0、OIDC、SAML 等协议的身份与访问管理平台。

本目录通过同一个 Docker Compose 项目部署 Casdoor 和配套 PostgreSQL。`init` 生成连接配置与随机密码，`start` 一起启动；数据库和初始账号由配套 PostgreSQL 在空数据目录首次启动时创建。

## 2. 核心配置项

### settings_casdoor.conf

- `INSTANCE_NAME`：Compose 项目名、容器名及本地数据目录前缀，只允许小写字母、数字、下划线和连字符，以字母或数字开头。
- `IMAGE`：默认 `casbin/casdoor:latest`，可指定固定标签。
- `POSTGRES_IMAGE`：配套数据库镜像，默认 `paradedb/paradedb:latest-pg17`，保留镜像默认的扩展预加载配置。
- `CASDOOR_PORT`：宿主机 Web 端口，容器内部固定 `8000`。
- `DOCKER_NETWORK`：管理员已创建的共享网络名；留空时使用本项目私有网络。
- `DB_HOST` / `DB_PORT`：默认连接 `${INSTANCE_NAME}_postgres:5432`，数据库不发布宿主机端口。
- `DB_NAME`：配套 PostgreSQL 的初始业务库，默认 `casdoor`；库名以字母或下划线开头，仅含字母、数字和下划线。
- `DB_USER` / `DB_PASSWORD`：配套 PostgreSQL 的初始账号与密码；账号默认 `casdoor`，密码在初始化时随机生成并保存。同一组值同时提供给 PostgreSQL 和 Casdoor。
- `DB_SSLMODE`：配套网络内默认 `disable`。

### data/<INSTANCE_NAME>_config/app.conf

Casdoor 程序读取的 INI 配置，包含数据库凭据，以 `600` 权限保存并只读挂载到 `/conf/app.conf`。`start` / `update` 从 settings 重新生成，需长期保留的调整应写入 settings 或 `templates/app.conf.tpl`。

## 3. 备注

- `init` 生成缺失的 settings，补齐已有配置中的空连接字段，再刷新 `settings_casdoor.compose.yaml` 并预建目录，不连接数据库或启动容器。自定义 `--conf` 时，YAML 使用相同文件名前缀。
- 已有非空值和密码保持原值；缺失字段追加，空字段替换原赋值。`start` / `update` 读取保存的配置，等待配套 PostgreSQL 通过 TCP 健康检查后启动 Casdoor。
- 数据库 DSN 使用 PostgreSQL 单引号规则转义，再单独处理模板替换转义，支持密码中的空格、引号、反斜线和 `$`；所有连接项必须为单行。settings 仍是 Bash 语法，例如字面值 `$` 应放在单引号中。
- `app.conf` 内容摘要作为 Compose label，配置变化后再执行 `start` 会触发重建。YAML 只保存变量引用，密码不会直接写入 YAML。
- 应用数据位于 `./data/<INSTANCE_NAME>_data`，数据库位于 `./data/<INSTANCE_NAME>_postgres_data`。重启、`docker rm` 或 CLI 的 `rm` 不删除这些目录，随后运行 `start` 可重建容器并复用数据。
- PostgreSQL 的初始账号、密码和库名只在空数据库目录首次启动时生效；保留数据时不能仅修改 settings 来重置数据库凭证。
- CLI 同时检查 Casdoor 和配套 PostgreSQL 的容器归属；同名容器属于其他 Compose 项目或服务时拒绝操作。不同实例使用不同 `INSTANCE_NAME`，数据库名可以相同，因为各实例有自己的 PostgreSQL。

## 4. 快速执行

默认配套部署无需先启动独立基础服务，也无需手工填写数据库连接：

```bash
cd deploy_apps/casdoor
bash cli.sh init
bash cli.sh start
```

默认使用本项目私有网络；若填写 `DOCKER_NETWORK`，该共享网络须预先存在。Casdoor 通过配套数据库容器名和内部端口连接，容器中的 `localhost` 仅指当前容器。当前默认流程始终生成配套 PostgreSQL，尚未实现按连接字段自动切换为外接数据库。

```bash
# Generate the bundled configuration and start both services.
bash cli.sh up
# Pull and apply both configured images.
bash cli.sh update
bash cli.sh stop
bash cli.sh rm
# DANGER: delete this instance's app and PostgreSQL data.
bash cli.sh purge
# DANGER: also delete this instance's settings, YAML and generated config directory.
bash cli.sh reset
```

## 5. 命令解释

以下为日常入口；Compose 调用均由 CLI 带上配置目录、项目名、YAML 路径及导出的 settings 变量。

#### init

生成缺失 settings、补齐空配置、刷新 Compose YAML，并预建应用和 PostgreSQL 数据目录。保留已有非空值和密码，不启动容器。

```bash
bash cli.sh init
```

#### start

检查配置字段、生成 app.conf 和 YAML，再执行本项目 `docker compose up -d`，启动 Casdoor 和配套 PostgreSQL。首次启动由 PostgreSQL 创建数据库与账号，Casdoor 初始化业务表。

```bash
bash cli.sh start
```

#### up

依次执行 `init` 和 `start`，默认连接与密码自动生成。

```bash
bash cli.sh up
```

#### update

刷新应用配置，执行本项目 `docker compose pull` 和 `docker compose up -d`，更新应用及配套 PostgreSQL 镜像，保留配置及数据。

```bash
bash cli.sh update
```

#### stop

执行本项目 `docker compose stop`，停止 Casdoor 和配套 PostgreSQL。

```bash
bash cli.sh stop
```

#### rm

执行本项目 `docker compose down`，删除本实例的应用、数据库容器和私有网络，保留配置和全部 bind mount 数据；已接入的 external 共享网络保留。

```bash
bash cli.sh rm
```

#### purge

执行 `rm` 后，通过一次性 root 容器删除本实例的 `data/<INSTANCE_NAME>_data` 和 `data/<INSTANCE_NAME>_postgres_data`。应用及数据库数据被清空，settings、生成 YAML 和 app.conf 保留。

```bash
bash cli.sh purge
```

#### reset

执行 `purge` 后，删除当前 `--conf` 文件、对应 YAML 和 `data/<INSTANCE_NAME>_config` 生成配置目录，完整清理本实例。其他实例、CLI、hooks 和源模板保留。

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

`update` 按 settings 中的 `IMAGE` 和 `POSTGRES_IMAGE` 拉取并应用镜像；默认标签滚动更新，可用具体版本或 digest 固定部署。升级前备份应用配置和业务数据库；PostgreSQL 负责空目录的初始建库建号，Casdoor 负责业务表和结构迁移。脚本不执行 PostgreSQL 跨主版本数据迁移。

停止整套服务后，复制包含 CLI、hooks、templates、settings、生成 YAML、`data/<INSTANCE_NAME>_config`、`data/<INSTANCE_NAME>_data` 和 `data/<INSTANCE_NAME>_postgres_data` 的部署目录。配置和数据库数据须一并保留；不能直接复制运行中的 PostgreSQL 数据目录作为一致性备份。

目标机器使用兼容的 PostgreSQL 主版本，保持实例名、密码与数据目录对应，运行 `start` 重建整套容器。默认私有网络由 Compose 创建；仅在配置了 `DOCKER_NETWORK` 时需要提前准备该共享网络。`start` 从 settings 和模板重建 app.conf；使用外置 `--conf` 时同时携带对应脚本和模板。

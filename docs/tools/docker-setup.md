# Docker 宿主机配置 (Deploy)

## 1. 简介

> 宿主机级别的 Docker 全局治理工具，当前负责安装并启用 ufw-docker，让 UFW 能够管控 Docker 发布的端口。

该工具直接修改宿主机防火墙，无 settings 和数据目录。在 Docker 使用 iptables 的环境中，发布端口的流量可能绕过常规 UFW INPUT 规则；ufw-docker 在转发路径加入 UFW 规则，需要对外开放的容器端口通过 `ufw-docker allow` 管理。作用对象包括 Compose 的 `ports` 发布，具体访问结果还取决于宿主机已有规则。

## 2. 核心配置项

无配置文件。行为由固定常量决定：

- `UFW_DOCKER_BIN`: ufw-docker 可执行文件落点，`/usr/local/bin/ufw-docker`。
- `AFTER_RULES`: ufw-docker 注入规则块的目标文件，`/etc/ufw/after.rules`。

## 3. 备注

- 作用范围：影响整机 Docker 发布端口，包括 Compose 的 `ports`；共享 Docker 网络的服务发现与接入仍由 Compose 管理。
- 前置依赖：需宿主机已安装 ufw；缺失时 `start` 直接报错退出。
- 权限：涉及防火墙与系统文件，脚本对非 root 调用自动回退 `sudo`。
- 幂等：`start` 检测 `after.rules` 中的 ufw-docker 标记块，已存在则跳过，不重复注入。

## 4. 快速执行

```bash
cd tools/docker-setup

# Apply host-wide ufw-docker rules.
bash cli.sh start

# Remove the injected rules.
bash cli.sh stop
```

## 5. 命令解释

以下片段展示 CLI 内部操作；日常使用 `bash cli.sh start` 或 `bash cli.sh stop`，权限处理由 CLI 完成。

#### start

下载 ufw-docker（若缺失），执行 `ufw-docker install` 并重启 ufw；已应用则跳过。

```bash
wget -O /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
chmod +x /usr/local/bin/ufw-docker
ufw-docker install
systemctl restart ufw
```

#### stop

从 `after.rules` 删除 ufw-docker 注入的标记块并重启 ufw，还原默认防火墙行为；可执行文件保留。

```bash
sed -i '/# BEGIN UFW AND DOCKER/,/# END UFW AND DOCKER/d' /etc/ufw/after.rules
systemctl restart ufw
```

## 6. 其他补充

- 命令集：提供 `start`（应用）与 `stop`（还原），不提供 Compose 生命周期或镜像 `update`。
- 与反代配合：可与 `tools/nginx` 配合控制应用直连端口和公网反代入口。
- 本工具不安装 Docker Engine 或 Compose。规则与可执行文件位于宿主机，复制本工具目录不会携带防火墙配置。

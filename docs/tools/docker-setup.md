# Docker 宿主机配置 (Deploy)

## 1. 简介

> 宿主机级别的 Docker 全局治理工具，当前负责安装并启用 ufw-docker，让 UFW 能够管控 Docker 发布的端口。

该服务直接作用于宿主物理机，非容器化，无 `settings_<服务名>.conf` 与数据目录。默认情况下 Docker 通过 `-p` 发布的端口会绕过 UFW（其规则写入 iptables 的 `DOCKER` 链，先于 UFW 的 `INPUT` 链生效）；启用 ufw-docker 后，Docker 发布端口默认不再对公网开放，需经 `ufw-docker allow` 显式放行。作为后续 Docker 宿主机治理脚本的聚合入口，可逐步扩展更多全局配置。

## 2. 核心配置项

无配置文件。行为由固定常量决定：

- `UFW_DOCKER_BIN`: ufw-docker 可执行文件落点，`/usr/local/bin/ufw-docker`。
- `AFTER_RULES`: ufw-docker 注入规则块的目标文件，`/etc/ufw/after.rules`。

## 3. 备注

- 全局副作用：启用后影响整机所有 Docker 服务，所有 `-p` 发布端口默认对公网不可达，直至 `ufw-docker allow` 放行。
- 前置依赖：需宿主机已安装 ufw；缺失时 `start` 直接报错退出。
- 权限：涉及防火墙与系统文件，脚本对非 root 调用自动回退 `sudo`。
- 幂等：`start` 检测 `after.rules` 中的 ufw-docker 标记块，已存在则跳过，不重复注入。

## 4. 快速执行

```bash
cd tools/docker-setup

# 启用 ufw-docker（全局生效）
bash cli.sh start

# 还原 ufw-docker（移除注入规则）
bash cli.sh stop
```

## 5. 命令解释

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

- 命令集裁剪：作为幂等的全局配置工具，仅保留 `start`（应用）与 `stop`（还原），不实现 `init`/`up`/`rm`/`purge`/`reset`。
- 与反代配合：通常与 `tools/nginx` 搭配——本服务关闭直连大门，`tools/nginx` 开放仅含白名单路径的公网入口。

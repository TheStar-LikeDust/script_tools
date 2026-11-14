# Docker 宿主机防火墙 (Deploy)

## 1. 简介

> 宿主机级别的 Docker 发布端口过滤配置，将 Docker 转发流量接入 UFW 的 forward 规则。

本工具直接维护 `/etc/ufw/after.rules` 中带专属标记的 DOCKER-USER 规则，不下载或执行 `ufw-docker` 等外部脚本。未获 UFW forward 规则允许的新连接会被丢弃。

## 2. 核心配置项

无实例 settings。固定维护的配置文件为 `/etc/ufw/after.rules`，规则使用 `SCRIPT-TOOLS-UFW-DOCKER` 链和专属注释标记。

## 3. 备注

- `install` 仅在缺失时通过 `apt-get` 安装 UFW，不会启用防火墙；启用前应先确认 SSH 等管理入口已放行。
- `start` 要求 Docker 正在运行且 UFW 已启用，写入规则后 reload UFW。当前配置适用于 Docker 的 iptables/DOCKER-USER 后端。
- DOCKER-USER 链由本工具接管转发过滤策略；其他自定义放行规则应通过 UFW `route` 规则维护，不要直接写入该链。
- Docker 发布端口不由普通的 `ufw allow <port>` 管理，需用 `ufw route allow` 配置转发规则。
- `stop` 移除当前运行态的专属过滤链，保留持久规则；后续 UFW reload 会重新加载该配置。
- `rm` 移除本工具的运行态链和 `/etc/ufw/after.rules` 标记区块，不卸载 UFW 或 Docker。
- 若检测到现有 DOCKER-USER 自定义规则或冲突的配置区块，脚本会拒绝覆盖。

## 4. 快速执行

```bash
cd tools/docker-setup
bash cli.sh install
# Enable UFW only after reviewing the host's required access rules.
bash cli.sh start
# Configure required published container ports with ufw route allow.
bash cli.sh stop
bash cli.sh rm
```

## 5. 命令解释

#### install

安装缺失的 UFW 软件包，不启用防火墙，不修改 Docker 或 UFW 规则。

#### start

要求 UFW active 且 Docker 可访问；将本工具规则插入 UFW 的 filter 配置并 reload。规则先放行已建立连接，再调用 `ufw-user-forward`；未命中的新连接被丢弃。

放行容器端口的形式如下，目标为 DNAT 后的容器地址和容器端口：

```bash
ufw route allow proto tcp from any to 172.18.0.2 port 8080
```

示例目标地址和端口需替换为容器当前的 IP 与容器端口。

#### stop

只移除运行中的专属链，持久配置保留。由于 UFW reload 会重新加载该区块，重新应用时运行 `start`。

#### rm

移除专属运行链和 `/etc/ufw/after.rules` 中的标记区块，再 reload 已启用的 UFW。其他规则及系统软件保留。

## 6. 其他补充

- 该规则影响整台主机的 Docker 发布端口，不只影响本仓库创建的容器。
- 容器 IP 可能随重建改变；重建容器后应检查并更新对应 `ufw route allow` 规则。
- 本工具不安装 Docker Engine，不管理应用 Compose 项目，也不替代云平台安全组。

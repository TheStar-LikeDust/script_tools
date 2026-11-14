# Nginx 网关 (Deploy)

## 1. 简介

> 宿主机级别的反向代理网关，将上游应用按白名单路径前缀暴露。

`install` 安装 Nginx 并生成缺失的实例 settings；`start/stop` 部署或撤下本站点；`rm` 额外删除本站点 settings 和生成配置。脚本只管理链接到本实例生成目录的站点，不改动 UFW 规则。

## 2. 核心配置项

### settings_nginx.conf

- `INSTANCE_NAME`：实例名，也是 `/etc/nginx/conf.d/` 中站点链接的名称。
- `SERVER_NAME`：公网主机名，默认 `_`。
- `LISTEN_PORT`：Nginx 公网监听端口，默认 `80`。
- `UPSTREAM_PORT`：本机上游应用端口，默认 `3000`。
- `ALLOW_PREFIX`：唯一反代路径前缀，默认 `/v1/`，必须以 `/` 开始和结束。

## 3. 备注

- `install` 适用于使用 `apt-get` 的 Debian/Ubuntu 系统；普通用户通过 `sudo` 安装。
- `start` 先生成独立站点配置，再运行 `nginx -t`；检查失败或 reload 失败时恢复原有的本站点链接。
- 若目标站点名已由普通文件或其他链接占用，脚本拒绝覆盖或删除。
- UFW 规则由管理员或 Docker 防火墙工具单独管理。`stop/rm` 不会删除端口规则，避免影响其他服务。
- `--conf PATH` 的父目录须已存在；`--name NAME` 只在首次 `install` 生成 settings 时生效。

## 4. 快速执行

```bash
cd tools/nginx
bash cli.sh install --name nginx_main
# Review settings_nginx.conf and set the upstream and public path.
bash cli.sh start
bash cli.sh stop
bash cli.sh rm
```

## 5. 命令解释

#### install

安装 Nginx，并在 settings 不存在时生成实例配置；不部署站点。

#### start

把模板渲染到实例数据目录，以软链部署到 `/etc/nginx/conf.d/`，执行 `nginx -t` 后 reload。只允许管理目标为本实例生成文件的软链。

#### stop

移除本实例拥有的站点软链并 reload Nginx；保留 settings 和生成文件。

#### rm

执行 stop 后删除本实例 settings 和生成的站点配置；保留 Nginx 软件包和其他站点。

## 6. 其他补充

- 模板默认只反代 `/v1/`，其余请求返回 404；管理界面不经该站点公开。
- 上游应用端口和网关入口的防火墙规则需分别管理。Nginx 工具不会创建或删除 UFW 规则。
- HTTP-01 证书申请需要 TCP 80 可从公网访问；Nginx 当前模板不自动接入 Certbot 证书。

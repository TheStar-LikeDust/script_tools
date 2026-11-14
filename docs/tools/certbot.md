# Certbot 证书申请 (Deploy)

## 1. 简介

> 使用 Certbot 通过 Let's Encrypt 为域名申请或续期 TLS 证书。

Certbot 是一次性命令行工具，不是常驻服务，因此只提供 `install` 与 `start`：前者安装软件，后者执行证书申请或续期。

## 2. 核心配置项

无需实例配置文件。`start` 接收一个域名或完整网址；证书保存在 `/etc/letsencrypt/live/<域名>/`。

## 3. 备注

- 安装使用 `apt-get`，适用于 Debian/Ubuntu；普通用户通过 `sudo` 执行。
- 申请使用 HTTP-01 standalone 验证，需要域名解析到当前服务器且公网 TCP 80 可访问、未被其他进程占用。
- 命令接受 Let's Encrypt 服务条款并以无邮箱方式注册；已安装的 Certbot 可配合系统续期 timer，脚本本身不创建续期任务。
- 此工具不提供 `stop/rm`，不删除证书或卸载系统软件。

## 4. 快速执行

```bash
cd tools/certbot
bash cli.sh install
bash cli.sh start https://example.com
```

## 5. 命令解释

#### install

安装缺失的 Certbot 软件包，不申请证书。

#### start

通过 HTTP-01 standalone 验证申请或续期指定域名，并输出证书和私钥路径。首次申请和续期前均要求公网 TCP 80 可用。

## 6. 其他补充

- 证书路径：`/etc/letsencrypt/live/<域名>/fullchain.pem`。
- 私钥路径：`/etc/letsencrypt/live/<域名>/privkey.pem`。
- 证书与续期配置由宿主机管理；备份时保存 `/etc/letsencrypt` 的证书、私钥、链接目标和续期配置。

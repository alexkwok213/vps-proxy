# VPS Proxy 实操使用指南（USAGE GUIDE）

> 本文档由实际部署与客户端接入过程中的经验整理而成，作为 `README.md` 的补充。
> 覆盖：部署、获取节点链接、客户端导入（含 Clash Verge Rev 坑点）、长期运行、日常运维、常见故障排查。

---

## 一、项目是什么

在海外 VPS 上自建个人代理出口，协议为 **Xray + VLESS + REALITY**（免域名、免证书、抗 GFW 主动探测）。

**部署产物**（二选一，取决于 VPS 是否装有 nginx 443 服务）：

| 产物 | 形式 | 前提 |
|------|------|------|
| 订阅 URL | `https://<VPS公网IP>/sub/<随机TOKEN>` | VPS 已运行 nginx 且有 443 配置 |
| Raw vless:// URI | `vless://<uuid>@<IP>:<PORT>?...` | 始终有，无需任何前提 |

---

## 二、部署前置（必须手动完成）

1. 一台海外 VPS，拿到 root 权限。
2. **云厂商安全组 / 防火墙放通 TCP 2053**（默认端口，入站来源 `0.0.0.0/0`）。
   - ⚠️ 这一步脚本管不了，**漏了必然连不上**，是最常见的坑。
3. （可选，用于订阅 URL）VPS 上已运行 nginx 且在 443 提供服务；没有则脚本自动跳过订阅托管，使用 Raw URI 即可。

---

## 三、部署方法

### 方式一：TAT（腾讯云自动化助手，推荐）
1. 全选复制 `deploy.sh` 全部内容。
2. 腾讯云控制台 → 自动化助手 → 新建执行任务 → 以 **root** 粘贴执行。
3. 等待 1–3 分钟（首次会安装 Xray），查看输出。

### 方式二：SSH
```bash
bash deploy.sh
# 或 curl -fsSL <你的raw地址>/deploy.sh | bash
```

脚本**幂等**：密钥首次随机生成后落盘 `/opt/proxy/secrets.env`，重跑不丢、不重复装、旧客户端不失效。

---

## 四、部署后如何拿到节点链接（重点）

### 4.1 部署输出的末尾

```
============== CLIENT CONFIG ==============
订阅 URL (推荐，一键导入):
  https://<你的VPS公网IP>/sub/<随机串>     ← 有 nginx 时出现

Raw vless:// URI:
  vless://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@<IP>:2053?...  ← 始终有
===========================================
```

### 4.2 事后随时可查（无需重跑脚本）

```bash
# 查订阅 URL（需知道 VPS 公网 IP，与 TOKEN 拼接）
grep TOKEN /opt/proxy/secrets.env
# → 订阅 URL = https://<VPS公网IP>/sub/<TOKEN值>

# 查 Raw vless:// URI（base64 解码订阅文件）
cat /opt/proxy/sub.txt | base64 -d
```

> 链接丢失不用慌：凭据都在 VPS 上，任意电脑登录 VPS 执行上面命令即可恢复。

---

## 五、客户端导入

### 5.1 Windows：Clash Verge Rev（实测坑点）

**重要坑点**：Clash Verge Rev 的「新建订阅」对话框里，URL 输入框**只接受 http/https 远程订阅链接**；
`vless://` 节点链接**不能**直接粘贴到 URL 输入框，必须走以下路径：

1. 复制 `vless://` 完整链接（或准备一份 Clash YAML 配置文件）。
2. 打开 Clash Verge Rev → 左侧「订阅」→ 点「新建」（+）。
3. 在弹出的对话框**切换到 Local（本地）类型**（默认可能是 Remote）。
4. 点击 **「从剪贴板导入」**（会自动解析 vless:// 链接）；或 **「从文件导入」** 选择 YAML 文件。
5. 生成后点击该配置 → **激活**。

**vless:// → Clash YAML 对照**（手动写配置时参考，Reality 节点必须带以下字段）：

```yaml
proxies:
  - name: MyVPS
    type: vless
    server: <VPS公网IP>
    port: 2053
    uuid: <UUID>
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: www.apple.com        # = URI 里的 sni
    client-fingerprint: chrome       # = URI 里的 fp
    reality-opts:
      public-key: <pbk>              # URI 里的 pbk（Reality 公钥，非私钥）
      short-id: <sid>                # URI 里的 sid
```

**验证**：代理页面选中该节点 → 浏览器打开 `https://ip.sb` → 显示 VPS 公网 IP 即成功。

### 5.2 其他客户端

| 客户端 | 导入方式 |
|--------|----------|
| Shadowrocket (iOS) | 右上 + → Subscribe 填 URL；或扫码 vless:// URI |
| v2rayN (Windows) | 订阅 → 添加订阅 → 填 URL → 更新 |
| v2rayNG (Android) | 订阅设置 → 添加订阅 URL → 更新 |
| Clash Meta / Stash / Surge | 订阅 → 填订阅 URL → 更新 |

---

## 六、长期运行与链接有效期

- **常驻运行**：Xray 注册为 systemd 服务（`systemctl enable --now xray`），开机自启，无需手动维护。
- **链接永久有效**：凭据落盘 `/opt/proxy/secrets.env`（幂等复用），重跑脚本 / 重启 VPS 均不变。
- **链接失效的三种情况**：
  1. VPS 重装系统（/opt 被清空）→ 重新部署，链接变化；
  2. VPS 更换公网 IP → 链接变化（IP 是链接一部分）；
  3. 手动删除 `/opt/proxy` 目录。

### 凭据轮换（怀疑泄漏时执行）

> ⚠️ 节点链接（vless:// URI）含 UUID + Reality 公钥 + short-id，拿到即可直接导入客户端使用。
> **任何情况下不要把它写进文档、截图、聊天记录或公开仓库**；一旦疑似泄漏，立即按下面步骤轮换。

因为脚本是幂等的（已有 `/opt/proxy/secrets.env` 就复用旧凭据），**必须删掉凭据文件后重跑才会生成新凭据**：

```bash
rm -f /opt/proxy/secrets.env      # 1. 删除旧凭据（UUID / short-id / TOKEN / Reality 密钥对）
bash deploy.sh                    # 2. 重跑脚本：生成全新凭据并重写 Xray 配置、自动重启
```

- 轮换后**旧链接立即失效**（旧 UUID 不再被接受），所有客户端需用新链接重新导入。
- 新链接获取方式不变：看部署输出 `CLIENT CONFIG` 块，或 `cat /opt/proxy/sub.txt | base64 -d`。
- 若使用订阅 URL：TOKEN 也同时变化，脚本会重写 nginx 订阅配置并 reload，订阅 URL 自动更新。
- 彻底吊销（不再使用本节点）：直接 `systemctl stop xray` 旧链接即不可用，完整清理见第七节。

---

## 七、日常运维

```bash
systemctl restart xray        # 重启
journalctl -u xray -f         # 看日志
systemctl is-active xray      # 状态（active 即正常）
```

吊销 / 清理：

```bash
systemctl stop xray && systemctl disable xray
rm -f /opt/proxy/nginx-sub.conf   # 并从 nginx 配置移除 include 行后 reload
rm -rf /opt/proxy /usr/local/etc/xray
ufw delete allow 2053/tcp         # 若开了 ufw
# 最后去云控制台删安全组 2053 规则
```

---

## 八、常见问题排查

| 现象 | 原因 | 解决 |
|------|------|------|
| 客户端连不上 | 云厂商安全组未放通 TCP 2053（最常见） | 控制台安全组放通 2053/tcp，来源 0.0.0.0/0 |
| 客户端连不上（放行后） | xray 服务未运行 | `systemctl is-active xray`，日志 `journalctl -u xray -e` |
| 部署时报 2053 被占用 | 端口冲突 | 改 `deploy.sh` 顶部 `PORT` 变量后重跑 |
| 本机 git/curl 无法访问 GitHub | 终端未走代理（Clash 混合端口 7897） | 当次命令前临时设置 `$env:HTTP_PROXY="http://127.0.0.1:7897"; $env:HTTPS_PROXY="http://127.0.0.1:7897"`；**不要配置 git 全局代理**（Clash 不常开时会导致 git 全部失败） |
| 私有仓库 clone 报 404 / 卡在认证 | 未登录；GitHub 对私有仓库统一返回 404 | 生成 repo 权限的 classic PAT，或用 `git credential` 保存凭据 |
| 部署后无订阅 URL | VPS 无 nginx 443 | 属正常，用 Raw vless:// URI 导入即可 |

---

## 九、本次实测记录（2026-07-31）

> ⚠️ 实测产生的真实节点链接（含 UUID 与公网 IP）**已从文档中移除并替换为占位符**，以免仓库成为凭据载体。
> 真实链接只存在于 VPS 的 `/opt/proxy/secrets.env` 与部署输出中，获取方式见第四节。

- **VPS**：腾讯云，公网 IP `<VPS公网IP>`（实测值已脱敏），端口 `2053`，Xray `26.3.27`。
- **nginx**：无（无订阅 URL，使用 Raw URI）。
- **节点链接**（结构示例，字段说明见 5.1 的 YAML 对照；`<...>` 均为占位符）：

```
vless://<UUID>@<VPS公网IP>:2053?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=<Reality公钥>&sid=<short-id>&type=tcp#CopyForge-VPS
```

- **客户端**：Windows + Clash Verge Rev 2.5.2，通过「新建 → Local → 从剪贴板导入」接入，`ip.sb` 验证通过。

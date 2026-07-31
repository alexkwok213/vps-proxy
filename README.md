# VPS 个人代理（VLESS + REALITY）

在任意海外 VPS 上自建一个稳定的翻墙出口，替代/补充机场软件。
协议为 **Xray + VLESS + REALITY**：免域名、免证书、抗 GFW 主动探测最强，全平台客户端通用。

## 特性
- 一键部署：单个 `deploy.sh` 自包含，TAT / SSH 以 root 跑一次即可。
- 幂等：密钥首次随机生成后落盘 `/opt/proxy/secrets.env`，重跑不丢、不重复装。
- 双交付客户端配置：订阅 URL（经 VPS 上 nginx 的 `443` 只读路径托管）+ 原始 `vless://` URI + 终端二维码。
- 零依赖污染：只新增一个独立端口（`2053` 默认）和一个 nginx 只读路径，不影响 VPS 上其它服务。

## 前置
1. 一台海外 VPS（能直连 GitHub 以下载 Xray），拿到 root。
2. 在云厂商**安全组 / 防火墙**放通你选的端口（默认 **TCP 2053**，入站来源 `0.0.0.0/0`）。
   - 这一步脚本管不了，必须在控制台做，否则客户端连不上。
3. （可选，用于订阅 URL）VPS 上已运行 nginx 并在 `443` 提供服务。若无 nginx，脚本会跳过订阅托管，直接用输出的 Raw URI 即可。

## 部署
```bash
# 方式一：TAT（腾讯云等厂商的自动化助手）
#   全选复制 deploy.sh 内容 → 控制台 → 自动化助手 → 以 root 执行

# 方式二：SSH 直接跑
curl -fsSL https://你的-raw-地址/deploy.sh | bash
# 或把 deploy.sh 传上去后：bash deploy.sh
```
等待 1–3 分钟（首次安装 Xray）。执行完在输出里找 `============== CLIENT CONFIG ==============` 块：
- **订阅 URL**：形如 `https://<你的VPS公网IP>/sub/<随机串>`，一键导入最省事。
- **Raw vless:// URI**：可手动粘贴或扫码。
- **二维码**：部分终端不支持 UTF8 会空白，无视即可（用订阅 URL）。

> 改端口 / 换 Reality 目标站：编辑 `deploy.sh` 顶部 `PORT` 变量，或重跑脚本（dest 会自动重新探测）。
> 重跑会复用已有密钥（幂等），不会让旧客户端失效。

## 客户端导入
| 客户端 | 导入方式 |
|--------|----------|
| Clash Meta(mihomo) / Stash / Surge | 订阅 → 填「订阅 URL」→ 更新 |
| Shadowrocket(iOS) | 右上 + → Subscribe 填 URL；或 Scan QR 扫 URI |
| v2rayN(Windows) | 订阅 → 添加订阅 → 填 URL → 更新订阅 |
| v2rayNG(Android) | 订阅设置 → 添加订阅 URL → 更新订阅 |

导入后选该节点，浏览器开 `https://ip.sb` 显示 VPS 公网 IP 即成功。

## 日常运维
```bash
systemctl restart xray          # 重启
journalctl -u xray -f           # 看日志
systemctl is-active xray        # 状态
```
吊销 / 清理：
```bash
# 停止并移除
systemctl stop xray && systemctl disable xray
rm -f /opt/proxy/nginx-sub.conf
# 从 nginx 配置里删掉 include /opt/proxy/nginx-sub.conf; 那一行，再 nginx -t && systemctl reload nginx
rm -rf /opt/proxy /usr/local/etc/xray
ufw delete allow 2053/tcp       # 若开了 ufw
# 最后去云控制台删安全组 2053 规则
```

## 工作原理（简述）
Xray 在 `2053` 监听 VLESS+Reality 入站。Reality 让握手流量伪装成到某个真实大站（自动选 apple/microsoft/bing/cloudflare）的普通 TLS，因此无需自有域名/证书也难以被探测。客户端用 `xtls-rprx-vision` 流控。

## 注意
- **线路质量**：取决于 VPS 到本地的线路，普通国际线通常不如优质机场的 CN2 专线；重度下载可能更慢。
- **合规**：自建个人代理自用，是否合规由你按当地法规自行判断；本方案不对外服务、不记录访问日志、订阅路径随机长串。
- **安全**：`/opt/proxy/secrets.env` 含私钥与凭据，`chmod 600`，切勿提交进 git（已写入 `.gitignore`）。

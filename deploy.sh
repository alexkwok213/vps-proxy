#!/bin/bash
# VPS Personal Proxy - VLESS + REALITY (Xray)
# 在海外 VPS 上自建翻墙出口，替代/补充机场。
# 严格不影响现有 80/443(Next.js) 与 8080(Lovart relay)。
# 用法：把整段内容粘贴到腾讯云 TAT（root）执行。
#
# 重要前置（脚本无法代劳，需你在腾讯云控制台做）：
#   安全组入站规则放通 TCP 2053（本脚本只负责 VPS 内 ufw，安全组在云控制台）。
set -euo pipefail

PORT=2053
PROXY_DIR=/opt/proxy
SECRETS="$PROXY_DIR/secrets.env"
XRAY_BIN=/usr/local/bin/xray

echo "=== VPS Proxy (VLESS+Reality) Deploy $(date) ==="

# ---- 0. apt 镜像修复（与 lovart 同款）----
if grep -q 'mirrors.tencentyun.com' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then
    echo "[fix] apt tencentyun -> aliyun"
    sed -i 's/mirrors\.tencentyun\.com/mirrors.aliyun.com/g' /etc/apt/sources.list.d/ubuntu.sources
fi

# ---- 1. 只读探针 ----
echo "[probe] 公网 IP / 区域"
for ipapi in ipinfo.io/ip ifconfig.me ip.sb icanhazip.com; do
    VPSIP=$(curl -s --max-time 8 "https://$ipapi" 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    [ -n "$VPSIP" ] && { echo "  ip=$VPSIP (via $ipapi)"; break; }
    echo "  probe $ipapi 失败，换下一个源..."
done
if [ -z "${VPSIP:-}" ]; then
    echo "ERROR: 公网 IP 探测失败；请检查 VPS 是否有 http_proxy/https_proxy 环境变量干扰 curl（env | grep -i proxy）" >&2
    exit 1
fi

echo "[probe] 端口 $PORT 是否空闲"
if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "  WARN: $PORT 已被占用，请改 PORT 变量"
else
    echo "  OK: $PORT 空闲"
fi

echo "[probe] 选 Reality 目标站(dest)..."
DEST=""
for d in www.apple.com www.microsoft.com www.bing.com www.cloudflare.com; do
    if curl -sI --connect-timeout 5 --max-time 8 "https://$d" >/dev/null 2>&1; then
        DEST="$d"; break
    fi
done
[ -z "$DEST" ] && DEST="www.apple.com"
echo "  dest=$DEST"

echo "[probe] 定位 nginx 443 配置"
NGX_CONF=$(grep -rl "listen 443" /etc/nginx/ 2>/dev/null | head -1 || true)
echo "  nginx 443 conf: ${NGX_CONF:-none}"

# ---- 2. 安装 Xray ----
if [ -x "$XRAY_BIN" ]; then
    echo "[xray] 已安装，跳过安装 ($(xray version 2>/dev/null | head -1))"
else
    echo "[xray] 安装中 (官方脚本，失败自动换 jsdelivr 镜像)..."
    if ! bash -c "$(curl -L --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
        echo "[xray] 重试 jsdelivr 镜像"
        bash -c "$(curl -L --max-time 60 https://cdn.jsdelivr.net/gh/XTLS/Xray-install@main/install-release.sh)" @ install
    fi
    echo "  xray: $(xray version 2>/dev/null | head -1)"
fi

# ---- 3. 密钥/凭据（幂等：已有则复用）----
mkdir -p "$PROXY_DIR"
export PORT DEST
if [ -f "$SECRETS" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS"
    if [ -z "${UUID:-}" ] || [ -z "${SID:-}" ] || [ -z "${TOKEN:-}" ] || [ -z "${PRIV:-}" ] || [ -z "${PUB:-}" ]; then
        echo "[secrets] 已有凭据不完整(如 PRIV/PUB 为空)，删除重新生成"
        rm -f "$SECRETS"
    fi
fi
if [ -f "$SECRETS" ]; then
    echo "[secrets] 复用已有凭据"
    # shellcheck disable=SC1090
    source "$SECRETS"
else
    echo "[secrets] 生成新凭据"
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SID=$(openssl rand -hex 4)
    TOKEN=$(openssl rand -hex 16)
    KEYS=$("$XRAY_BIN" x25519 2>/dev/null)
    # 兼容新旧输出格式：旧版 Private key:/Public key:；Xray≥26 改为 PrivateKey:/Password:/Hash32:（Password=原 Public key）
    # 用前缀匹配规避大小写差异：新版 PrivateKey 大写 K，旧版 Private key 带空格
    PRIV=$(echo "$KEYS" | awk -F': ?' '/^Private/{print $2}')
    PUB=$(echo "$KEYS"  | awk -F': ?' '/^Public key|^Password/{print $2}')
    if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
        echo "ERROR: xray x25519 密钥解析失败；请手动执行 'xray x25519' 查看输出（新版为 PrivateKey/Password/Hash32，Password 即公钥）" >&2
        exit 1
    fi
    cat > "$SECRETS" <<ENV
UUID=$UUID
SID=$SID
TOKEN=$TOKEN
PRIV=$PRIV
PUB=$PUB
DEST=$DEST
PORT=$PORT
ENV
    chmod 600 "$SECRETS"
    echo "  已写入 $SECRETS (chmod 600)"
fi
export UUID SID TOKEN PRIV PUB

# ---- 4. 写 Xray 配置 ----
echo "[config] 写 $XRAY_BIN 配置 -> /usr/local/etc/xray/config.json"
python3 - <<'PYCFG'
import os, json, subprocess, re
# Xray ≥26 将 streamSettings 的传输方式字段由 network 改为 method，按版本自适应
ver = 0
try:
    vout = subprocess.run(["/usr/local/bin/xray", "version"], capture_output=True, text=True, timeout=10).stdout
    m = re.search(r"Xray\s+v?(\d+)\.", vout)
    if m:
        ver = int(m.group(1))
except Exception:
    pass
transport = {"method": "raw", "rawSettings": {}} if ver >= 26 else {"network": "tcp"}
print("  transport: Xray {} -> {}".format(ver, "method/raw" if ver >= 26 else "network/tcp"))
cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "0.0.0.0",
        "port": int(os.environ["PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": os.environ["UUID"], "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            **transport,
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": os.environ["DEST"] + ":443",
                "xver": 0,
                "serverNames": [os.environ["DEST"]],
                "privateKey": os.environ["PRIV"],
                "shortIds": [os.environ["SID"]]
            }
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
    }],
    "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
os.makedirs("/usr/local/etc/xray", exist_ok=True)
with open("/usr/local/etc/xray/config.json", "w") as f:
    json.dump(cfg, f, indent=2)
print("  config.json written")
PYCFG

# ---- 5. systemd ----
echo "[systemd] 启动 xray"
systemctl daemon-reload
systemctl enable --now xray
sleep 1
echo "  xray active: $(systemctl is-active xray)"
if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "  listening: OK ($(ss -ltn 2>/dev/null | grep ":$PORT " | awk '{print $4}'))"
else
    echo "  listening: NONE"
    echo "ERROR: xray 未监听 $PORT；排查日志: journalctl -u xray -e | tail -50" >&2
    exit 1
fi

# ---- 6. ufw ----
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
    echo "[ufw] 放通 $PORT/tcp"
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
fi

# ---- 7. 构建客户端 vless:// URI ----
echo "[client] 构建 URI"
if [ -z "${VPSIP:-}" ]; then
    VPSIP=$(curl -s --max-time 8 ipinfo.io/ip 2>/dev/null || true)
fi
export VPSIP
URI=$(python3 - "$VPSIP" "$PORT" "$UUID" "$PUB" "$SID" "$DEST" <<'PYURI'
import sys, urllib.parse
ip, port, uuid, pub, sid, dest = sys.argv[1:7]
name = urllib.parse.quote("CopyForge-VPS")
q = {
    "encryption": "none",
    "flow": "xtls-rprx-vision",
    "security": "reality",
    "sni": dest,
    "fp": "chrome",
    "pbk": pub,
    "sid": sid,
    "type": "tcp",
}
uri = "vless://{}@{}:{}?".format(uuid, ip, port) + urllib.parse.urlencode(q) + "#" + name
print(uri)
PYURI
)
echo "  URI 长度: ${#URI}"

# ---- 8. 订阅文件 + nginx 托管 ----
SUB_FILE="$PROXY_DIR/sub.txt"
echo -n "$URI" | base64 -w0 > "$SUB_FILE"
chmod 644 "$SUB_FILE"   # 需让 nginx worker 可读；内容仅为公开 URI，靠随机 token 路径保护
echo "[sub] $SUB_FILE 已写"

if [ -n "$NGX_CONF" ]; then
    echo "[nginx] 注入只读订阅路径 /sub/$TOKEN"
    cat > "$PROXY_DIR/nginx-sub.conf" <<NGX
location = /sub/$TOKEN {
    alias $SUB_FILE;
    default_type text/plain;
    add_header Access-Control-Allow-Origin "*";
    expires -1;
}
NGX
    cp "$NGX_CONF" "$NGX_CONF.bak-proxy-$(date +%s)"
    python3 - "$NGX_CONF" <<'PYNGX'
import sys
f = sys.argv[1]
marker = "include /opt/proxy/nginx-sub.conf;"
s = open(f).read()
if marker not in s:
    lines, inserted = [], False
    for ln in s.split("\n"):
        lines.append(ln)
        if not inserted and "listen" in ln and "443" in ln:
            lines.append("    " + marker)
            inserted = True
    open(f, "w").write("\n".join(lines))
    print("  nginx: include 已注入")
else:
    print("  nginx: include 已存在，跳过")
PYNGX
    if nginx -t 2>&1 | grep -q "test is successful"; then
        systemctl reload nginx
        echo "  nginx reloaded"
    else
        echo "  WARN: nginx -t 失败，请检查 $NGX_CONF"
    fi
else
    echo "[nginx] 未找到 443 配置，跳过订阅托管（用下方 Raw URI 即可）"
fi

# ---- 9. 输出客户端配置 ----
echo ""
echo "============== CLIENT CONFIG =============="
if [ -n "$NGX_CONF" ] && [ -n "${VPSIP:-}" ]; then
    echo "订阅 URL (推荐，一键导入):"
    echo "  https://$VPSIP/sub/$TOKEN"
fi
echo ""
echo "Raw vless:// URI:"
echo "  $URI"
echo ""
echo "二维码 (手机客户端扫码导入，若空白说明终端不支持 UTF8):"
if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$URI" 2>/dev/null || echo "  (qrencode 生成失败)"
else
    echo "  (未装 qrencode，可忽略；用上方订阅 URL 或 URI 即可)"
fi
echo "==========================================="
echo ""
echo "提醒：若客户端连不上，先确认【腾讯云安全组】已放通 TCP $PORT 入站。"
echo "日常：systemctl restart xray | journalctl -u xray -f | 换 dest 重跑本脚本即可(凭据保持不变)。"

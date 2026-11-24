#!/bin/bash
# ============================================================================
#  xboard-allowlist installer
#
#  仓库内安装：
#      sudo ./install.sh
#      sudo ./install.sh 203.0.113.10
#      sudo ./install.sh 203.0.113.10 198.51.100.0/24
#
#  一键安装（无需 clone）：
#      curl -fsSL https://raw.githubusercontent.com/Assute/xboard-allowlist/main/install.sh | sudo bash
#      curl -fsSL https://raw.githubusercontent.com/Assute/xboard-allowlist/main/install.sh | sudo bash -s -- 203.0.113.10
#
#  非默认端口：
#      curl -fsSL ... | sudo XB_PORT=7002 bash
#
#  做的事：
#      1. 装脚本到 /usr/local/sbin/xboard-allowlist
#      2. 装 systemd unit 并 enable（开机自动 apply）
#      3. 命令带 IP 时逐条 add（add 内部会自动 apply）
#      4. 列表非空时重新 apply
#      5. 装完直接进入交互菜单，用序号增删放行地址
#
#  装完不想进菜单（脚本化调用）：
#      curl -fsSL ... | sudo XB_NO_MENU=1 bash
#
#  不会覆盖已有的 /etc/xboard-allowlist/ips.list
# ============================================================================
set -euo pipefail

PORT="${XB_PORT:-7001}"
RAW="${XB_RAW:-https://raw.githubusercontent.com/Assute/xboard-allowlist/main}"
PREFIX="${PREFIX:-/usr/local}"
BIN="${PREFIX}/sbin/xboard-allowlist"
UNIT="/etc/systemd/system/xboard-allowlist.service"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { red "$*"; exit 1; }

# ---------------------------------------------------------------- 前置检查

[ "$(id -u)" -eq 0 ] || die "需要 root 权限，用 sudo 执行"
command -v iptables >/dev/null 2>&1 || die "缺少 iptables"
iptables -S DOCKER-USER >/dev/null 2>&1 \
    || die "DOCKER-USER 链不存在 —— docker 没在运行，或 daemon.json 里 iptables 被设为 false"

# ---------------------------------------------------------------- 定位主脚本

SRC=""
TMPBODY=""
cleanup() { if [ -n "$TMPBODY" ]; then rm -f "$TMPBODY"; fi; }
trap cleanup EXIT

# 仓库内模式：install.sh 旁边就有 xboard-allowlist
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
    if [ -n "$here" ] && [ -f "$here/xboard-allowlist" ]; then
        SRC="$here/xboard-allowlist"
        grn "==> 使用本地副本: $SRC"
    fi
fi

# 远程模式：curl | bash
if [ -z "$SRC" ]; then
    TMPBODY="$(mktemp)"
    grn "==> 下载主脚本: $RAW/xboard-allowlist"
    curl -fsSL --max-time 45 "$RAW/xboard-allowlist" -o "$TMPBODY" \
        || die "下载失败。检查网络，或用 XB_RAW=<镜像地址> 覆盖"
    [ -s "$TMPBODY" ] || die "下载到的文件为空"
    head -1 "$TMPBODY" | grep -q '^#!' || die "下载到的不是脚本（可能是错误页）"
    SRC="$TMPBODY"
fi

# ---------------------------------------------------------------- 安装

grn "==> 安装到 $BIN"
install -D -m 755 "$SRC" "$BIN"

grn "==> 写 systemd unit"
cat > "$UNIT" <<UNITEOF
[Unit]
Description=XBoard origin allowlist for port ${PORT} (DOCKER-USER chain)
Documentation=https://github.com/Assute/xboard-allowlist
After=docker.service ufw.service
Wants=docker.service

[Service]
Type=oneshot
Environment=XB_PORT=${PORT}
ExecStart=${BIN} apply
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable xboard-allowlist.service >/dev/null 2>&1
grn "==> 已 enable xboard-allowlist.service"

# ---------------------------------------------------------------- 放行 IP

if [ $# -gt 0 ]; then
    grn "==> 写入 $# 条放行规则"
    for ip in "$@"; do
        XB_PORT="$PORT" "$BIN" add "$ip" || ylw "    跳过无效条目: $ip"
    done
elif [ -s /etc/xboard-allowlist/ips.list ] && XB_PORT="$PORT" "$BIN" apply >/dev/null 2>&1; then
    grn "==> 已有列表，已按端口 $PORT 重新应用"
else
    ylw ""
    ylw "没有提供放行地址 —— 端口目前对所有来源开放。"
    ylw "下一步：在菜单里按 1，把 CDN 回源 IP 填进去，填完自动生效。"
fi

systemctl restart xboard-allowlist.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 结果

echo
grn "安装完成。"
echo
XB_PORT="$PORT" "$BIN" list 2>/dev/null | sed 's/^/    /' || true
echo
echo "  常用命令："
echo "    $BIN                    交互菜单"
echo "    $BIN add <IP|CIDR>      添加并自动 apply"
echo "    $BIN del <序号|IP>      删除并自动 apply"
echo "    $BIN list               列表 + 生效规则 + 命中计数"
echo
ylw "  注意: ufw allow from ... to any port $PORT 对 docker 发布的端口无效，可删掉。"

# ---------------------------------------------------------------- 进菜单

# curl | bash 时 stdin 是管道，但 /dev/tty 通常仍可读；
# 把 stdin 换成 tty 就能直接在菜单里按序号操作。
# 脚本化场景设 XB_NO_MENU=1 跳过。
if [ -z "${XB_NO_MENU:-}" ] && [ -r /dev/tty ] && [ -t 1 ]; then
    echo
    grn ">>> 进入管理菜单（按 0 退出）"
    sleep 1
    XB_PORT="$PORT" "$BIN" < /dev/tty || true
fi

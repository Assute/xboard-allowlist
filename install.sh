#!/bin/bash
# ============================================================================
#  xboard-allowlist installer
#
#  用法：
#     sudo ./install.sh                 安装并首次 apply
#     sudo XB_PORT=7002 ./install.sh    为非默认端口安装
#
#  做的事：
#     1. 装脚本到 /usr/local/sbin/xboard-allowlist
#     2. 装 systemd unit 并 enable（开机自动 apply）
#     3. 首次 apply
#
#  不会动已有的 /etc/xboard-allowlist/ips.list
# ============================================================================
set -euo pipefail

PORT="${XB_PORT:-7001}"
CHAIN="DOCKER-USER"
PREFIX="${PREFIX:-/usr/local}"
BIN="${PREFIX}/sbin/xboard-allowlist"
UNIT="/etc/systemd/system/xboard-allowlist.service"
SRC="$(cd "$(dirname "$0")" && pwd)/xboard-allowlist"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { red "需要 root 权限，试试 sudo ./install.sh"; exit 1; }
[ -f "$SRC" ] || { red "找不到 $SRC，请在仓库目录里执行"; exit 1; }

command -v iptables >/dev/null 2>&1 || { red "缺少 iptables"; exit 1; }

if ! iptables -S "$CHAIN" >/dev/null 2>&1; then
    red "DOCKER-USER 链不存在"
    red "docker 没运行，或者 daemon.json 里设置了 \"iptables\": false"
    exit 1
fi

grn "==> 安装脚本到 $BIN"
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
ExecStart=${BIN} apply
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF

if [ -f /etc/xboard-allowlist/ips.list ]; then
    ylw "==> 检测到已有 /etc/xboard-allowlist/ips.list，保留原内容"
else
    ylw "==> 未发现列表文件，首次执行将生成模板"
fi

systemctl daemon-reload
systemctl enable xboard-allowlist.service >/dev/null 2>&1
grn "==> 已 enable xboard-allowlist.service"

grn "==> 首次 apply"
if ! XB_PORT="$PORT" "$BIN" apply; then
    ylw ""
    ylw "列表为空，本次没有写入任何限制规则 —— 端口目前对所有来源开放。"
    ylw "加上回源地址后再应用："
    ylw "    $BIN add <你的CDN回源IP>"
    ylw "    $BIN apply"
fi

systemctl restart xboard-allowlist.service >/dev/null 2>&1 || true

echo
grn "安装完成。"
echo
echo "  当前放行列表："
XB_PORT="$PORT" "$BIN" list | sed 's/^/    /'
echo
echo "  常用命令："
echo "    $BIN                    交互菜单"
echo "    $BIN add <IP|CIDR>      添加并自动 apply"
echo "    $BIN del <序号|IP>      删除并自动 apply"
echo "    $BIN list               列表 + 生效规则 + 命中计数"
echo
ylw "  别忘了：ufw allow from ... to any port $PORT 这类规则对 docker 端口无效，可以删掉。"

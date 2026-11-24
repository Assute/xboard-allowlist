# xboard-allowlist

> 把面板回源端口锁给 CDN，而不是锁给全世界。

XBoard / v2board 用 docker 跑面板时，`7001` 端口通常直接裸在公网。这个工具用 **`iptables` 的 `DOCKER-USER` 链**给容器端口做 IP 白名单，带序号管理、自动持久化、变更日志。

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [为什么 ufw 不管用](#为什么-ufw-不管用)
- [安装](#安装)
- [用法](#用法)
- [列表文件](#列表文件)
- [典型场景](#典型场景)
- [原理](#原理)
- [排错](#排错)
- [已知限制](#已知限制)

---

## 它解决什么问题

docker compose 里写：

```yaml
services:
  web:
    image: ghcr.io/cedar2025/xboard:new
    ports:
      - 7001:7001          # ← 等价于 0.0.0.0:7001，全网可达
```

于是 `http://<你的IP>:7001/api/v1/passport/auth/login` 任何人都能直连，绕过 CDN 的 WAF、限速、CC 防护。

把 `ports` 改成 `127.0.0.1:7001:7001` 能彻底解决，但前提是**回源流量走本地 nginx 反代**。如果 CDN 是直连 `IP:7001` 回源，这样改会让站点立刻 504。

这个工具的适用场景就是：**CDN 必须直连容器端口，但不想让全世界都能连。**

---

## 为什么 ufw 不管用

直觉做法：

```bash
ufw allow from 203.0.113.10 to any port 7001 proto tcp
ufw delete allow 7001/tcp
```

`ufw status` 显示规则已生效，但直连 `IP:7001` 依然 200。原因是包的处理路径：

```
网卡 → nat/PREROUTING（docker DNAT 在这里改写目标地址）
       ↓
     filter/FORWARD  →  容器
       
     filter/INPUT    ←  ufw 的规则挂在这里，流量根本走不到
```

docker 发布端口时在 `nat/PREROUTING` 就做了 DNAT，包被改写成"转发给容器网段"，随后走 `FORWARD` 链。ufw 的 allow/deny 全部挂在 `INPUT` 上，对这类流量**完全无效**。

docker 官方为此保留了 `DOCKER-USER` 链——它在 DNAT 之后、转发之前执行，是唯一能拦住容器流量的位置。本项目把白名单写在这里。

验证一下你机器上是不是这个情况：

```bash
# 加一条 ufw 限制，然后从外部直连，如果还能通，就是踩了这个坑
ufw allow from 1.2.3.4 to any port 7001 proto tcp
curl -s -o /dev/null -w '%{http_code}\n' http://<你的IP>:7001/
```

---

## 安装

需要：Linux + iptables + docker（`DOCKER-USER` 链必须存在）+ root。

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/Assute/xboard-allowlist/main/install.sh \
  | sudo bash -s -- 203.0.113.10
```

把 `203.0.113.10` 换成你的 CDN 回源 IP。可以一次给多个：

```bash
curl -fsSL https://raw.githubusercontent.com/Assute/xboard-allowlist/main/install.sh \
  | sudo bash -s -- 203.0.113.10 198.51.100.0/24
```

不给参数就是只装不设白名单，装完再加：

```bash
curl -fsSL https://raw.githubusercontent.com/Assute/xboard-allowlist/main/install.sh | sudo bash
xboard-allowlist add <你的CDN回源IP>
```

端口不是 7001：

```bash
curl -fsSL https://raw.githubusercontent.com/Assute/xboard-allowlist/main/install.sh \
  | sudo XB_PORT=7002 bash
```

`raw.githubusercontent.com` 不通时换 CDN 镜像：

```bash
curl -fsSL https://raw.githubusercontent.com/Assute/xboard-allowlist/main/install.sh \
  | sudo XB_RAW=https://cdn.jsdelivr.net/gh/Assute/xboard-allowlist@main bash
```

### 从仓库安装

```bash
git clone https://github.com/Assute/xboard-allowlist.git
cd xboard-allowlist
sudo ./install.sh 203.0.113.10
```

### install.sh 做的事

1. 把 `xboard-allowlist` 装到 `/usr/local/sbin/`
2. 写 `/etc/systemd/system/xboard-allowlist.service`（`After=docker.service`，开机自动 apply）
3. 命令行给了 IP 就逐条 `add`（`add` 内部自动 apply）
4. 列表非空时按目标端口重新 apply
5. **装完直接进入交互菜单**，用序号增删放行地址

重复执行是安全的：`ips.list` 已存在时不会被覆盖，iptables 规则每次全量重建。

### 装完直接进菜单

一条命令下去，看到的就是这个：

```
>>> 进入管理菜单（按 0 退出）

╔═══════════════════════════════════════════════╗
║    XBoard 回源放行管理  端口 7001             ║
║    后端链: DOCKER-USER  非 ufw                ║
╚═══════════════════════════════════════════════╝

端口 7001 放行列表   /etc/xboard-allowlist/ips.list
---------------------------------------------
   1) 203.0.113.10
   2) 198.51.100.0/24
---------------------------------------------
  共 2 条

  1) 添加 IP / 网段
  2) 删除 IP（输入序号或地址）
  3) 重新应用规则
  4) 本机连通性自测
  5) 手工编辑列表
  0) 退出

选择 [0-5]:
```

`curl | bash` 的 stdin 是管道，installer 会把 stdin 切到 `/dev/tty` 再启动菜单，所以照样能按数字。按 `0` 退出回到 shell。

脚本化调用不想要菜单：

```bash
curl -fsSL .../install.sh | sudo XB_NO_MENU=1 bash -s -- 203.0.113.10
```

之后任何时候手动进菜单：`xboard-allowlist`（不带参数）。

### 手动安装

```bash
install -m 755 xboard-allowlist /usr/local/sbin/xboard-allowlist
xboard-allowlist add <你的CDN回源IP>
```

---
## 用法

### 交互菜单

```bash
xboard-allowlist
```

```
╔═══════════════════════════════════════════════╗
║    XBoard 回源放行管理  端口 7001             ║
║    后端链: DOCKER-USER  非 ufw                ║
╚═══════════════════════════════════════════════╝

端口 7001 放行列表   /etc/xboard-allowlist/ips.list
---------------------------------------------
   1) 203.0.113.10
   2) 198.51.100.0/24
---------------------------------------------
  共 2 条

当前 DOCKER-USER 生效规则
  -A DOCKER-USER -s 203.0.113.10/32 -p tcp -m tcp --dport 7001 -j RETURN
  -A DOCKER-USER -s 198.51.100.0/24 -p tcp -m tcp --dport 7001 -j RETURN
  -A DOCKER-USER -p tcp -m tcp --dport 7001 -j DROP

命中计数
   504  31378 RETURN  6  --  *  *  203.0.113.10    0.0.0.0/0  tcp dpt:7001
     2    104 RETURN  6  --  *  *  198.51.100.0/24   0.0.0.0/0  tcp dpt:7001
     8    416 DROP    6  --  *  *  0.0.0.0/0         0.0.0.0/0  tcp dpt:7001

  1) 添加 IP / 网段
  2) 删除 IP（输入序号或地址）
  3) 重新应用规则
  4) 本机连通性自测
  5) 手工编辑列表
  0) 退出
```

删除时输入 `2` 删第二条，输入 `198.51.100.0/24` 也认。

### 子命令

```bash
xboard-allowlist list                    # 列表 + 生效规则 + 命中计数
xboard-allowlist add 1.2.3.4             # 添加单个 IP，自动 apply
xboard-allowlist add 10.0.0.0/8          # 添加网段
xboard-allowlist del 2                   # 按序号删除
xboard-allowlist del 203.0.113.10      # 按地址删除
xboard-allowlist apply                   # 手工改完 ips.list 后重建规则
xboard-allowlist test                    # curl 127.0.0.1:<port> 看源站本身
xboard-allowlist raw                     # 原始 iptables 计数
xboard-allowlist help
```

端口不是 7001 时用环境变量覆盖：

```bash
XB_PORT=7002 xboard-allowlist list
```

`add` / `del` 都会自动 `apply`，不用手动再敲一次。

---

## 列表文件

`/etc/xboard-allowlist/ips.list`，纯文本，可以直接编辑：

```
# 7001 端口回源放行列表
# 每行一个 IPv4 地址或 CIDR，以 # 开头为注释，空行忽略
# 菜单里的序号就是这里的有效行顺序
203.0.113.10
198.51.100.0/24
```

改完执行 `xboard-allowlist apply`。

每次写入前自动备份为 `ips.list.bak.<时间戳>`，保留最近 20 份。

**列表为空时 `apply` 会拒绝执行**——否则一条规则都不剩，等于把端口全封死。

---

## 典型场景

### CDN 换了回源 IP，站点 504

```bash
# 先加新的，再删旧的（顺序反了中间那一秒会断）
xboard-allowlist add 1.2.3.4
xboard-allowlist del 5.6.7.8
```

### 不知道新 IP 是多少

```bash
# 1. 临时全放开，先止血
iptables -I DOCKER-USER 1 -p tcp --dport 7001 -j RETURN

# 2. 抓真实来源（看 conntrack 已建立的连接）
grep 'dport=7001' /proc/net/nf_conntrack \
  | grep -oE 'src=[0-9.]+' | cut -d= -f2 | sort | uniq -c | sort -rn

# 3. 把结果加进列表
xboard-allowlist add <抓到的IP>

# 4. 重新 apply，会把第 1 步那条临时规则一起清掉
xboard-allowlist apply
```

第 2 步如果抓出来全是 `127.0.0.1` 和 `172.x`，说明回源走的是本地 nginx 反代，那 `7001` 可以直接绑 `127.0.0.1`，不需要这个工具了。

### 只放行一个段

```bash
xboard-allowlist add 198.51.100.0/24
```

比逐个 IP 稳定——CDN 在同一段内换节点不会断。

### 误删了想恢复

```bash
ls -1t /etc/xboard-allowlist/ips.list.bak.* | head -1
cp "$(ls -1t /etc/xboard-allowlist/ips.list.bak.* | head -1)" /etc/xboard-allowlist/ips.list
xboard-allowlist apply
```

### 确认规则真的在拦

```bash
# DROP 那一行的 pkts 应该持续增长
xboard-allowlist list

# 从外部机器直连，应该超时而不是 200
curl -m 8 http://<你的IP>:7001/    # 期望: curl: (28) timed out
```

---

## 原理

`apply` 每次重建整个规则集合，不是增量追加，所以反复执行结果一致，不会叠规则：

```bash
# 1. 清掉本工具之前写的所有规则（只认带 --dport <port> 的）
iptables -S DOCKER-USER | grep -- "--dport 7001" | sed 's/^-A /-D /' | xargs -r iptables

# 2. 先插兜底 DROP
iptables -I DOCKER-USER 1 -p tcp --dport 7001 -j DROP

# 3. 倒序把每条放行插到位置 1，最终顺序与列表一致
iptables -I DOCKER-USER 1 -p tcp --dport 7001 -s <列表末项> -j RETURN
...
iptables -I DOCKER-USER 1 -p tcp --dport 7001 -s <列表首项> -j RETURN
```

最终链形态：

```
-A DOCKER-USER -s 203.0.113.10/32 -p tcp -m tcp --dport 7001 -j RETURN
-A DOCKER-USER -s 198.51.100.0/24   -p tcp -m tcp --dport 7001 -j RETURN
-A DOCKER-USER -p tcp -m tcp --dport 7001 -j DROP
```

匹配放行的直接 `RETURN`（跳出 `DOCKER-USER`，继续走 docker 的转发），其余 `DROP`。

**顺序必须是 `RETURN` 在前、`DROP` 在后**，反了的话所有流量都会先被 DROP 掉。

只删自己写的规则（`--dport <port>`），不会碰 `DOCKER-USER` 链里别的规则，也不会碰 docker 自动生成的链尾 `RETURN`。

持久化靠 systemd：

```ini
[Unit]
Description=XBoard origin allowlist for port 7001 (DOCKER-USER chain)
After=docker.service ufw.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xboard-allowlist apply
RemainAfterExit=yes
```

`After=docker.service` 保证链已经建好；脚本内部会重试最多 60 秒等待 `DOCKER-USER` 出现。

---

## 排错

### `DOCKER-USER 链不存在（docker 没在运行？）`

`DOCKER-USER` 是 docker 启动时创建的。检查：

```bash
systemctl status docker
iptables -S DOCKER-USER
```

### 加了 IP 但还是 504

先确认流量到没到服务器：

```bash
# 抓新连接
iptables -I INPUT -p tcp --dport 7001 -m state --state NEW -j LOG --log-prefix "P7001: "
sleep 30
grep P7001: /var/log/kern.log | tail -5
iptables -D INPUT -p tcp --dport 7001 -m state --state NEW -j LOG
```

如果抓到了 IP，说明 CDN 用的是另一个回源地址，加进列表即可。

**注意**：已经建立的连接走 conntrack 快速路径，不受新加的 DROP 影响，所以测试时要用**新的**外部连接。

### 面板自己也不通了

确认 `127.0.0.1` 这条路径没被误伤：

```bash
xboard-allowlist test     # 期望 200
```

`test` 走的是回环，不经过 `DOCKER-USER` 的 `RETURN`/`DROP`（本机流量不匹配外部接口），应该始终通的。如果不通，说明容器本身有问题，跟白名单无关。

### 重启后规则没了

```bash
systemctl is-enabled xboard-allowlist.service
systemctl status xboard-allowlist.service
journalctl -u xboard-allowlist.service -n 20
```

### 想彻底回退

```bash
systemctl disable --now xboard-allowlist.service
rm -f /etc/systemd/system/xboard-allowlist.service
systemctl daemon-reload
iptables -S DOCKER-USER | grep -- '--dport 7001' | sed 's/^-A /-D /' | xargs -r iptables
```

---

## 已知限制

- **只处理 IPv4。** `DOCKER-USER` 的 IPv6 版本是 `ip6tables` 的独立链，需要 docker 启用 IPv6 才有意义。
- **要求 docker 使用 iptables。** 如果 `/etc/docker/daemon.json` 里关了 `"iptables": false`，`DOCKER-USER` 不会被调用。
- **不替代 CDN 侧防护。** 这个工具只限制"谁能连到容器端口"，不做请求内容过滤。要防绕过 CDN，还应在 nginx 层校验自定义 header 或 CDN 回源 IP。
- **`flush` 依赖规则格式。** 带 `--comment` 的手工规则如果恰好也匹配 `--dport <port>`，会被一起清掉。这是有意的——保证 `apply` 幂等。

---

## License

MIT

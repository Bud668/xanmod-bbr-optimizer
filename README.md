<div align="center">

# 🚀 VPS Proxy Suite

**VPS 代理一键部署与运维脚本**

一键安装 Snell v5 · Realm 中转 · Shadowsocks-Rust · BBR v3 · XanMod 内核优化

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-blue)
![Shell](https://img.shields.io/badge/shell-bash-lightgrey)
![Version](https://img.shields.io/badge/version-v13.2-green)

</div>

---

## ⚡ 一键启动

**curl（推荐）：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/Bud668/VPS-Proxy-Suite/main/ipt_prxy.sh)
```

**wget（备用）：**
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Bud668/VPS-Proxy-Suite/main/ipt_prxy.sh)
```

**通用（curl / wget / 自动安装，裸系统也能用）：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/Bud668/VPS-Proxy-Suite/main/ipt_prxy.sh 2>/dev/null || wget -qO- https://raw.githubusercontent.com/Bud668/VPS-Proxy-Suite/main/ipt_prxy.sh 2>/dev/null || (apt-get install -y curl -qq >/dev/null 2>&1 && curl -sL https://raw.githubusercontent.com/Bud668/VPS-Proxy-Suite/main/ipt_prxy.sh))
```

> 需要 root 权限，支持 Debian 10+ / Ubuntu 20.04+

---

## 📋 目录

- [功能总览](#功能总览)
- [亮点功能详解](#亮点功能详解)
  - [Snell v5 高性能代理](#-snell-v5-高性能代理)
  - [Realm 智能流量中转](#-realm-智能流量中转)
  - [BBR v3 + XanMod 内核优化](#-bbr-v3--xanmod-内核网络优化)
  - [Telegram 实时告警](#-telegram-实时告警)
  - [流量配额管理](#-流量配额管理)
  - [一键防火墙管理](#-防火墙与安全)
- [菜单结构](#菜单结构)
- [安装说明](#安装说明)
- [文件路径](#文件路径)

---

## 功能总览

| 分类 | 功能 |
|------|------|
| 🖥️ **系统优化** | XanMod 内核一键安装、BBR v3 拥塞控制、网络缓冲区动态调优 |
| 🔒 **安全防护** | Fail2Ban 防暴力破解、SSH 端口定制、iptables 策略、CN IP 封禁 |
| 🌐 **代理服务** | Snell v5 多实例、Shadowsocks-Rust、SOCKS5 |
| 🔀 **流量转发** | Realm 高性能中转、链式转发、失效规则自动清理 |
| 📊 **监控告警** | Telegram 推送、SSH 登录通知、TCPing 入口丢包监测、每日状态报告 |
| 💾 **流量管理** | 月度流量配额、超量自动封禁、到期日管理、每日用量报告 |

---

## 亮点功能详解

### ⚡ Snell v5 高性能代理

[Snell](https://github.com/nicholasgasior/snell-server) 是专为 Surge 设计的轻量加密代理协议，v5 版本在性能和安全性上大幅提升。

**本脚本提供：**

- **一键安装最新版**：自动检测 GitHub Release，无需手动查版本号
- **多实例并行**：同一台机器可运行多个 Snell 实例（不同端口），每实例独立 systemd 服务，互不影响
- **PSK 自动生成**：随机生成高强度 PSK，也支持手动指定
- **配置行自动输出**：安装完成后直接输出 Surge 格式配置，复制即用
- **一键升级**：保留所有配置，无感更新到最新版

```
# 安装完成后自动输出（Surge 格式）
🇯🇵Tokyo = snell, 1.2.3.4, 12345, psk=abc123xxx, version=5, reuse=true, tfo=true
```

---

### 🔀 Realm 智能流量中转

[Realm](https://github.com/zhboner/realm) 是基于 Rust 的零开销端口转发工具，适合搭建中转节点。

**本脚本提供：**

- **一键安装与规则管理**：向导式添加转发规则，无需手写配置文件
- **链式转发**：本机 → 中转 → 落地，支持多跳链路，自动携带 Snell PSK 元数据
- **自动生成节点配置**：中转规则添加后直接输出完整 Snell 配置行（含落地节点国旗）
- **失效规则自动清理**：定时检测转发目标是否可达，不通则自动删除规则并发 TG 告警
- **一键重启**：所有 Realm 规则统一重启，无需逐条操作

```
# 链式转发示意
用户 → 中转机(Realm) → 落地机(Snell v5)
              ↑ 本脚本自动处理端口映射和 PSK 传递
```

---

### 🌐 BBR v3 + XanMod 内核网络优化

针对代理服务器的网络性能瓶颈做系统级优化，是稳定跑高流量的关键。

#### XanMod 内核

[XanMod](https://xanmod.org/) 是面向性能优化的 Linux 内核，内置 BBR v3 拥塞控制算法。

- 一键安装最新 XanMod 内核（从官方 APT 源）
- 安装完成提示重启，重启后自动切换到新内核
- 支持多版本切换（EDGE / 主线版）

#### BBR v3 拥塞控制

BBR v3 相比传统 CUBIC 在高延迟、高丢包网络下有显著吞吐量提升，适合跨境代理场景。

```bash
# 脚本自动写入 sysctl
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

#### 网络缓冲区动态调优

根据你服务器的实际带宽，**自动计算最优的 TCP 缓冲区大小**：

| 参数 | 说明 |
|------|------|
| `rmem_max` / `wmem_max` | 套接字接收/发送缓冲区上限，按带宽动态计算 |
| `tcp_rmem` / `tcp_wmem` | TCP 读写缓冲区三级配置 |
| `netdev_max_backlog` | 网卡队列深度 |
| `somaxconn` | 最大连接数队列 |

> 1Gbps 带宽服务器缓冲区和 100Mbps 服务器最优参数完全不同，脚本会按实际带宽套用对应模板。

---

### 📱 Telegram 实时告警

所有运维事件通过 TG 机器人实时推送，无需盯着日志。

| 告警类型 | 触发条件 | 推送内容 |
|----------|----------|----------|
| 🔐 SSH 登录通知 | 有人 SSH 登录服务器 | 登录 IP、用户名、时间、地理位置 |
| ⚠️ 中转失效告警 | Realm 转发目标不可达 | 失效规则详情，自动已删除 |
| 📊 每日状态报告 | 每天定时 | 各服务状态、在线时长 |
| 💾 流量配额告警 | 用量超限或到期 | 端口、用量、剩余额度 |
| 🔴 丢包监测告警 | TCPing 检测入口丢包异常 | 丢包率、持续时长 |

配置一次，所有告警统一发到同一个 TG 频道/群组。

---

### 💾 流量配额管理

基于 iptables 计数的精准流量统计与控制系统。

**工作原理：**

```
为每个 Realm 转发端口添加 iptables 计数规则
       ↓
每日定时汇总计数，累加到月度统计文件
       ↓
超出配额 → 自动添加 DROP 规则封禁端口 + TG 告警
到达到期日 → 自动封禁 + TG 告警
```

**支持功能：**
- 按端口设置月度流量上限（GB 级）
- 设置到期日（精确到天）
- 每日 TG 推送用量报告（已用 / 剩余 / 到期日）
- 超量或到期后一键解封（续费/续量后手动恢复）

---

### 🔒 防火墙与安全

#### iptables 精细管控
- 默认策略 DROP，只放行显式规则（最小暴露面）
- 向导式开放/关闭端口（TCP/UDP 可分别控制）
- 规则持久化（`iptables-persistent`，重启不丢失）
- **CN IP 封禁**：加载完整中国大陆 IP 段到 ipset，一条规则阻断全部大陆访问

#### Fail2Ban 防暴力破解
- 自动配置 SSH 登录失败封禁策略
- 支持自定义封禁阈值和封禁时长
- IP 白名单管理（管理员 IP 永不被封）

#### 测试模式
临时开放 Ping 和 iperf3 测速，**2 小时后自动关闭**，不用担心忘记手动恢复安全策略。

---

## 菜单结构

```
╔══════════════════════════════════════════════════════════════╗
║       Server & Proxy Manager      v13.2                     ║
╚══════════════════════════════════════════════════════════════╝

 [ 系统管理 ]
  1  一键初始化          4  切换测试模式
  2  Fail2Ban & SSH      5  防火墙规则
  3  TG 推送配置         6  系统维护 / 内核 / BBR

 [ 代理服务 ]                [ 规则与转发 ]
  7  Snell v5             11  添加 Realm 转发规则
  8  Realm 中转           12  重启 Realm
  9  Shadowsocks-Rust     13  检测并清理失效规则
 10  SOCKS5               14  流量配额与到期管理
                          15  查看运行日志

 [ 进阶控制 ]
 16  启停服务
 17  更新服务（Snell / SS-Rust / Realm / SOCKS5）
 18  卸载服务
```

---

## 安装说明

### 1. 首次部署（新服务器）

```bash
# 一键启动
bash <(curl -sL https://raw.githubusercontent.com/Bud668/VPS-Proxy-Suite/main/ipt_prxy.sh)

# 选择「1. 一键初始化」，按向导完成：
# ① 系统更新 → ② 设置节点名称 → ③ 安装 XanMod 内核
# ④ 网络参数优化 → ⑤ 防火墙初始化 → ⑥ TG 告警配置
```

> 安装 XanMod 内核后需重启一次，重启后再运行脚本安装代理服务。

### 2. 安装 Snell v5

```bash
# 运行脚本 → 选择「7. 安装/管理 Snell」
# 按提示输入端口号（或回车随机生成）
# 安装完成后自动输出 Surge 配置行
```

### 3. 配置 Realm 中转

```bash
# 运行脚本 → 选择「11. 添加转发规则」
# 输入：落地机 IP、落地机 Snell 端口、落地机 PSK
# 脚本自动分配本地端口，输出中转节点配置行
```

### 4. 守护进程（自动化任务）

脚本安装时自动配置 systemd 定时器，无需手动设置：

```bash
bash ipt_prxy.sh daemon       # 中转存活检测
bash ipt_prxy.sh daily        # 每日状态报告
bash ipt_prxy.sh quota-check  # 流量配额检查
bash ipt_prxy.sh quota-daily  # 配额每日报告
```

---

## 文件路径

| 路径 | 用途 |
|------|------|
| `/opt/proxy-manager/` | 脚本工作目录（缓存、统计数据） |
| `/etc/snell/` | Snell 实例配置 |
| `/etc/shadowsocks-rust/` | SS-Rust 配置 |
| `/etc/realm/` | Realm 转发规则及元数据 |
| `/etc/ssh-tg-monitor.conf` | TG 告警配置 |
| `/etc/tcping-monitor.conf` | TCPing 监控配置 |
| `/var/log/proxy-manager.log` | 脚本运行日志 |

---

## 常见问题

**Q: 安装 XanMod 后 BBR v3 没生效？**  
重启服务器后再执行 `sysctl net.ipv4.tcp_congestion_control`，确认输出为 `bbr`。

**Q: Realm 转发规则失效告警频繁？**  
检查落地机是否在线，或落地机防火墙是否放行对应端口。

**Q: 流量配额重启后计数归零？**  
iptables 计数器重启后清零，脚本每日将计数持久化到文件进行累加，月度统计不受影响。

**Q: CN IP 封禁后我自己访问不了？**  
将你的 IP 加入白名单（选项 2 → 白名单管理），或临时切换防火墙为 ACCEPT 模式。

---

## License

MIT License — 自由使用，保留署名。

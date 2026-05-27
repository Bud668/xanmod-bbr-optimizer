<div align="center">

# ⚡ XanMod BBR Optimizer

**Linux 服务器网络调优脚本**

一键安装 XanMod 内核 · BBR v3 拥塞控制 · TCP 缓冲区优化 · Fail2Ban 安全加固

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-blue)
![Shell](https://img.shields.io/badge/shell-bash-lightgrey)
![Version](https://img.shields.io/badge/version-v13.2-green)

</div>

---

## ⚡ 一键启动

**curl（推荐）：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/Bud668/xanmod-bbr-optimizer/main/vps-mgr.sh)
```

**wget（备用）：**
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Bud668/xanmod-bbr-optimizer/main/vps-mgr.sh)
```

**通用（裸系统自动安装 curl）：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/Bud668/xanmod-bbr-optimizer/main/vps-mgr.sh 2>/dev/null || wget -qO- https://raw.githubusercontent.com/Bud668/xanmod-bbr-optimizer/main/vps-mgr.sh 2>/dev/null || (apt-get install -y curl -qq >/dev/null 2>&1 && curl -sL https://raw.githubusercontent.com/Bud668/xanmod-bbr-optimizer/main/vps-mgr.sh))
```

> 需要 root 权限，支持 Debian 10+ / Ubuntu 20.04+

---

## 功能总览

| 分类 | 功能 |
|------|------|
| 🚀 **内核优化** | XanMod 内核一键安装、BBR v3 拥塞控制 |
| 📶 **网络调优** | TCP 缓冲区动态计算、网络参数 sysctl 优化 |
| 🔒 **安全加固** | Fail2Ban 防暴力破解、SSH 端口定制、iptables 防火墙 |
| 📊 **监控告警** | Telegram 推送、SSH 登录通知、TCPing 丢包监测 |
| 🛠️ **系统管理** | 防火墙规则管理、流量统计、服务启停 |

---

## 亮点功能详解

### 🚀 XanMod 内核 + BBR v3

[XanMod](https://xanmod.org/) 是专为性能优化设计的 Linux 内核，内置 BBR v3 拥塞控制算法。

**BBR v3 vs 传统 CUBIC：**
- 高延迟网络下吞吐量显著提升
- 高丢包场景下更稳定
- 适合跨境、高延迟 VPS 场景

```bash
# 脚本自动写入 sysctl
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

- 从官方 APT 源一键安装最新 XanMod 内核
- 安装后提示重启，重启自动生效
- 支持多版本切换（EDGE / 主线）

---

### 📶 TCP 缓冲区动态调优

根据服务器实际带宽**自动计算最优参数**，而不是套用固定模板：

| 参数 | 说明 |
|------|------|
| `rmem_max` / `wmem_max` | 套接字缓冲区上限，按带宽动态计算 |
| `tcp_rmem` / `tcp_wmem` | TCP 读写缓冲区三级配置 |
| `netdev_max_backlog` | 网卡队列深度 |
| `somaxconn` | 最大连接数队列 |

> 1Gbps 和 100Mbps 的服务器最优参数完全不同，脚本自动按带宽套用对应模板。

---

### 🔒 安全加固

**Fail2Ban 防暴力破解**
- 自动配置 SSH 登录失败封禁策略
- IP 白名单管理，管理员 IP 永不被封
- 自定义封禁阈值和时长

**iptables 防火墙**
- 默认 DROP 策略，最小暴露面
- 向导式端口开放/关闭
- 规则持久化，重启不丢失

**测试模式**
- 临时开放 Ping 和 iperf3，**2 小时自动关闭**
- 不用担心忘记恢复安全策略

---

### 📱 Telegram 实时告警

| 告警类型 | 触发条件 |
|----------|----------|
| 🔐 SSH 登录通知 | 有人登录服务器，推送 IP + 时间 |
| 📊 每日状态报告 | 定时推送服务状态摘要 |
| 🔴 丢包监测告警 | TCPing 检测入口丢包异常 |

---

## 菜单结构

```
 [ 系统管理 ]
  1  一键初始化（内核 + 调优 + 防火墙）
  2  Fail2Ban & SSH 安全配置
  3  Telegram 告警配置
  4  测试模式（临时开放 Ping/iperf3）
  5  防火墙规则管理
  6  系统维护 / 内核切换 / BBR 参数

 [ 进阶控制 ]
 16  服务启停
 17  更新组件
 18  卸载组件
```

---

## 安装说明

```bash
bash <(curl -sL https://raw.githubusercontent.com/Bud668/xanmod-bbr-optimizer/main/vps-mgr.sh)

# 选择「1. 一键初始化」完成：
# ① 系统更新 → ② XanMod 内核 → ③ 网络参数调优
# ④ 防火墙初始化 → ⑤ Fail2Ban → ⑥ TG 告警配置
```

> 安装 XanMod 内核后需重启一次，重启后 BBR v3 自动生效。

### 验证 BBR v3 已启用

```bash
sysctl net.ipv4.tcp_congestion_control
# 输出: net.ipv4.tcp_congestion_control = bbr

uname -r
# 输出应包含: xanmod
```

---

## 常见问题

**Q: 安装 XanMod 后 BBR v3 没生效？**
重启后再验证，确认 `uname -r` 输出包含 `xanmod`。

**Q: 支持 CentOS 吗？**
目前仅支持 Debian / Ubuntu，XanMod 官方 APT 源仅面向 Debian 系。

**Q: 网络参数调优后速度反而变慢？**
选择「6. 系统维护」→「查看/修改 BBR 参数」，可手动调整或恢复默认值。

---

## License

MIT License — 自由使用，保留署名。

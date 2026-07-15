# VPS Manager

A single-file Bash TUI for managing Debian/Ubuntu servers: kernel tuning, firewall hardening, proxy service deployment, port forwarding, traffic accounting, and Telegram-based monitoring.

All configuration is entered interactively at runtime. No credentials are stored in this repository.

## Requirements

- Debian / Ubuntu (uses `apt`)
- systemd
- root privileges

## Usage

Run as root. Installs `curl` if it's missing, so this works on a minimal image
where no downloader is present:

```bash
command -v curl >/dev/null || { echo "Installing curl (a few seconds)..."; apt-get update -qq && apt-get install -y -qq curl; }; echo "Downloading..."; curl -fsSL https://raw.githubusercontent.com/springvip/vps-mgr/main/vps-mgr.sh -o vps-mgr.sh && chmod +x vps-mgr.sh && ./vps-mgr.sh
```

The script is menu-driven — run it and pick an option. On a new server, start
with `[1] Quick Init`, which installs the remaining dependencies
(`wget`, `jq`, `socat`, `iptables-persistent`, `fail2ban`, `ipset`, and others).

## Features

**System tuning**
- Adaptive `sysctl` tuning based on measured bandwidth (separate profiles for relay vs. landing nodes)
- BBR congestion control, conntrack, file descriptor and journald limits
- Swap provisioning, IPv6 toggle

**Security**
- iptables firewall management with persistence
- SSH hardening (custom port, key-only auth)
- Fail2Ban installation with IP whitelisting
- Optional per-port CIDR allowlists

**Proxy services**
- [sing-box](https://github.com/SagerNet/sing-box) — Shadowsocks, SOCKS5, Hysteria2
- Snell
- Install, update, and uninstall via systemd units

**Port forwarding**
- [realm](https://github.com/zhboner/realm) forwarding rules with dead-endpoint detection

**Monitoring & reporting**
- TCPing latency/jitter/loss probing with daily Telegram reports
- Connection statistics
- Per-port traffic quotas with automatic pause and Telegram alerts

**DNS**
- Cloudflare DDNS with automatic A-record creation and health checks

## Third-party components

This script downloads and configures software from upstream projects, each under its own license:

- [sing-box](https://github.com/SagerNet/sing-box)
- [realm](https://github.com/zhboner/realm)

## Disclaimer

Provided as-is, without warranty of any kind. This tool modifies system-level configuration (kernel parameters, firewall rules, SSH settings) and installs services. Review the script before running it, and use it only on servers you own or are authorized to administer. You are responsible for complying with all applicable laws and with the terms of service of your hosting provider.

## License

[MIT](LICENSE)

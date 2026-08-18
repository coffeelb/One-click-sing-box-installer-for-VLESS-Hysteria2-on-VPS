# sing-box VLESS + Hysteria2 One-Click Deployment

## Quick Start

After hosting the script in your own GitHub repository, run the following command as root on your VPS to pull the script and open the management menu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/coffeelb/One-click-sing-box-installer-for-VLESS-Hysteria2-on-VPS/main/sing-box.sh)
```

## Verification & Troubleshooting

```bash
systemctl status sing-box     # Service status
journalctl -u sing-box -f     # Live logs
sing-box check -c /etc/sing-box/config.json   # Validate config
```

Common issues:

- **Service fails to start**: check the logs first; common causes are the port being occupied or the bound IP version (`listen`) being unavailable.
- **Cannot connect**: make sure both the cloud security group and the system firewall allow the port.
- **Handshake failure/timeout**: try a different SNI (reachability varies between big-company CDNs) and confirm the server time is accurate (the config includes built-in NTP time sync).
- **HY2 cannot connect**: make sure the UDP port is open; in domain mode, confirm the domain resolves correctly (`dig your-domain`).
- **Reality private key leakage**: the private key stays on the server only; clients use the public key. To rotate keys, regenerate them and update both ends.

## Disclaimer

For personal technical learning and legal use only. Please comply with the laws and regulations of both the server's location and your own.

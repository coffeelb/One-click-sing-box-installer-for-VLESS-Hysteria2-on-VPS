# sing-box VLESS + Reality + XTLS-Vision One-Click Deployment

## Quick Start

After hosting the script in your own GitHub repository, run the following command as root on your VPS to pull the script and open the management menu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/coffeelb/One-click-sing-box-installer-for-VLESS-Hysteria2-on-VPS/main/sing-box.sh)
```

Management subcommands (corresponding to the menu options):

```bash
bash <(curl -fsSL ...) info                 # Show node info and share links
bash <(curl -fsSL ...) restart              # Restart the service
bash <(curl -fsSL ...) status               # Show status and logs
bash <(curl -fsSL ...) autostart on|off|status   # Configure autostart on boot
bash <(curl -fsSL ...) update               # Update the sing-box core
bash <(curl -fsSL ...) change-port          # Change port (interactive)
bash <(curl -fsSL ...) change-sni           # Change SNI (interactive)
bash <(curl -fsSL ...) uninstall            # Uninstall (requires confirmation)
```

## Firewall

```bash
# UFW
ufw allow 8443/tcp
ufw allow 8443/udp        # HY2 uses UDP; allow both TCP and UDP if it shares the port with VLESS

# firewalld
firewall-cmd --add-port=8443/tcp --permanent
firewall-cmd --add-port=8443/udp --permanent
firewall-cmd --reload

# Also open the corresponding port in your cloud provider's security group
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

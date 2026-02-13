# Ensure Network (eth0) is up

It can happen that the network manager does not work and the ethernet connection will not come up (for example when desktop environment is removed).

To access the Jetson Nano via ssh ethernet connection, you need to bring up eth0 either manually (with monitor / keyboard required) or run the following script during boot.

## 1. Network script

This script checks whether eth0 exists + has a carrier + has an IPv4 address and if not, does ip link set eth0 up + dhclient eth0

`/usr/local/sbin/ensure-eth0.sh`

```
#!/usr/bin/env bash
set -euo pipefail

IFACE="eth0"

# If the interface doesn't exist, exit cleanly (don’t break boot).
ip link show "$IFACE" >/dev/null 2>&1 || exit 0

# Bring link up (idempotent)
ip link set "$IFACE" up || true

# If there's no carrier, don't waste time on DHCP
if [[ -f "/sys/class/net/$IFACE/carrier" ]] && [[ "$(cat "/sys/class/net/$IFACE/carrier")" != "1" ]]; then
  exit 0
fi

# If we already have an IPv4 address, we're good
if ip -4 addr show dev "$IFACE" | grep -q "inet "; then
  exit 0
fi

# Try DHCP (short + blocking)
dhclient -4 -v -1 "$IFACE" || true

# Optional: print resulting address to the journal
ip -4 addr show dev "$IFACE" || true

```

make sure it is executbale:

`sudo chmod +x /usr/local/sbin/ensure-eth0.sh`


## 2. Systemd unit

Runs the above script during boot

`/etc/systemd/system/ensure-eth0.service`

```
[Unit]
Description=Ensure eth0 is up and has DHCP lease
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ensure-eth0.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target

```

Enable it on every boot

```
sudo systemctl daemon-reload
sudo systemctl enable ensure-eth0.service
sudo systemctl start ensure-eth0.service
```

check the service logs with

`sudo systemctl status ensure-eth0.service`

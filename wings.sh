#!/bin/bash
set -e

# ==============================
# Configurable arguments
# ==============================
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --api) CF_API=$2; shift ;;
    --zone) CF_ZONE=$2; shift ;;
    --domain) CF_DOMAIN=$2; shift ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$CF_API" || -z "$CF_ZONE" || -z "$CF_DOMAIN" ]]; then
  echo "Usage: $0 --api <cloudflare_api> --zone <zone_id> --domain <domain>"
  exit 1
fi

# ==============================
# Update system and install Docker
# ==============================
echo "[*] Updating system packages..."
apt update && apt upgrade -y

echo "[*] Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# ==============================
# Enable swap accounting (if GRUB exists)
# ==============================
echo "[*] Enabling swap accounting..."
if [[ -f "/etc/default/grub" ]]; then
  sed -i 's/GRUB_CMDLINE_LINUX="[^"]*/& swapaccount=1/' /etc/default/grub
  update-grub
else
  echo "No GRUB found, skipping swapaccount step."
fi

# ==============================
# Install Wings
# ==============================
echo "[*] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ \"$(uname -m)\" == \"x86_64\" ]] && echo \"amd64\" || echo \"arm64\")"
chmod +x /usr/local/bin/wings

# Create systemd service
echo "[*] Creating systemd service for Wings..."
cat >/etc/systemd/system/wings.service <<EOL
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

systemctl enable --now wings

# ==============================
# Install firewalld + configure rules
# ==============================
echo "[*] Installing and configuring firewalld..."
apt install -y firewalld
systemctl enable --now firewalld

# Disable ufw if present
ufw disable || true
systemctl stop ufw || true
systemctl disable ufw || true

# TCP ports
firewall-cmd --permanent --add-port=2022/tcp
firewall-cmd --permanent --add-port=5657/tcp
firewall-cmd --permanent --add-port=56423/tcp
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=25565-25800/tcp
firewall-cmd --permanent --add-port=50000-50500/tcp
firewall-cmd --permanent --add-port=19132/tcp

# UDP ports
firewall-cmd --permanent --add-port=8080/udp
firewall-cmd --permanent --add-port=25565-25800/udp
firewall-cmd --permanent --add-port=50000-50500/udp
firewall-cmd --permanent --add-port=19132/udp

firewall-cmd --reload
echo "✅ Firewalld setup complete!"

# ==============================
# Setup Cloudflare DNS records
# ==============================
echo "[*] Setting up Cloudflare DNS records..."
read -p "Enter a name for this Wings node (used for comments): " NODE_NAME

SERVER_IP=$(curl -s ifconfig.me)
DNS_BASE="node"
GAME_BASE="game"

# Find next available number
for i in $(seq 1 50); do
  if ! curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?name=${DNS_BASE}-${i}.${CF_DOMAIN}" \
    -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | grep -q '"count":1'; then
    NODE_NUM=$i
    break
  fi
done

CF_NODE_NAME="${DNS_BASE}-${NODE_NUM}.${CF_DOMAIN}"
CF_GAME_NAME="${GAME_BASE}-${NODE_NUM}.${CF_DOMAIN}"

# Create Wings DNS
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
  -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"${CF_NODE_NAME}\",\"content\":\"${SERVER_IP}\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME Wings FQDN\"}" >/dev/null

# Create Game DNS
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
  -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"${CF_GAME_NAME}\",\"content\":\"${SERVER_IP}\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME Game IP\"}" >/dev/null

echo "✅ DNS records created:"
echo " - $CF_NODE_NAME"
echo " - $CF_GAME_NAME"

# ==============================
# System resources for panel setup
# ==============================
TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 2048))

TOTAL_DISK_MB=$(df --output=size -m / | tail -1)
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 51200))

# ==============================
# Final Summary
# ==============================
echo
echo "=============================================="
echo "✅ Wings Node Setup Complete!"
echo "Details for adding this node in the Pterodactyl Panel:"
echo
echo "  Node Name   : $NODE_NAME"
echo "  Wings FQDN  : $CF_NODE_NAME"
echo "  Game FQDN   : $CF_GAME_NAME"
echo "  Public IP   : $SERVER_IP"
echo "  Wings Port  : 8080 (default)"
echo "  RAM (alloc) : ${ALLOC_RAM_MB} MB (from total ${TOTAL_RAM_MB} MB)"
echo "  Disk (alloc): ${ALLOC_DISK_MB} MB (from total ${TOTAL_DISK_MB} MB)"
echo
echo "IP Aliases:"
echo "  Wings Node : $CF_NODE_NAME → $SERVER_IP"
echo "  Game Node  : $CF_GAME_NAME → $SERVER_IP"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

#!/bin/bash
# wings.sh - Automated Pterodactyl Wings installer with Cloudflare auto-DNS and firewalld setup
# Author: FlyingAura
# Run as root: sudo ./wings.sh

set -e

# ===== Prompt for node name =====
read -rp "Enter a name for this Wings node (used as Cloudflare comment): " NODE_NAME

# ===== Root check =====
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script as root (sudo ./wings.sh)"
  exit 1
fi

# ===== System update =====
echo "[1/8] Updating system packages..."
apt update && apt upgrade -y

# ===== Docker install =====
echo "[2/8] Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# ===== Swap accounting =====
echo "[3/8] Enabling swap accounting..."
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' /etc/default/grub
update-grub

# ===== Wings install =====
echo "[4/8] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

# ===== systemd service =====
echo "[5/8] Creating systemd service for Wings..."
cat > /etc/systemd/system/wings.service << 'EOF'
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
EOF

systemctl daemon-reload
systemctl enable --now wings

# ===== Cloudflare auto-DNS =====
echo "[6/8] Setting up Cloudflare auto-DNS record..."
# CONFIGURE THESE VARIABLES
CF_API_TOKEN="your_api_token_here"
CF_ZONE_ID="your_zone_id_here"
CF_DOMAIN="example.com"
SUB_PREFIX="node"
COMMENT="$NODE_NAME"

# Install dependencies
apt install -y jq curl >/dev/null 2>&1

# Get public IP
SERVER_IP=$(curl -s https://ipv4.icanhazip.com)

# Find first available subdomain
for i in $(seq 1 50); do
  CANDIDATE="${SUB_PREFIX}-${i}.${CF_DOMAIN}"
  RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$CANDIDATE" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

  if [ "$RECORD_ID" == "null" ] || [ -z "$RECORD_ID" ]; then
    CF_RECORD_NAME="$CANDIDATE"
    break
  fi
done

if [ -z "$CF_RECORD_NAME" ]; then
  echo "❌ No free subdomains found (1–50 tried)."
  exit 1
fi

# Create DNS record
echo "Creating DNS record: $CF_RECORD_NAME → $SERVER_IP (comment: $COMMENT)"
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{
    \"type\": \"A\",
    \"name\": \"$CF_RECORD_NAME\",
    \"content\": \"$SERVER_IP\",
    \"ttl\": 120,
    \"proxied\": false,
    \"comment\": \"$COMMENT\"
  }" | jq .

# ===== Resource calculation =====
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 2048))
TOTAL_DISK_MB=$(df --block-size=1M / | awk 'NR==2 {print $2}')
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 51200))

# ===== Firewalld setup =====
echo "[7/8] Installing and configuring firewalld..."
apt update -y
apt install -y firewalld

# Disable other firewalls (ufw)
ufw disable || true
systemctl stop ufw || true
systemctl disable ufw || true

# Enable firewalld
systemctl enable --now firewalld

# Configure allowed ports
# TCP
firewall-cmd --permanent --add-port=2022/tcp
firewall-cmd --permanent --add-port=5657/tcp
firewall-cmd --permanent --add-port=56423/tcp
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=25565-25800/tcp
firewall-cmd --permanent --add-port=50000-50500/tcp
firewall-cmd --permanent --add-port=19132/tcp
# UDP
firewall-cmd --permanent --add-port=8080/udp
firewall-cmd --permanent --add-port=25565-25800/udp
firewall-cmd --permanent --add-port=50000-50500/udp
firewall-cmd --permanent --add-port=19132/udp

firewall-cmd --reload
echo "✅ Firewalld setup complete!"
echo "Allowed TCP: 2022, 5657, 56423, 8080, 25565-25800, 19132, 50000-50500"
echo "Allowed UDP: 8080, 25565-25800, 19132, 50000-50500"

# ===== Summary =====
echo
echo "=============================================="
echo "✅ Wings Node Setup Complete!"
echo "Details for adding this node in the Pterodactyl Panel:"
echo
echo "  Node Name   : $NODE_NAME"
echo "  FQDN        : $CF_RECORD_NAME"
echo "  Public IP   : $SERVER_IP"
echo "  Wings Port  : 8080 (default)"
echo "  RAM (alloc) : ${ALLOC_RAM_MB} MB (from total ${TOTAL_RAM_MB} MB)"
echo "  Disk (alloc): ${ALLOC_DISK_MB} MB (from total ${TOTAL_DISK_MB} MB)"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

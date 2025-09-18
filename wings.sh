#!/bin/bash
# wings.sh - Automated Pterodactyl Wings installer with Cloudflare auto-DNS
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
echo "[1/7] Updating system packages..."
apt update && apt upgrade -y

# ===== Docker install =====
echo "[2/7] Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# ===== Swap accounting =====
echo "[3/7] Enabling swap accounting..."
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' /etc/default/grub
update-grub

# ===== Wings install =====
echo "[4/7] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

# ===== systemd service =====
echo "[5/7] Creating systemd service for Wings..."
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
echo "[6/7] Setting up Cloudflare auto-DNS record..."
# CONFIGURE THESE VARIABLES
CF_API_TOKEN="Ve6F0M2s0xEizHu7fPw6DfpVPDOXCuKpgCGtEzrk"
CF_ZONE_ID="99fd720b3ecd19f20068d94aeb1c5010"
CF_DOMAIN="hexiumnodes.cloud"
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
echo "⚠️  Reminder: Configure /etc/pterodactyl/config.yml using the token from your panel."
echo
echo "Next, secure your server by running the firewall setup script:"
echo "  bash <(curl -s https://raw.githubusercontent.com/LakshyaTheMinecrafter/skript.sh/main/firewalld.sh)"
echo "=============================================="

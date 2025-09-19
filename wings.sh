#!/bin/bash
set -e

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root" 
   exit 1
fi

# ---------------- Parse arguments ----------------
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --api) CF_API="$2"; shift; shift ;;
    --zone) CF_ZONE="$2"; shift; shift ;;
    --domain) CF_DOMAIN="$2"; shift; shift ;;
    *) shift ;;
  esac
done

# ---------------- Prompt if missing ----------------
read -p "Enter a name for this Wings node (used in comments): " NODE_NAME
[ -z "$CF_API" ] && read -p "Enter your Cloudflare API Token: " CF_API
[ -z "$CF_ZONE" ] && read -p "Enter your Cloudflare Zone ID: " CF_ZONE
[ -z "$CF_DOMAIN" ] && read -p "Enter your Domain (example.com): " CF_DOMAIN

SERVER_IP=$(curl -s https://ipinfo.io/ip)

# ---------------- Install Docker if missing ----------------
if command -v docker &> /dev/null; then
    echo "[1/7] Docker is already installed, skipping installation..."
else
    echo "[1/7] Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    sudo systemctl enable --now docker
fi

# ---------------- Enable swap accounting ----------------
if grep -q "swapaccount=1" /etc/default/grub; then
    echo "[2/7] Swap accounting already enabled"
else
    echo '[2/7] Enabling swap accounting...'
    sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 swapaccount=1"|' /etc/default/grub || echo 'GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"' >> /etc/default/grub
    update-grub || true
fi

# ---------------- Install Wings ----------------
echo "[3/7] Installing Pterodactyl Wings..."
sudo mkdir -p /etc/pterodactyl
ARCH=$(uname -m)
ARCH=${ARCH/x86_64/amd64}
ARCH=${ARCH/aarch64/arm64}
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$ARCH"
chmod +x /usr/local/bin/wings

# ---------------- Wings systemd service ----------------
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

# ---------------- Firewalld ----------------
echo "[4/7] Setting up Firewalld..."
sudo apt update -y
sudo apt install -y firewalld
sudo systemctl enable --now firewalld

# Add allowed ports
TCP_PORTS="2022 5657 56423 8080 25565-25800 19132 50000-50500"
UDP_PORTS="8080 25565-25800 19132 50000-50500"

for p in $TCP_PORTS; do
    sudo firewall-cmd --permanent --add-port=$p/tcp || true
done
for p in $UDP_PORTS; do
    sudo firewall-cmd --permanent --add-port=$p/udp || true
done
sudo firewall-cmd --reload
echo "✅ Firewalld setup complete!"
echo "Allowed TCP: $TCP_PORTS"
echo "Allowed UDP: $UDP_PORTS"

# ---------------- Cloudflare DNS ----------------
echo "[5/7] Creating Cloudflare DNS records..."
NEXT_NODE=1
while true; do
    NODE_NAME_CHECK="node-$NEXT_NODE.$CF_DOMAIN"
    RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=$NODE_NAME_CHECK" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json")
    if ! echo "$RESPONSE" | grep -q "\"name\":\"$NODE_NAME_CHECK\""; then
        break
    else
        NEXT_NODE=$((NEXT_NODE+1))
    fi
done

CF_NODE_NAME="node-$NEXT_NODE.$CF_DOMAIN"
CF_GAME_NAME="game-$NEXT_NODE.$CF_DOMAIN"

# Create node record
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
     -H "Authorization: Bearer $CF_API" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"comment\":\"$NODE_NAME\"}" > /dev/null

# Create game record
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
     -H "Authorization: Bearer $CF_API" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"comment\":\"$NODE_NAME game ip\"}" > /dev/null

echo "✅ DNS record created: $CF_NODE_NAME"
echo "✅ DNS record created: $CF_GAME_NAME"

# ---------------- SSL ----------------
echo "[6/7] Installing SSL..."
sudo apt install -y certbot python3-certbot-nginx
certbot certonly --nginx -d "$CF_NODE_NAME" --non-interactive --agree-tos -m your-email@example.com || echo "⚠️ SSL setup failed. Make sure nginx is running and domain resolves correctly."
(crontab -l 2>/dev/null; echo "0 23 * * * certbot renew --quiet --deploy-hook \"systemctl restart nginx\"") | crontab -

# ---------------- Final Info ----------------
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
RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
ALLOC_RAM_MB=$((RAM_MB-1024))
DISK_TOTAL=$(df --output=size -BM / | tail -1 | tr -d 'M ')
DISK_AVAIL=$(df --output=avail -BM / | tail -1 | tr -d 'M ')
echo "  RAM (alloc) : $ALLOC_RAM_MB MB (from total ${RAM_MB} MB)"
echo "  Disk (alloc): ${DISK_AVAIL} MB (from total ${DISK_TOTAL} MB)"

LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | jq -r '.city + ", " + .country')
echo "  Location    : $LOCATION"
echo
echo "IP Aliases:"
echo "  Wings Node : $CF_NODE_NAME → $SERVER_IP"
echo "  Game Node  : $CF_GAME_NAME → $SERVER_IP"
echo
echo "Open Ports:"
echo "  TCP: $TCP_PORTS"
echo "  UDP: $UDP_PORTS"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

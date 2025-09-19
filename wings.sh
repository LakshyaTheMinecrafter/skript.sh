#!/bin/bash
set -e

# ==================== ARGUMENT PARSING ====================
while [[ $# -gt 0 ]]; do
  case $1 in
    --api) CF_API="$2"; shift 2 ;;
    --zone) CF_ZONE="$2"; shift 2 ;;
    --domain) CF_DOMAIN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ==================== 1. Docker Installation ====================
if command -v docker &> /dev/null; then
    echo "[1/7] Docker is already installed, skipping installation..."
else
    echo "[1/7] Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    sudo systemctl enable --now docker
fi

# ==================== 2. Enable Swap Accounting ====================
GRUB_FILE="/etc/default/grub"
if [[ -f "$GRUB_FILE" ]]; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 swapaccount=1"/' "$GRUB_FILE"
    sudo update-grub || true
    echo "[2/7] Swap accounting enabled in GRUB."
else
    echo "[2/7] No GRUB found, skipping swapaccount step."
fi

# ==================== 3. Install Wings ====================
echo "[3/7] Installing Wings..."
sudo mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
sudo chmod u+x /usr/local/bin/wings

# Create systemd service
sudo tee /etc/systemd/system/wings.service > /dev/null <<EOF
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

sudo systemctl enable --now wings

# ==================== 4. Firewalld Setup ====================
echo "[4/7] Setting up firewalld..."
sudo apt update -y
sudo apt install -y firewalld || true
sudo systemctl stop ufw || true
sudo systemctl disable ufw || true
sudo systemctl enable --now firewalld

# Open TCP ports
for port in 2022 5657 56423 8080 25565-25800 50000-50500 19132; do
    sudo firewall-cmd --permanent --add-port=${port}/tcp
done
# Open UDP ports
for port in 8080 25565-25800 50000-50500 19132; do
    sudo firewall-cmd --permanent --add-port=${port}/udp
done
sudo firewall-cmd --reload
echo "✅ Firewalld setup complete!"

# ==================== 5. Cloudflare DNS ====================
echo "[5/7] Configuring Cloudflare DNS..."
if [[ -z "$CF_API" ]]; then
    read -p "Enter your Cloudflare API Key: " CF_API
fi
if [[ -z "$CF_ZONE" ]]; then
    read -p "Enter your Cloudflare Zone ID: " CF_ZONE
fi
if [[ -z "$CF_DOMAIN" ]]; then
    read -p "Enter your Cloudflare Domain: " CF_DOMAIN
fi
read -p "Enter a name for this Wings node (used in comment): " NODE_NAME

# Determine node index
i=1
while curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=node-$i.$CF_DOMAIN" \
    -H "Authorization: Bearer $CF_API" \
    -H "Content-Type: application/json" | grep -q '"result":\[\]'; do
    i=$((i+1))
done

CF_NODE_NAME="node-$i.$CF_DOMAIN"
CF_GAME_NAME="game-$i.$CF_DOMAIN"
SERVER_IP=$(curl -s https://ipinfo.io/ip)

# Create DNS records
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
  -H "Authorization: Bearer $CF_API" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"comment\":\"$NODE_NAME\"}"

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
  -H "Authorization: Bearer $CF_API" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"comment\":\"$NODE_NAME\"}"

# ==================== 6. SSL Certificate ====================
echo "[6/7] Installing SSL..."
sudo apt update
sudo apt install -y certbot
sudo certbot certonly --nginx -d "$CF_NODE_NAME"
(crontab -l 2>/dev/null; echo '0 23 * * * certbot renew --quiet --deploy-hook "systemctl restart nginx"') | crontab -

# ==================== 7. Final Summary ====================
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
ALLOC_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
TOTAL_RAM_MB=$ALLOC_RAM_MB
ALLOC_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
TOTAL_DISK_MB=$(df -m / | awk 'NR==2 {print $2}')
echo "  RAM (alloc) : ${ALLOC_RAM_MB} MB (from total ${TOTAL_RAM_MB} MB)"
echo "  Disk (alloc): ${ALLOC_DISK_MB} MB (from total ${TOTAL_DISK_MB} MB)"
LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | jq -r '.city + ", " + .country')
echo "  Location    : $LOCATION"
echo
echo "IP Aliases:"
echo "  Wings Node : $CF_NODE_NAME → $SERVER_IP"
echo "  Game Node  : $CF_GAME_NAME → $SERVER_IP"
echo
echo "Open Ports:"
echo "  TCP: 2022, 5657, 56423, 8080, 25565-25800, 19132, 50000-50500"
echo "  UDP: 8080, 25565-25800, 19132, 50000-50500"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

#!/bin/bash
set -e

# -------------------- Root Check --------------------
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root."
  exit 1
fi

# -------------------- Node Info --------------------
read -p "Enter a name for this Wings node (used in comments): " NODE_NAME
read -p "Enter your Cloudflare API Token: " CF_API
read -p "Enter your Cloudflare Zone ID: " CF_ZONE
read -p "Enter your Domain (example.com): " CF_DOMAIN

SERVER_IP=$(curl -s https://api.ipify.org)

# -------------------- Docker --------------------
if command -v docker &> /dev/null; then
    echo "[1/7] Docker is already installed, skipping installation..."
else
    echo "[1/7] Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    sudo systemctl enable --now docker
fi

# -------------------- GRUB swapaccount --------------------
echo "[2/7] Enabling swap accounting..."
if grep -q "swapaccount=1" /etc/default/grub; then
    echo "Swap accounting already enabled"
else
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 /' /etc/default/grub
    sudo update-grub || true
fi

# -------------------- Wings --------------------
echo "[3/7] Installing Pterodactyl Wings..."
sudo mkdir -p /etc/pterodactyl
ARCH=$(uname -m)
ARCH=${ARCH/x86_64/amd64}
ARCH=${ARCH/aarch64/arm64}
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$ARCH"
sudo chmod u+x /usr/local/bin/wings

# Create systemd service
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

sudo systemctl enable --now wings

# -------------------- Firewall --------------------
echo "[4/7] Installing and configuring firewalld..."
sudo apt update
sudo apt install -y firewalld
sudo ufw disable || true
sudo systemctl stop ufw || true
sudo systemctl disable ufw || true
sudo systemctl enable --now firewalld

# TCP ports
for port in 2022 5657 56423 8080 25565-25800 50000-50500 19132; do
    sudo firewall-cmd --permanent --add-port=$port/tcp
done
# UDP ports
for port in 8080 25565-25800 50000-50500 19132; do
    sudo firewall-cmd --permanent --add-port=$port/udp
done
sudo firewall-cmd --reload

echo "✅ Firewalld setup complete!"
echo "Allowed TCP: 2022, 5657, 56423, 8080, 25565-25800, 19132, 50000-50500"
echo "Allowed UDP: 8080, 25565-25800, 19132, 50000-50500"

# -------------------- Cloudflare --------------------
echo "[5/7] Creating Cloudflare DNS records..."
NEXT_NODE=1
while true; do
    NODE_CHECK=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=node-$NEXT_NODE.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | grep "$SERVER_IP" || true)
    if [[ -z "$NODE_CHECK" ]]; then
        break
    else
        NEXT_NODE=$((NEXT_NODE+1))
    fi
done

CF_NODE_NAME="node-$NEXT_NODE.$CF_DOMAIN"
CF_GAME_NAME="game-$NEXT_NODE.$CF_DOMAIN"

# Node record
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
     -H "Authorization: Bearer $CF_API" \
     -H "Content-Type: application/json" \
     --data '{"type":"A","name":"'"$CF_NODE_NAME"'","content":"'"$SERVER_IP"'","ttl":120,"comment":"'"$NODE_NAME"'"}'

# Game record
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
     -H "Authorization: Bearer $CF_API" \
     -H "Content-Type: application/json" \
     --data '{"type":"A","name":"'"$CF_GAME_NAME"'","content":"'"$SERVER_IP"'","ttl":120,"comment":"'"$NODE_NAME"' game ip"}'

echo "✅ DNS record created: $CF_NODE_NAME"
echo "✅ DNS record created: $CF_GAME_NAME"

# -------------------- SSL --------------------
echo "[6/7] Installing SSL..."
sudo apt install -y certbot python3-certbot-nginx
if ! command -v nginx &> /dev/null; then
    sudo apt install -y nginx
fi
sudo systemctl enable --now nginx
sudo certbot certonly --nginx -d "$CF_NODE_NAME"
(crontab -l 2>/dev/null; echo "0 23 * * * certbot renew --quiet --deploy-hook 'systemctl restart nginx'") | crontab -

# -------------------- Final Summary --------------------
ALLOC_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_RAM_MB=$ALLOC_RAM_MB
ALLOC_DISK_MB=$(df --output=avail / | tail -1)
TOTAL_DISK_MB=$(df --output=size / | tail -1)

LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | jq -r '.city + ", " + .country')

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

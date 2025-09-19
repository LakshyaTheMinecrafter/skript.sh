#!/bin/bash
set -e

# --------------------------
# Parse arguments
# --------------------------
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --api) CF_API="$2"; shift ;;
        --zone) CF_ZONE="$2"; shift ;;
        --domain) CF_DOMAIN="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Prompt if not passed
[ -z "$CF_API" ] && read -rp "Enter Cloudflare API token: " CF_API
[ -z "$CF_ZONE" ] && read -rp "Enter Cloudflare Zone ID: " CF_ZONE
[ -z "$CF_DOMAIN" ] && read -rp "Enter your domain: " CF_DOMAIN

# --------------------------
# Step 1: Install Docker
# --------------------------
echo "[1/6] Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
sudo systemctl enable --now docker

# --------------------------
# Step 2: Enable swap accounting
# --------------------------
echo "[2/6] Enabling swap accounting..."
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 swapaccount=1"/' /etc/default/grub || true
sudo update-grub || true

# --------------------------
# Step 3: Install Wings
# --------------------------
echo "[3/6] Installing Wings..."
sudo mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
sudo chmod u+x /usr/local/bin/wings

# Create systemd service
sudo tee /etc/systemd/system/wings.service > /dev/null <<'EOF'
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

# --------------------------
# Step 4: Setup Firewall
# --------------------------
echo "[4/6] Setting up firewalld..."
sudo apt update -y
sudo apt install -y firewalld
sudo ufw disable || true
sudo systemctl stop ufw || true
sudo systemctl disable ufw || true
sudo systemctl enable --now firewalld

# TCP ports
for p in 2022 5657 56423 8080 25565-25800 50000-50500 19132; do
    sudo firewall-cmd --permanent --add-port=$p/tcp
done
# UDP ports
for p in 8080 25565-25800 50000-50500 19132; do
    sudo firewall-cmd --permanent --add-port=$p/udp
done
sudo firewall-cmd --reload
echo "✅ Firewalld setup complete!"

# --------------------------
# Step 5: Cloudflare DNS
# --------------------------
echo "[5/6] Configuring Cloudflare DNS..."
read -rp "Enter Wings node name (used as comment): " NODE_NAME

# Determine node number
N=1
while curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?name=node-$N.$CF_DOMAIN" \
  -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | grep -q "\"result\":\[\]"; do
  break
done
NODE_NUM=$N
CF_NODE_NAME="node-$NODE_NUM.$CF_DOMAIN"
CF_GAME_NAME="game-$NODE_NUM.$CF_DOMAIN"

# Create DNS records
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
-H "Authorization: Bearer $CF_API" \
-H "Content-Type: application/json" \
--data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$(curl -s https://ipinfo.io/ip)\",\"ttl\":120,\"proxied\":false}" >/dev/null

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
-H "Authorization: Bearer $CF_API" \
-H "Content-Type: application/json" \
--data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$(curl -s https://ipinfo.io/ip)\",\"ttl\":120,\"proxied\":false}" >/dev/null

# --------------------------
# Step 6: SSL Certificate
# --------------------------
echo "[6/6] Installing SSL for $CF_NODE_NAME..."
sudo apt update
sudo apt install -y certbot
sudo certbot certonly --nginx -d "$CF_NODE_NAME" --non-interactive --agree-tos -m "admin@$CF_DOMAIN"
# Setup renewal cron
sudo bash -c "echo '0 23 * * * certbot renew --quiet --deploy-hook \"systemctl restart nginx\"' >> /etc/crontab"

# --------------------------
# Final Summary
# --------------------------
SERVER_IP=$(curl -s https://ipinfo.io/ip)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 1024))
TOTAL_DISK_MB=$(df -m / | awk 'NR==2{print $2}')
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 5000))
LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | jq -r '.city + ", " + .country')

echo
echo "=============================================="
echo "✅ Wings Node Setup Complete!"
echo "Details for adding this node in the Pterodactyl Panel:"
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

#!/bin/bash
set -e

# --------------------------
# Parse arguments
# --------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --api) CF_API="$2"; shift 2;;
        --zone) CF_ZONE="$2"; shift 2;;
        --domain) CF_DOMAIN="$2"; shift 2;;
        *) echo "Unknown argument: $1"; exit 1;;
    esac
done

# Ask for Wings node name (used in comments)
read -rp "Enter a name for this Wings node (used for comments): " NODE_NAME

# --------------------------
# Step 1: Install Docker if missing
# --------------------------
echo "[1/6] Checking Docker installation..."
if command -v docker >/dev/null 2>&1; then
    echo "Docker is already installed, skipping installation."
else
    echo "Docker not found. Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    sudo systemctl enable --now docker
fi

# --------------------------
# Step 2: Enable swap accounting if GRUB exists
# --------------------------
echo "[2/6] Enabling swap accounting..."
if [[ -f /etc/default/grub ]]; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 /' /etc/default/grub
    sudo update-grub
    echo "Swap accounting enabled."
else
    echo "No GRUB found, skipping swapaccount step."
fi

# --------------------------
# Step 3: Install Wings
# --------------------------
echo "[3/6] Installing Pterodactyl Wings..."
sudo mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
sudo chmod u+x /usr/local/bin/wings

# Create systemd service for Wings
sudo tee /etc/systemd/system/wings.service > /dev/null <<EOL
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

# --------------------------
# Step 4: Firewalld setup
# --------------------------
echo "[4/6] Installing and configuring firewalld..."
sudo apt update -y
sudo apt install -y firewalld
sudo systemctl enable --now firewalld

# TCP ports
for port in 2022 5657 56423 8080 25565-25800 50000-50500 19132; do
    sudo firewall-cmd --permanent --add-port=${port}/tcp
done

# UDP ports
for port in 8080 25565-25800 50000-50500 19132; do
    sudo firewall-cmd --permanent --add-port=${port}/udp
done

sudo firewall-cmd --reload
echo "✅ Firewalld setup complete!"
echo "Open Ports:"
echo "  TCP: 2022, 5657, 56423, 8080, 25565-25800, 19132, 50000-50500"
echo "  UDP: 8080, 25565-25800, 19132, 50000-50500"

# --------------------------
# Step 5: Cloudflare DNS
# --------------------------
echo "[5/6] Creating Cloudflare DNS records..."
SERVER_IP=$(curl -s ipinfo.io/ip)

# Find first available node number
NUM=1
while true; do
    node_check=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records?name=node-${NUM}.${CF_DOMAIN}" \
        -H "Authorization: Bearer ${CF_API}" \
        -H "Content-Type: application/json" | jq '.result | length')
    if [[ $node_check -eq 0 ]]; then
        break
    fi
    NUM=$((NUM+1))
done

CF_NODE_NAME="node-${NUM}.${CF_DOMAIN}"
CF_GAME_NAME="game-${NUM}.${CF_DOMAIN}"

# Create DNS records
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records" \
    -H "Authorization: Bearer ${CF_API}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":true,\"comment\":\"$NODE_NAME\"}"

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records" \
    -H "Authorization: Bearer ${CF_API}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":true,\"comment\":\"$NODE_NAME\"}"

# --------------------------
# Step 6: Final summary
# --------------------------
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 500))
TOTAL_DISK_MB=$(df -m / | awk 'NR==2 {print $2}')
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 5000))
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

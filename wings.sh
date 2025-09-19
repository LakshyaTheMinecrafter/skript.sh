#!/bin/bash

set -e

# ---------------- Cloudflare args ----------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --api) CF_API="$2"; shift 2 ;;
    --zone) CF_ZONE="$2"; shift 2 ;;
    --domain) CF_DOMAIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Ask for Cloudflare info if not passed
if [[ -z "$CF_API" ]]; then
    read -p "Enter your Cloudflare API Token: " CF_API
fi
if [[ -z "$CF_ZONE" ]]; then
    read -p "Enter your Cloudflare Zone ID: " CF_ZONE
fi
if [[ -z "$CF_DOMAIN" ]]; then
    read -p "Enter your Cloudflare Domain: " CF_DOMAIN
fi

# Ask for Wings node name (used in DNS comment)
read -p "Enter a name for this Wings node (used in DNS comments): " NODE_NAME

# ---------------- Docker ----------------
if command -v docker &> /dev/null; then
    echo "[1/7] Docker is already installed, skipping installation..."
else
    echo "[1/7] Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    sudo systemctl enable --now docker
fi

# ---------------- GRUB swap ----------------
echo "[2/7] Enabling swap accounting..."
if [[ -f /etc/default/grub ]]; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 /' /etc/default/grub
    sudo update-grub
else
    echo "No /etc/default/grub found, skipping swapaccount"
fi

# ---------------- Wings ----------------
echo "[3/7] Installing Pterodactyl Wings..."
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

# ---------------- Firewalld ----------------
echo "[4/7] Setting up firewalld..."
sudo apt update -y
sudo apt install -y firewalld
sudo systemctl stop ufw || true
sudo systemctl disable ufw || true
sudo systemctl enable --now firewalld

# External interface name - change if needed
EXT_IFACE="ens18"

# Assign external interface to public zone if not already assigned
EXT_ZONE=$(firewall-cmd --get-zone-of-interface=$EXT_IFACE 2>/dev/null || echo "")
if [[ -z "$EXT_ZONE" ]]; then
  echo "[4/7] Assigning external interface $EXT_IFACE to public zone..."
  sudo firewall-cmd --zone=public --add-interface=$EXT_IFACE --permanent
else
  echo "[4/7] External interface $EXT_IFACE is already in zone: $EXT_ZONE"
fi

# Ports to allow in Docker zone (docker0 and pterodactyl0 bridges are automatically managed by Docker in the 'docker' zone)
DOCKER_TCP_PORTS="2022 5657 56423 8080 25565-25800 19132 50000-50500"
DOCKER_UDP_PORTS="8080 25565-25800 19132 50000-50500"

# Ports to allow on external interface (public zone)
EXTERNAL_TCP_PORTS="2022 5657 56423 8080 25565-25800 19132 50000-50500"
EXTERNAL_UDP_PORTS="8080 25565-25800 19132 50000-50500"

echo "[4/7] Opening ports in docker zone..."
for port in $DOCKER_TCP_PORTS; do
  sudo firewall-cmd --zone=docker --add-port=${port}/tcp --permanent
done
for port in $DOCKER_UDP_PORTS; do
  sudo firewall-cmd --zone=docker --add-port=${port}/udp --permanent
done

echo "[4/7] Opening ports in public zone (external interface $EXT_IFACE)..."
for port in $EXTERNAL_TCP_PORTS; do
  sudo firewall-cmd --zone=public --add-port=${port}/tcp --permanent
done
for port in $EXTERNAL_UDP_PORTS; do
  sudo firewall-cmd --zone=public --add-port=${port}/udp --permanent
done

# Reload firewall to apply changes
sudo firewall-cmd --reload

echo "✅ Firewalld setup complete!"
echo "Allowed TCP ports on docker zone: $DOCKER_TCP_PORTS"
echo "Allowed UDP ports on docker zone: $DOCKER_UDP_PORTS"
echo "Allowed TCP ports on public zone: $EXTERNAL_TCP_PORTS"
echo "Allowed UDP ports on public zone: $EXTERNAL_UDP_PORTS"
echo "External interface $EXT_IFACE assigned to zone: $(firewall-cmd --get-zone-of-interface=$EXT_IFACE)"


# ---------------- Cloudflare DNS ----------------
echo "[5/7] Creating Cloudflare DNS records..."
SERVER_IP=$(curl -s https://ipinfo.io/ip)

NEXT_NODE=1
while true; do
    NODE_CHECK=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=node-$NEXT_NODE.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API" \
        -H "Content-Type: application/json")
    
    if ! echo "$NODE_CHECK" | grep -q '"id":'; then
        break
    else
        NEXT_NODE=$((NEXT_NODE+1))
    fi
done

CF_NODE_NAME="node-$NEXT_NODE.$CF_DOMAIN"
CF_GAME_NAME="game-$NEXT_NODE.$CF_DOMAIN"

create_dns() {
    local NAME="$1"
    local COMMENT="$2"
    
    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
        -H "Authorization: Bearer $CF_API" \
        -H "Content-Type: application/json" \
        --data '{"type":"A","name":"'"$NAME"'","content":"'"$SERVER_IP"'","ttl":120,"comment":"'"$COMMENT"'"}')
    
    if echo "$RESPONSE" | grep -q '"success":true'; then
        echo "✅ DNS record created: $NAME"
    else
        echo "⚠️ DNS record NOT created: $NAME"
        echo "Response: $RESPONSE"
    fi
}

create_dns "$CF_NODE_NAME" "$NODE_NAME"
create_dns "$CF_GAME_NAME" "$NODE_NAME game ip"

# ---------------- SSL ----------------
echo "[6/7] Installing SSL..."
sudo apt install -y certbot
certbot certonly --standalone -d "$CF_NODE_NAME"

# Add cron for renewal
(crontab -l 2>/dev/null; echo "0 23 * * * certbot renew --quiet --deploy-hook 'systemctl restart nginx'") | crontab -

# ---------------- Final Summary ----------------
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
ALLOC_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
TOTAL_RAM_MB=$ALLOC_RAM_MB
ALLOC_DISK_MB=$(df --output=avail -m / | tail -1)
TOTAL_DISK_MB=$(df --output=size -m / | tail -1)
echo "  RAM (alloc) : ${ALLOC_RAM_MB} MB (from total ${TOTAL_RAM_MB} MB)"
echo "  Disk (alloc): ${ALLOC_DISK_MB} MB (from total ${TOTAL_DISK_MB} MB)"

LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | awk -F'"' '/"city"/{city=$4} /"country"/{country=$4} END{print city ", " country}')
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

#!/bin/bash
set -e
# ---------------- Cloudflare args ----------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --api) CF_API="$2"; shift 2 ;;
    --zone) CF_ZONE="$2"; shift 2 ;;
    --domain) CF_DOMAIN="$2"; shift 2 ;;
    --email) CF_EMAIL="$2"; shift 2 ;;
    --key) CF_KEY="$2"; shift 2 ;;
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
if [[ -z "$CF_EMAIL" ]]; then
    read -p "Enter your Cloudflare Email: " CF_EMAIL
fi
if [[ -z "$CF_KEY" ]]; then
    read -p "Enter your Cloudflare Global API Key: " CF_KEY
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
echo "Allowed TCP: 2022, 5657, 56423, 8080, 25565-25800, 19132, 50000-50500"
echo "Allowed UDP: 8080, 25565-25800, 19132, 50000-50500"

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

# ---------------- SSL using Cloudflare Global API Key ----------------
echo "[6/7] Installing and issuing SSL certificate with acme.sh (CF_Key + CF_Email)..."

ACME_SH="/root/.acme.sh/acme.sh"

# Install acme.sh if not present
if [[ ! -f "$ACME_SH" ]]; then
    curl https://get.acme.sh | sh
fi

# Make sure we can run it
chmod +x "$ACME_SH"

# Switch CA to Let's Encrypt
"$ACME_SH" --set-default-ca --server letsencrypt

# Issue SSL certificate
"$ACME_SH" --issue --dns dns_cf -d "$CF_NODE_NAME" --server letsencrypt \
  --key-file /etc/letsencrypt/live/$CF_DOMAIN/privkey.pem \
  --fullchain-file /etc/letsencrypt/live/$CF_DOMAIN/fullchain.pem

# Install cert and reload Wings automatically
"$ACME_SH" --install-cert -d "$CF_NODE_NAME" \
  --key-file /etc/letsencrypt/live/$CF_DOMAIN/privkey.pem \
  --fullchain-file /etc/letsencrypt/live/$CF_DOMAIN/fullchain.pem \
  --reloadcmd "systemctl restart wings"

echo "✅ SSL certificate installed for $CF_NODE_NAME"

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

#!/bin/bash
set -e

# ==================== Arguments ====================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --api) CF_API="$2"; shift ;;
        --zone) CF_ZONE="$2"; shift ;;
        --domain) CF_DOMAIN="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$CF_API" || -z "$CF_ZONE" || -z "$CF_DOMAIN" ]]; then
    echo "Usage: $0 --api <cloudflare_api> --zone <zone_id> --domain <domain>"
    exit 1
fi

echo "[*] Starting Wings Node Setup..."

# ==================== System Update ====================
echo "[*] Updating system..."
apt update && apt upgrade -y

# ==================== Docker Installation ====================
echo "[*] Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# ==================== Swap Accounting ====================
echo "[*] Enabling swap accounting..."
if [[ -f /etc/default/grub ]]; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' /etc/default/grub
    update-grub
else
    echo "No GRUB found, skipping swapaccount step."
fi

# ==================== Wings Installation ====================
echo "[*] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

# ==================== Wings systemd ====================
echo "[*] Creating systemd service for Wings..."
cat > /etc/systemd/system/wings.service <<EOF
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

systemctl enable --now wings

# ==================== Firewalld Installation ====================
echo "[*] Installing firewalld..."
apt install -y firewalld jq
ufw disable || true
systemctl stop ufw || true
systemctl disable ufw || true
systemctl enable --now firewalld

# Configure required ports
for PORT in 2022 5657 56423 8080 25565-25800 50000-50500 19132; do
    firewall-cmd --permanent --add-port=$PORT/tcp || true
    firewall-cmd --permanent --add-port=$PORT/udp || true
done
firewall-cmd --reload

# ==================== Detect Public IP ====================
SERVER_IP=$(curl -s https://ipinfo.io/ip)

# ==================== Cloudflare DNS ====================
echo "[*] Creating/updating Cloudflare DNS records..."
read -p "Enter a name for this Wings node (used for DNS comments): " NODE_NAME

# Save env folder for later use if needed
mkdir -p ~/cloudflare_env
ENV_FILE=~/cloudflare_env/.env
echo "API=$CF_API" > "$ENV_FILE"
echo "ZONE=$CF_ZONE" >> "$ENV_FILE"
echo "DOMAIN=$CF_DOMAIN" >> "$ENV_FILE"

# Detect next free node number
NEXT_NODE=1
while true; do
    NODE_CHECK=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=node-$NEXT_NODE.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[] | select(.content=="'"$SERVER_IP"'") | .id')
    if [[ -z "$NODE_CHECK" ]]; then
        break
    else
        NEXT_NODE=$((NEXT_NODE+1))
    fi
done

CF_NODE_NAME="node-$NEXT_NODE.$CF_DOMAIN"
CF_GAME_NAME="game-$NEXT_NODE.$CF_DOMAIN"

# Create or update node A record
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
     -H "Authorization: Bearer $CF_API" \
     -H "Content-Type: application/json" \
     --data '{"type":"A","name":"'"$CF_NODE_NAME"'","content":"'"$SERVER_IP"'","ttl":120,"comment":"'"$NODE_NAME"'"}'

# Create or update game A record
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
     -H "Authorization: Bearer $CF_API" \
     -H "Content-Type: application/json" \
     --data '{"type":"A","name":"'"$CF_GAME_NAME"'","content":"'"$SERVER_IP"'","ttl":120,"comment":"'"$NODE_NAME"' game ip"}'

# ==================== System Resource Info ====================
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 2048))
TOTAL_DISK_MB=$(df --output=size -m / | tail -1)
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 51200))

# ==================== Final Summary ====================
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

# Fetch live location
LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | jq -r '.city + ", " + .country')
echo "  Location    : $LOCATION"

echo
echo "IP Aliases:"
echo "  Wings Node : $CF_NODE_NAME → $SERVER_IP"
echo "  Game Node  : $CF_GAME_NAME → $SERVER_IP"

echo
echo "Open Ports (firewalld):"
echo "  TCP: $(firewall-cmd --permanent --list-ports | tr ' ' ', ')"
echo "  UDP: $(firewall-cmd --permanent --list-ports | tr ' ' ', ')"

echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

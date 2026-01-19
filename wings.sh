#!/bin/bash
set -e

# ============================================================
#   __        ___                 
#   \ \      / (_)_ __   __ _ ___ 
#    \ \ /\ / /| | '_ \ / _` / __|
#     \ V  V / | | | | | (_| \__ \
#      \_/\_/  |_|_| |_|\__, |___/
#                       |___/     
#
#              Wings Installer
#              (By FlyingAura)
# ============================================================

# ============================================================
# Argument Parsing (Cloudflare & DNS)
# ============================================================
while [[ $# -gt 0 ]]; do
  case $1 in
    --api) CF_API="$2"; shift 2 ;;
    --zone) CF_ZONE="$2"; shift 2 ;;
    --domain) CF_DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --node_dns_name) NODE_DNS_NAME="$2"; shift 2 ;;
    --game_dns_name) GAME_DNS_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ============================================================
# Interactive Prompts (if args not provided)
# ============================================================
[[ -z "$CF_API" ]] && read -p "Enter your Cloudflare API Token: " CF_API
[[ -z "$CF_ZONE" ]] && read -p "Enter your Cloudflare Zone ID: " CF_ZONE
[[ -z "$CF_DOMAIN" ]] && read -p "Enter your Cloudflare Domain: " CF_DOMAIN
[[ -z "$EMAIL" ]] && read -p "Enter your Email: " EMAIL
[[ -z "$NODE_DNS_NAME" ]] && read -p "Enter Node DNS Name: " NODE_DNS_NAME
[[ -z "$GAME_DNS_NAME" ]] && read -p "Enter Game DNS Name: " GAME_DNS_NAME

# Used only for DNS comments
read -p "Enter a name for this Wings node (used in DNS comments): " NODE_NAME

# ============================================================
# Confirmation Summary (NO INSTALL YET)
# ============================================================
echo
echo "================ INSTALLATION SUMMARY ================"
echo " Cloudflare Zone ID : $CF_ZONE"
echo " Cloudflare Domain  : $CF_DOMAIN"
echo " Node DNS Base      : $NODE_DNS_NAME"
echo " Game DNS Base      : $GAME_DNS_NAME"
echo " Node Name          : $NODE_NAME"
echo " Email              : $EMAIL"
echo "======================================================"
echo
read -p "Proceed with installation? (y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Installation cancelled by user."
    exit 1
fi

echo "✅ Confirmation received. Starting installation..."
echo

# ============================================================
# [1/7] Docker Installation
# ============================================================
if command -v docker &> /dev/null; then
    echo "[1/7] Docker already installed — skipping."
else
    echo "[1/7] Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    sudo systemctl enable --now docker
fi

sudo systemctl restart docker
echo "✅ Docker restarted."

# ============================================================
# [2/7] Enable Swap Accounting (GRUB)
# ============================================================
echo "[2/7] Enabling swap accounting..."
if [[ -f /etc/default/grub ]]; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 /' /etc/default/grub
    sudo update-grub
else
    echo "⚠️ GRUB config not found — skipping."
fi

# ============================================================
# [3/7] Install Pterodactyl Wings
# ============================================================
echo "[3/7] Installing Pterodactyl Wings..."
sudo mkdir -p /etc/pterodactyl

curl -L -o /usr/local/bin/wings \
"https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$(
  [[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64"
)"

sudo chmod u+x /usr/local/bin/wings

# systemd service
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


# ============================================================
# [4/7] Firewall Configuration (UFW)
# ============================================================
echo "[4/7] Configuring UFW firewall..."

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2022/tcp
ufw allow 5657/tcp
ufw allow 56423/tcp
ufw allow 8080/tcp
ufw allow 25565:25599/tcp
ufw allow 19132:19199/tcp

ufw allow 2022/udp
ufw allow 25565:25599/udp
ufw allow 19132:19199/udp

ufw enable

ufw status verbose
echo "✅ Firewall configured."

# ============================================================
# [5/7] Cloudflare DNS Records
# ============================================================
echo "[5/7] Creating Cloudflare DNS records..."

SERVER_IP=$(curl -s https://ipinfo.io/ip)
NEXT_NODE=1

while true; do
    CHECK=$(curl -s -X GET \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=$GAME_DNS_NAME$NEXT_NODE.$CF_DOMAIN" \
      -H "Authorization: Bearer $CF_API" \
      -H "Content-Type: application/json")

    echo "$CHECK" | grep -q '"id":' && NEXT_NODE=$((NEXT_NODE+1)) || break
done

CF_NODE_NAME="$NODE_DNS_NAME$NEXT_NODE.$CF_DOMAIN"
CF_GAME_NAME="$GAME_DNS_NAME$NEXT_NODE.$CF_DOMAIN"

create_dns() {
    local NAME="$1"
    local COMMENT="$2"

    RESPONSE=$(curl -s -X POST \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
      -H "Authorization: Bearer $CF_API" \
      -H "Content-Type: application/json" \
      --data '{"type":"A","name":"'"$NAME"'","content":"'"$SERVER_IP"'","ttl":120,"comment":"'"$COMMENT"'"}')

    echo "$RESPONSE" | grep -q '"success":true' \
      && echo "✅ DNS created: $NAME" \
      || echo "⚠️ DNS failed: $NAME"
}

create_dns "$CF_NODE_NAME" "$NODE_NAME"
create_dns "$CF_GAME_NAME" "$NODE_NAME game ip"

# ============================================================
# [6/7] SSL Certificate (Certbot)
# ============================================================
echo "[6/7] Installing SSL certificate..."
sudo apt update
sudo apt install -y certbot
certbot certonly --standalone -d "$CF_NODE_NAME" --email "$EMAIL" --agree-tos --non-interactive
echo "✅ SSL installed."

# ============================================================
# [7/7] Final Summary
# ============================================================
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
ALLOC_RAM_MB=$(( TOTAL_RAM_MB * 90 / 100 ))

TOTAL_DISK_MB=$(df --output=size -m / | tail -1)
ALLOC_DISK_MB=$(( TOTAL_DISK_MB - 61440 ))
(( ALLOC_DISK_MB < 0 )) && ALLOC_DISK_MB=0

LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | awk -F'"' '/"city"/{c=$4} /"country"/{k=$4} END{print c ", " k}')

echo
echo "======================================================"
echo "✅ Wings Node Setup Complete"
echo " Node Name   : $NODE_NAME"
echo " Wings FQDN  : $CF_NODE_NAME"
echo " Game FQDN   : $CF_GAME_NAME"
echo " Public IP   : $SERVER_IP"
echo " RAM (90%)   : ${ALLOC_RAM_MB} MB"
echo " Disk        : ${ALLOC_DISK_MB} MB"
echo " Location    : $LOCATION"
echo "======================================================"

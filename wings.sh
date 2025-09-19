#!/bin/bash
set -e

echo "[*] Starting Wings Node Setup..."

# ========= Parse Arguments ========= #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api)
      CF_API_KEY="$2"
      shift 2
      ;;
    --zone)
      CF_ZONE_ID="$2"
      shift 2
      ;;
    --domain)
      CF_DOMAIN="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ========= Check for required args ========= #
if [ -z "$CF_API_KEY" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_DOMAIN" ]; then
    echo "❌ Missing required arguments. Usage:"
    echo "bash <(curl -s https://raw.githubusercontent.com/LakshyaTheMinecrafter/skript.sh/main/wings.sh) --api <key> --zone <zoneid> --domain <domain>"
    exit 1
fi

# ========= Persist to .env ========= #
mkdir -p ~/cloudflare_env
ENV_FILE=~/cloudflare_env/.env

if [ ! -f "$ENV_FILE" ]; then
    echo "CF_API_KEY=$CF_API_KEY" > "$ENV_FILE"
    echo "CF_ZONE_ID=$CF_ZONE_ID" >> "$ENV_FILE"
    echo "CF_DOMAIN=$CF_DOMAIN" >> "$ENV_FILE"
    echo "DNS_CREATED=false" >> "$ENV_FILE"
else
    source "$ENV_FILE"
fi

# ========= Install Docker ========= #
apt update && apt upgrade -y
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# ========= Enable swap accounting if GRUB exists ========= #
if [ -f /etc/default/grub ]; then
    echo "[*] Enabling swap accounting..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' /etc/default/grub
    update-grub || true
else
    echo "No GRUB found, skipping swapaccount step."
fi

# ========= Install Wings ========= #
echo "[*] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

# ========= Create systemd service ========= #
echo "[*] Creating systemd service for Wings..."
cat > /etc/systemd/system/wings.service <<EOL
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

# ========= Firewall ========= #
echo "[*] Installing and configuring firewalld..."
apt install -y firewalld
systemctl enable --now firewalld
ufw disable || true
systemctl stop ufw || true
systemctl disable ufw || true

# TCP
firewall-cmd --permanent --add-port=2022/tcp
firewall-cmd --permanent --add-port=5657/tcp
firewall-cmd --permanent --add-port=56423/tcp
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=25565-25800/tcp
firewall-cmd --permanent --add-port=50000-50500/tcp
firewall-cmd --permanent --add-port=19132/tcp
# UDP
firewall-cmd --permanent --add-port=8080/udp
firewall-cmd --permanent --add-port=25565-25800/udp
firewall-cmd --permanent --add-port=50000-50500/udp
firewall-cmd --permanent --add-port=19132/udp
firewall-cmd --reload
echo "✅ Firewalld setup complete!"

# ========= Cloudflare DNS ========= #
if grep -q "DNS_CREATED=false" "$ENV_FILE"; then
    echo "[*] Setting up Cloudflare DNS records..."
    read -p "Enter a name for this Wings node (used for comments): " NODE_NAME

    LAST_NODE_NUM=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=node-*.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" | jq -r '.result[].name' | grep -o 'node-[0-9]*' | cut -d- -f2 | sort -n | tail -1)

    if [ -z "$LAST_NODE_NUM" ]; then
        NODE_NUM=1
    else
        NODE_NUM=$((LAST_NODE_NUM + 1))
    fi

    SERVER_IP=$(curl -s https://ipinfo.io/ip)
    CF_NODE_NAME="node-$NODE_NUM.$CF_DOMAIN"
    CF_GAME_NAME="game-$NODE_NUM.$CF_DOMAIN"

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":false,\"comment\":\"$NODE_NAME Wings IP\"}" >/dev/null

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":false,\"comment\":\"$NODE_NAME Game IP\"}" >/dev/null

    echo "DNS_CREATED=true" >> "$ENV_FILE"
    echo "✅ DNS records created:"
    echo " - $CF_NODE_NAME"
    echo " - $CF_GAME_NAME"
else
    echo "✅ DNS already created, skipping..."
fi

# ========= Resource Info ========= #
TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 2048))
TOTAL_DISK_MB=$(df --output=size -m / | tail -1)
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 51200))
SERVER_IP=$(curl -s https://ipinfo.io/ip)

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
echo
echo "IP Aliases:"
echo "  Wings Node : $CF_NODE_NAME → $SERVER_IP"
echo "  Game Node  : $CF_GAME_NAME → $SERVER_IP"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

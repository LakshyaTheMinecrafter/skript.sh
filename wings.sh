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

# ========= Persist to .env ========= #
mkdir -p ~/cloudflare_env
ENV_FILE=~/cloudflare_env/.env

if [ ! -f "$ENV_FILE" ]; then
    echo "CF_API_KEY=$CF_API_KEY" > "$ENV_FILE"
    echo "CF_ZONE_ID=$CF_ZONE_ID" >> "$ENV_FILE"
    echo "CF_DOMAIN=$CF_DOMAIN" >> "$ENV_FILE"
    echo "DNS_CREATED=false" >> "$ENV_FILE"
else
    # Load values
    source "$ENV_FILE"

    # Override with args if provided
    [ -n "$CF_API_KEY" ] && sed -i "s/^CF_API_KEY=.*/CF_API_KEY=$CF_API_KEY/" "$ENV_FILE"
    [ -n "$CF_ZONE_ID" ] && sed -i "s/^CF_ZONE_ID=.*/CF_ZONE_ID=$CF_ZONE_ID/" "$ENV_FILE"
    [ -n "$CF_DOMAIN" ] && sed -i "s/^CF_DOMAIN=.*/CF_DOMAIN=$CF_DOMAIN/" "$ENV_FILE"

    source "$ENV_FILE"
fi

# Validate
if [ -z "$CF_API_KEY" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_DOMAIN" ]; then
    echo "❌ Missing Cloudflare credentials! Provide via args:"
    echo "bash <(curl -s https://.../wings.sh) --api <key> --zone <zoneid> --domain <domain>"
    exit 1
fi

# ========= System Setup ========= #
echo
echo "[*] Updating system..."
apt update && apt upgrade -y

echo "[*] Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

echo "[*] Enabling swap accounting..."
if [ -f /etc/default/grub ]; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' /etc/default/grub
    update-grub || true
else
    echo "No GRUB found, skipping swapaccount step."
fi

echo "[*] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings \
"https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

echo "[*] Creating systemd service for Wings..."
cat >/etc/systemd/system/wings.service <<EOF
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

# ========= Firewall ========= #
echo "[*] Installing firewalld..."
apt install -y firewalld
systemctl enable --now firewalld
ufw disable || true
systemctl stop ufw || true
systemctl disable ufw || true

echo "[*] Configuring firewall rules..."
for PORT in 2022/tcp 5657/tcp 56423/tcp 8080/tcp 25565-25800/tcp 50000-50500/tcp 19132/tcp 8080/udp 25565-25800/udp 50000-50500/udp 19132/udp; do
    firewall-cmd --permanent --add-port=$PORT || true
done
firewall-cmd --reload

# ========= DNS Creation ========= #
if grep -q "DNS_CREATED=true" "$ENV_FILE"; then
    echo "✅ DNS already created, skipping..."
else
    echo "[*] Creating Cloudflare DNS records..."
    SERVER_IP=$(curl -s http://ipv4.icanhazip.com)

    # Find next available node number
    NUM=1
    while curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=node-$NUM.$CF_DOMAIN" \
      -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" | grep -q '"count":1'; do
        NUM=$((NUM + 1))
    done

    CF_NODE_NAME="node-$NUM.$CF_DOMAIN"
    CF_GAME_NAME="game-$NUM.$CF_DOMAIN"

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"Wings node\"}" >/dev/null

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"Game IP\"}" >/dev/null

    sed -i "s/^DNS_CREATED=false/DNS_CREATED=true/" "$ENV_FILE"
    echo "CF_NODE_NAME=$CF_NODE_NAME" >> "$ENV_FILE"
    echo "CF_GAME_NAME=$CF_GAME_NAME" >> "$ENV_FILE"
fi

# ========= Final Summary ========= #
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 2048))
TOTAL_DISK_MB=$(df --output=size -m / | tail -1)
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 51200))
SERVER_IP=$(curl -s http://ipv4.icanhazip.com)

source "$ENV_FILE"

echo
echo "=============================================="
echo "✅ Wings Node Setup Complete!"
echo "Details for adding this node in the Pterodactyl Panel:"
echo
echo "  Wings FQDN  : ${CF_NODE_NAME:-not set}"
echo "  Game FQDN   : ${CF_GAME_NAME:-not set}"
echo "  Public IP   : $SERVER_IP"
echo "  Wings Port  : 8080 (default)"
echo "  RAM (alloc) : ${ALLOC_RAM_MB} MB (from total ${TOTAL_RAM_MB} MB)"
echo "  Disk (alloc): ${ALLOC_DISK_MB} MB (from total ${TOTAL_DISK_MB} MB)"
echo
echo "IP Aliases:"
echo "  Wings Node : ${CF_NODE_NAME:-not set} → $SERVER_IP"
echo "  Game Node  : ${CF_GAME_NAME:-not set} → $SERVER_IP"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

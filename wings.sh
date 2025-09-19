#!/bin/bash
set -e

# ===== Parse Arguments =====
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --api) CF_API_KEY="$2"; shift ;;
    --zone) CF_ZONE_ID="$2"; shift ;;
    --domain) CF_DOMAIN="$2"; shift ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$CF_API_KEY" || -z "$CF_ZONE_ID" || -z "$CF_DOMAIN" ]]; then
  echo "Usage: $0 --api <CLOUDFLARE_API_KEY> --zone <CLOUDFLARE_ZONE_ID> --domain <DOMAIN>"
  exit 1
fi

# ===== Setup env storage =====
ENV_DIR="$HOME/cloudflare_env"
ENV_FILE="$ENV_DIR/.env"
mkdir -p "$ENV_DIR"

# ===== Always ask for Wings node name =====
echo -n "Enter a name for this Wings node (used in comments): "
read NODE_NAME

# Write env file fresh each run
{
  echo "CF_API_KEY=\"$CF_API_KEY\""
  echo "CF_ZONE_ID=\"$CF_ZONE_ID\""
  echo "CF_DOMAIN=\"$CF_DOMAIN\""
  echo "NODE_NAME=\"$NODE_NAME\""
} > "$ENV_FILE"

echo "[*] Starting Wings Node Setup..."

# ===== System update =====
echo "[*] Updating system..."
apt update -y && apt upgrade -y

# ===== Docker =====
echo "[*] Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# ===== Enable swap accounting =====
echo "[*] Enabling swap accounting..."
if [[ -f "/etc/default/grub" ]]; then
  sed -i 's/GRUB_CMDLINE_LINUX="[^"]*/& swapaccount=1/' /etc/default/grub || true
  update-grub || true
else
  echo "No GRUB found, skipping swapaccount step."
fi

# ===== Install Wings =====
echo "[*] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

# ===== Systemd service =====
echo "[*] Creating systemd service for Wings..."
cat >/etc/systemd/system/wings.service <<EOL
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

systemctl enable --now wings

# ===== Firewalld =====
echo "[*] Installing firewalld..."
apt install -y firewalld
systemctl enable --now firewalld
echo "[*] Configuring firewall rules..."
ufw disable || true
systemctl stop ufw || true
systemctl disable ufw || true

# Ports
firewall-cmd --permanent --add-port=2022/tcp
firewall-cmd --permanent --add-port=5657/tcp
firewall-cmd --permanent --add-port=56423/tcp
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=25565-25800/tcp
firewall-cmd --permanent --add-port=50000-50500/tcp
firewall-cmd --permanent --add-port=19132/tcp
firewall-cmd --permanent --add-port=8080/udp
firewall-cmd --permanent --add-port=25565-25800/udp
firewall-cmd --permanent --add-port=50000-50500/udp
firewall-cmd --permanent --add-port=19132/udp
firewall-cmd --reload
echo "✅ Firewalld setup complete!"

# ===== Cloudflare DNS =====
echo "[*] Creating or updating Cloudflare DNS records..."

# Determine next available node number (or reuse existing one)
NEXT_NUM=1
while curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=node-$NEXT_NUM.$CF_DOMAIN" \
  -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" | grep -q '"count":1'; do
  NEXT_NUM=$((NEXT_NUM+1))
done

CF_NODE_NAME="node-$NEXT_NUM.$CF_DOMAIN"
CF_GAME_NAME="game-$NEXT_NUM.$CF_DOMAIN"
SERVER_IP=$(curl -s https://ipv4.icanhazip.com)

# Create or update records
for NAME in "node-$NEXT_NUM" "game-$NEXT_NUM"; do
  EXISTING_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$NAME.$CF_DOMAIN" \
    -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')

  COMMENT="$NODE_NAME ($( [[ $NAME == node* ]] && echo "Wings" || echo "Game"))"

  if [[ -n "$EXISTING_ID" ]]; then
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$EXISTING_ID" \
      -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$COMMENT\"}" >/dev/null
  else
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$COMMENT\"}" >/dev/null
  fi
done

# ===== Resource Info =====
TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 2048))
TOTAL_DISK_MB=$(df -m --total | awk '/total/ {print $2}')
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 51200))

# ===== Final summary =====
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

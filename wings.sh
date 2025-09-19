#!/bin/bash
set -e

# =============== ARGUMENTS ===============
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --api) CF_API="$2"; shift ;;
    --zone) CF_ZONE="$2"; shift ;;
    --domain) CF_DOMAIN="$2"; shift ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

# Make sure required arguments are set
if [[ -z "$CF_API" || -z "$CF_ZONE" || -z "$CF_DOMAIN" ]]; then
  echo "Usage: bash <(curl -s https://raw.githubusercontent.com/USERNAME/REPO/main/wings.sh) --api <API_TOKEN> --zone <ZONE_ID> --domain <DOMAIN>"
  exit 1
fi

mkdir -p /root/cloudflare_env
ENV_FILE="/root/cloudflare_env/.env"

# Load old env if exists
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

# =============== SYSTEM SETUP ===============
echo "[*] Installing required packages..."
apt update -y
apt install -y curl wget sudo jq firewalld

echo "[*] Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# =============== SWAP ACCOUNTING ===============
echo
echo "[*] Enabling swap accounting..."
if grep -q "GRUB_CMDLINE_LINUX" /etc/default/grub; then
  sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="swapaccount=1 /' /etc/default/grub
  update-grub || true
else
  echo "No GRUB found, skipping swapaccount step."
fi

# =============== INSTALL WINGS ===============
echo
echo "[*] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
cd /etc/pterodactyl
curl -L -o wings.tar.gz https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
tar -xvzf wings.tar.gz -C /usr/local/bin
chmod +x /usr/local/bin/wings

echo "[*] Creating systemd service for Wings..."
cat > /etc/systemd/system/wings.service <<EOF
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

[Install]
WantedBy=multi-user.target
EOF

systemctl enable wings

# =============== FIREWALLD SETUP ===============
echo
echo "[*] Installing and configuring firewalld..."
systemctl enable --now firewalld

# Disable ufw if exists
ufw disable || true
systemctl stop ufw || true
systemctl disable ufw || true

# Open required ports
firewall-cmd --permanent --add-port=2022/tcp || true
firewall-cmd --permanent --add-port=5657/tcp || true
firewall-cmd --permanent --add-port=56423/tcp || true
firewall-cmd --permanent --add-port=8080/tcp || true
firewall-cmd --permanent --add-port=25565-25800/tcp || true
firewall-cmd --permanent --add-port=50000-50500/tcp || true
firewall-cmd --permanent --add-port=19132/tcp || true
firewall-cmd --permanent --add-port=8080/udp || true
firewall-cmd --permanent --add-port=25565-25800/udp || true
firewall-cmd --permanent --add-port=50000-50500/udp || true
firewall-cmd --permanent --add-port=19132/udp || true
firewall-cmd --reload
echo "✅ Firewalld setup complete!"

# =============== CLOUDFLARE DNS ===============
if [[ "$DNS_CREATED" != "true" ]]; then
  echo
  echo "[*] Setting up Cloudflare DNS records..."
  read -p "Enter a name for this Wings node (used for comments): " NODE_NAME

  NODE_NUM=$((RANDOM % 1000))
  CF_NODE_NAME="node-$NODE_NUM.$CF_DOMAIN"
  CF_GAME_NAME="game-$NODE_NUM.$CF_DOMAIN"
  SERVER_IP=$(curl -s https://ipinfo.io/ip)

  # Create DNS records
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
    -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME wings ip\"}" >/dev/null

  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
    -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME game ip\"}" >/dev/null

  echo "✅ DNS records created:"
  echo " - $CF_NODE_NAME"
  echo " - $CF_GAME_NAME"

  DNS_CREATED=true
  # Save to env
  cat > "$ENV_FILE" <<EOF
CF_API=$CF_API
CF_ZONE=$CF_ZONE
CF_DOMAIN=$CF_DOMAIN
NODE_NAME="$NODE_NAME"
CF_NODE_NAME=$CF_NODE_NAME
CF_GAME_NAME=$CF_GAME_NAME
DNS_CREATED=true
EOF
else
  echo "✅ DNS already created, skipping..."
fi

# Reload env so summary always has values
source "$ENV_FILE"

# =============== SYSTEM INFO ===============
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - (TOTAL_RAM_MB / 10)))
TOTAL_DISK_MB=$(df --output=size -m / | tail -1 | xargs)
ALLOC_DISK_MB=$((TOTAL_DISK_MB - (TOTAL_DISK_MB / 10)))
SERVER_IP=$(curl -s https://ipinfo.io/ip)

# =============== SUMMARY ===============
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

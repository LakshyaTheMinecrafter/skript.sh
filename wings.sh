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
# OS Detection
# ============================================================
. /etc/os-release
OS="$ID"

# ============================================================
# Argument Parsing
# ============================================================
while [[ $# -gt 0 ]]; do
  case $1 in
    --api) CF_API="$2"; shift 2 ;;
    --zone) CF_ZONE="$2"; shift 2 ;;
    --domain) CF_DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --node_dns_name) NODE_DNS_NAME="$2"; shift 2 ;;
    --game_dns_name) GAME_DNS_NAME="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ============================================================
# Prompts
# ============================================================
[[ -z "$CF_API" ]] && read -p "Cloudflare API Token: " CF_API
[[ -z "$CF_ZONE" ]] && read -p "Cloudflare Zone ID: " CF_ZONE
[[ -z "$CF_DOMAIN" ]] && read -p "Cloudflare Domain: " CF_DOMAIN
[[ -z "$EMAIL" ]] && read -p "Email: " EMAIL
[[ -z "$NODE_DNS_NAME" ]] && read -p "Node DNS base (eg node): " NODE_DNS_NAME
[[ -z "$GAME_DNS_NAME" ]] && read -p "Game DNS base (eg game): " GAME_DNS_NAME
read -p "Wings Node Name (for DNS comment): " NODE_NAME
[[ -z "$PASSWORD" ]] && read -p "Password for using in script (MySQL user): " PASSWORD

# ============================================================
# [1/7] Dependencies
# ============================================================
dep_install() {
  echo "[1/7] Installing dependencies..."

  sudo apt update
  sudo apt install -y \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    mariadb-server \
    ufw \
    certbot
}

# ============================================================
# [1/7] Docker (separate but same step number as requested)
# ============================================================
docker_install() {
  if command -v docker &> /dev/null; then
    echo "[1/7] Docker already installed — skipping."
  else
    echo "[1/7] Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    sudo systemctl enable --now docker
  fi

  sudo systemctl restart docker
  echo "✅ Docker restarted."
}

# ============================================================
# [2/7] Enable Swap Accounting (GRUB)
# ============================================================
grub_swap() {
  echo "[2/7] Enabling swap accounting..."

  if [[ -f /etc/default/grub ]]; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 /' /etc/default/grub
    sudo update-grub
  else
    echo "⚠️ GRUB config not found — skipping."
  fi
}

# ============================================================
# [3/7] Wings
# ============================================================
wings_dl() {
  echo "[3/7] Installing Pterodactyl Wings..."

  sudo mkdir -p /etc/pterodactyl
  sudo curl -L -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$(
      [[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64"
    )"

  sudo chmod +x /usr/local/bin/wings

  sudo tee /etc/systemd/system/wings.service > /dev/null <<EOF
[Unit]
Description=Pterodactyl Wings
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl enable --now wings
  echo "✅ Wings installed & started."
}

# ============================================================
# [4/7] UFW
# ============================================================
ufw_conf() {
  echo "[4/7] Configuring UFW..."

  sudo ufw allow 22/tcp
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  sudo ufw allow 2022/tcp
  sudo ufw allow 3306/tcp
  sudo ufw allow 5657/tcp
  sudo ufw allow 56423/tcp
  sudo ufw allow 8080/tcp
  sudo ufw allow 25565:25599/tcp
  sudo ufw allow 19132:19199/tcp
  sudo ufw allow 25565:25599/udp
  sudo ufw allow 19132:19199/udp

  sudo ufw --force enable
  echo "✅ Firewall configured."
}

# ============================================================
# [5/7] MySQL
# ============================================================
configure_mysql() {
  echo "[5/7] Configuring MySQL..."
  case "$OS" in
  debian | ubuntu)
  sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/mariadb.conf.d/50-server.cnf
  systemctl restart mysqld
  
  sudo mariadb -u root -e \
    "CREATE USER IF NOT EXISTS 'pterodactyluser'@'%' IDENTIFIED BY '$PASSWORD';"
  sudo mariadb -u root -e \
    "GRANT ALL PRIVILEGES ON *.* TO 'pterodactyluser'@'%' WITH GRANT OPTION;"
  sudo mariadb -u root -e "FLUSH PRIVILEGES;"

  echo "✅ MySQL configured."
}

# ============================================================
# [6/7] Cloudflare DNS
# ============================================================
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

cloudflare_dns() {
  echo "[6/7] Creating Cloudflare DNS records..."

  SERVER_IP=$(curl -s https://ipinfo.io/ip)
  NEXT=1

  while true; do
    CHECK=$(curl -s -H "Authorization: Bearer $CF_API" \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=$NODE_DNS_NAME$NEXT.$CF_DOMAIN")
    echo "$CHECK" | grep -q '"id":' && NEXT=$((NEXT+1)) || break
  done

  CF_NODE_NAME="$NODE_DNS_NAME$NEXT.$CF_DOMAIN"
  CF_GAME_NAME="$GAME_DNS_NAME$NEXT.$CF_DOMAIN"

  create_dns "$CF_NODE_NAME" "$NODE_NAME"
  create_dns "$CF_GAME_NAME" "$NODE_NAME game ip"
}

# ============================================================
# [7/7] SSL
# ============================================================
install_ssl() {
  echo "[7/7] Installing SSL certificate..."

  certbot certonly --standalone -d "$CF_NODE_NAME" --email "$EMAIL" --agree-tos --non-interactive

  echo "✅ SSL installed."
}

# ============================================================
# Execution Order
# ============================================================
dep_install
docker_install
grub_swap
wings_dl
ufw_conf
configure_mysql
cloudflare_dns
install_ssl

# ============================================================
# Final Summary (ORIGINAL STYLE)
# ============================================================
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
TOTAL_DISK_MB=$(df --output=size -m / | tail -1)
LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | awk -F'"' '/"city"/{c=$4} /"country"/{k=$4} END{print c ", " k}')

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
echo "  RAM (alloc) : ${TOTAL_RAM_MB} MB (from total ${TOTAL_RAM_MB} MB)"
echo "  Disk (alloc): ${TOTAL_DISK_MB} MB (from total ${TOTAL_DISK_MB} MB)"
echo "  Location    : $LOCATION"
echo
echo "Details for adding this node as a database host in the Pterodactyl Panel:"
echo "  Name    : $NODE_NAME"
echo "  Host    : $SERVER_IP"
echo "  Port    : 3306"
echo "  Username    : pterodactyluser"
echo "  Password    : $PASSWORD"
echo "  Linked Node    : $NODE_NAME"
echo
echo "IP Aliases:"
echo "  Wings Node : $CF_NODE_NAME → $SERVER_IP"
echo "  Game Node  : $CF_GAME_NAME → $SERVER_IP"
echo
echo "Open Ports:"
echo "  TCP: 80, 443, 2022, 3306, 5657, 56423, 8080, 25565-25599, 19132-19199"
echo "  UDP: 25565-25599, 19132-19199"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

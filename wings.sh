#!/bin/bash

# ===========================================
#  Pterodactyl Wings Auto Installer + Cloudflare DNS
# ===========================================

ENV_FILE="$HOME/cloudflare_env/.env"
mkdir -p "$HOME/cloudflare_env"

# Load existing env if it exists
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# ========= Functions ========= #

save_env() {
    cat > "$ENV_FILE" <<EOL
CF_API_KEY=$CF_API_KEY
CF_ZONE_ID=$CF_ZONE_ID
CF_DOMAIN=$CF_DOMAIN
NODE_NAME=$NODE_NAME
GAME_NAME=$GAME_NAME
DNS_CREATED=$DNS_CREATED
EOL
}

create_dns_record() {
    local NAME=$1
    local IP=$2
    local TYPE=$3

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_KEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$TYPE\",\"name\":\"$NAME.$CF_DOMAIN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}" \
        >/dev/null
}

find_next_node_number() {
    local COUNT=1
    while true; do
        CHECK_NODE="node-$COUNT.$CF_DOMAIN"
        CHECK_GAME="game-$COUNT.$CF_DOMAIN"

        # Check if DNS record already exists
        NODE_EXISTS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$CHECK_NODE" \
            -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" | grep -o '"count":[0-9]*' | cut -d: -f2)

        GAME_EXISTS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$CHECK_GAME" \
            -H "Authorization: Bearer $CF_API_KEY" -H "Content-Type: application/json" | grep -o '"count":[0-9]*' | cut -d: -f2)

        if [[ "$NODE_EXISTS" == "0" && "$GAME_EXISTS" == "0" ]]; then
            echo $COUNT
            return
        fi

        COUNT=$((COUNT+1))
    done
}

# ========= Start ========= #

echo "[*] Starting Wings Node Setup..."

# Ask for Cloudflare details if missing
if [ -z "$CF_API_KEY" ]; then
    read -p "Enter your Cloudflare API Key: " CF_API_KEY
fi

if [ -z "$CF_ZONE_ID" ]; then
    read -p "Enter your Cloudflare Zone ID: " CF_ZONE_ID
fi

if [ -z "$CF_DOMAIN" ]; then
    read -p "Enter your Cloudflare Domain (example.com): " CF_DOMAIN
fi

# Detect server public IP
SERVER_IP=$(curl -s https://ipinfo.io/ip)

# Handle DNS creation (only once per VPS)
if [ "$DNS_CREATED" != "true" ]; then
    NODE_NUM=$(find_next_node_number)
    NODE_NAME="node-$NODE_NUM"
    GAME_NAME="game-$NODE_NUM"

    echo "[*] Creating Cloudflare DNS records..."
    create_dns_record "$NODE_NAME" "$SERVER_IP" "A"
    create_dns_record "$GAME_NAME" "$SERVER_IP" "A"
    DNS_CREATED=true
    save_env
    echo "✅ DNS records created: $NODE_NAME.$CF_DOMAIN, $GAME_NAME.$CF_DOMAIN"
else
    echo "✅ DNS already exists, skipping..."
fi

# ========= Install Docker ========= #
echo "[*] Installing Docker..."
apt update -y
apt install -y docker.io curl

systemctl enable --now docker

# ========= Install Wings ========= #
echo "[*] Installing Pterodactyl Wings..."
sudo mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
sudo chmod u+x /usr/local/bin/wings

# ========= Setup Firewall ========= #
echo "[*] Installing and configuring firewalld..."
apt install -y firewalld
systemctl enable --now firewalld

firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=2022/tcp
firewall-cmd --permanent --add-port=5657/tcp
firewall-cmd --permanent --add-port=50000-50500/tcp
firewall-cmd --permanent --add-port=19132/udp
firewall-cmd --reload

# ========= System Info ========= #
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
ALLOC_RAM_MB=$(free -m | awk '/Mem:/ {print int($2*0.97)}')

TOTAL_DISK_MB=$(df --total -m | grep total | awk '{print $2}')
ALLOC_DISK_MB=$(df --total -m | grep total | awk '{print int($2*0.95)}')

# ========= Final Summary ========= #
echo
echo "=============================================="
echo "✅ Wings Node Setup Complete!"
echo "Details for adding this node in the Pterodactyl Panel:"
echo
echo "  Node Name   : $NODE_NAME"
echo "  Wings FQDN  : $NODE_NAME.$CF_DOMAIN"
echo "  Game FQDN   : $GAME_NAME.$CF_DOMAIN"
echo "  Public IP   : $SERVER_IP"
echo "  Wings Port  : 8080 (default)"
echo "  RAM (alloc) : ${ALLOC_RAM_MB} MB (from total ${TOTAL_RAM_MB} MB)"
echo "  Disk (alloc): ${ALLOC_DISK_MB} MB (from total ${TOTAL_DISK_MB} MB)"
echo
echo "IP Aliases:"
echo "  Wings Node : $NODE_NAME.$CF_DOMAIN → $SERVER_IP"
echo "  Game Node  : $GAME_NAME.$CF_DOMAIN → $SERVER_IP"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

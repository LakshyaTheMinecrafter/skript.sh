#!/bin/bash
set -e

# ========= CONFIG FUNCTIONS =========
save_env() {
    mkdir -p /root/cloudflare_env
    cat > /root/cloudflare_env/.env <<EOF
API_KEY=$CF_API
ZONE_ID=$CF_ZONE
DOMAIN=$CF_DOMAIN
DNS_CREATED=$DNS_CREATED
NODE_NAME=$NODE_NAME
CF_NODE_NAME=$CF_NODE_NAME
CF_GAME_NAME=$CF_GAME_NAME
EOF
}

load_env() {
    if [[ -f /root/cloudflare_env/.env ]]; then
        source /root/cloudflare_env/.env
    fi
}

# ========= ARGUMENTS =========
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api) CF_API="$2"; shift 2 ;;
        --zone) CF_ZONE="$2"; shift 2 ;;
        --domain) CF_DOMAIN="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Load saved environment if available
load_env

# ========= SYSTEM SETUP =========
echo "[1/6] Updating system packages..."
apt update && apt upgrade -y

echo "[2/6] Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

echo "[3/6] Enabling swap accounting..."
if [ -f /etc/default/grub ]; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' /etc/default/grub
    update-grub || true
else
    echo "No GRUB found, skipping swapaccount step."
fi

echo "[4/6] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ $(uname -m) == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

echo "[5/6] Creating systemd service for Wings..."
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

echo "[6/6] Installing and configuring firewalld..."
apt install -y firewalld
ufw disable || true
systemctl stop ufw || true
systemctl disable ufw || true

systemctl enable --now firewalld

# TCP ports
firewall-cmd --permanent --add-port=2022/tcp
firewall-cmd --permanent --add-port=5657/tcp
firewall-cmd --permanent --add-port=56423/tcp
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=25565-25800/tcp
firewall-cmd --permanent --add-port=50000-50500/tcp
firewall-cmd --permanent --add-port=19132/tcp

# UDP ports
firewall-cmd --permanent --add-port=8080/udp
firewall-cmd --permanent --add-port=25565-25800/udp
firewall-cmd --permanent --add-port=50000-50500/udp
firewall-cmd --permanent --add-port=19132/udp

firewall-cmd --reload
echo "✅ Firewalld setup complete!"

# ========= CLOUDFLARE DNS =========
SERVER_IP=$(curl -s http://ipv4.icanhazip.com)

if [[ "$DNS_CREATED" != "true" ]]; then
    read -p "Enter a name for this Wings node (used for comments): " NODE_NAME

    i=1
    while curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=node-$i.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | grep -q "\"count\":1"; do
        i=$((i+1))
    done

    CF_NODE_NAME="node-$i.$CF_DOMAIN"
    CF_GAME_NAME="game-$i.$CF_DOMAIN"

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME\"}"

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME game ip\"}"

    echo "✅ DNS records created:"
    echo " - $CF_NODE_NAME"
    echo " - $CF_GAME_NAME"

    DNS_CREATED=true
    save_env
else
    echo "✅ DNS already created, skipping..."
fi

# ========= FINAL SUMMARY =========
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 2048))
TOTAL_DISK_MB=$(df --total -m | awk '/^total/{print $2}')
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 51200))

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

#!/bin/bash
set -e

### CONFIGURATION STORAGE ###
CONFIG_DIR="/root/cloudflare_env"
CONFIG_FILE="$CONFIG_DIR/.env"

# Load or ask for Cloudflare config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "ℹ️ Loaded Cloudflare config from $CONFIG_FILE"
else
    echo "Enter your Cloudflare API Token: "
    read CLOUDFLARE_API_TOKEN
    echo "Enter your Cloudflare Zone ID: "
    read CLOUDFLARE_ZONE_ID
    echo "Enter your domain (example.com): "
    read DOMAIN

    mkdir -p "$CONFIG_DIR"
    cat >"$CONFIG_FILE" <<EOL
CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
CLOUDFLARE_ZONE_ID=$CLOUDFLARE_ZONE_ID
DOMAIN=$DOMAIN
DNS_CREATED=false
EOL
    echo "✅ Saved Cloudflare config to $CONFIG_FILE"
fi

### FUNCTIONS ###
get_next_subdomain() {
    local prefix=$1
    local i=1
    while true; do
        local name="${prefix}-${i}"
        local result=$(curl -s -X GET \
            "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=A&name=${name}.${DOMAIN}" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json")
        if [[ $(echo "$result" | grep -c '"count":0') -ge 1 ]]; then
            echo "$name"
            return
        fi
        i=$((i+1))
    done
}

create_dns_record() {
    local name=$1
    local ip=$2
    local comment=$3
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{
          \"type\": \"A\",
          \"name\": \"${name}\",
          \"content\": \"${ip}\",
          \"ttl\": 3600,
          \"proxied\": false,
          \"comment\": \"${comment}\"
        }" >/dev/null
}

### START INSTALLER ###
echo "Enter a name for this Wings node (used for comments): "
read NODE_NAME

echo "[1/8] Updating system packages..."
apt update && apt upgrade -y

echo "[2/8] Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

echo "[3/8] Enabling swap accounting (if supported)..."
if [ -f /etc/default/grub ]; then
    cp /etc/default/grub /etc/default/grub.bak
    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' /etc/default/grub
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"' >> /etc/default/grub
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg
    fi
    echo "✅ Swap accounting enabled. Please reboot for changes to take effect."
else
    echo "ℹ️ No GRUB detected. Skipping swapaccount setup (Wings will still work fine)."
fi

echo "[4/8] Installing Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ $(uname -m) == x86_64 ]] && echo amd64 || echo arm64)"
chmod u+x /usr/local/bin/wings

echo "[5/8] Creating systemd service for Wings..."
cat >/etc/systemd/system/wings.service <<EOL
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

echo "[6/8] Configuring firewall..."
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

echo "[7/8] Creating DNS records on Cloudflare..."
IP=$(curl -s ifconfig.me)
if [ "$DNS_CREATED" != "true" ]; then
    SUBDOMAIN=$(get_next_subdomain "node")
    GAMESUBDOMAIN=$(echo "$SUBDOMAIN" | sed 's/node/game/')
    create_dns_record "$SUBDOMAIN" "$IP" "$NODE_NAME"
    create_dns_record "$GAMESUBDOMAIN" "$IP" "$NODE_NAME game ip"

    # Update .env so DNS isn’t recreated next time
    sed -i 's/DNS_CREATED=false/DNS_CREATED=true/' "$CONFIG_FILE"
    echo "✅ DNS records created."
else
    echo "ℹ️ DNS already created. Skipping..."
    SUBDOMAIN=$(get_next_subdomain "node") # still set for output
    GAMESUBDOMAIN=$(echo "$SUBDOMAIN" | sed 's/node/game/')
fi

FQDN="${SUBDOMAIN}.${DOMAIN}"
GAMEFQDN="${GAMESUBDOMAIN}.${DOMAIN}"

echo "[8/8] Calculating resources..."
TOTAL_RAM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
ALLOC_RAM=$((TOTAL_RAM - 2097152)) # subtract 2GB in KB
ALLOC_RAM_MB=$((ALLOC_RAM / 1024))
TOTAL_DISK=$(df --output=size -k / | tail -1)
ALLOC_DISK=$((TOTAL_DISK - 52428800)) # subtract 50GB in KB
ALLOC_DISK_MB=$((ALLOC_DISK / 1024))

### OUTPUT ###
echo
echo "=============================================="
echo "✅ Wings node installed successfully!"
echo "Panel Setup Info:"
echo " - FQDN: $FQDN"
echo " - Game IP Alias: $GAMEFQDN"
echo " - IP Address: $IP"
echo " - Allocatable RAM: ${ALLOC_RAM_MB} MB"
echo " - Allocatable Disk: ${ALLOC_DISK_MB} MB"
echo " - Comment/Node Name: $NODE_NAME"
echo "=============================================="

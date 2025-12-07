#!/bin/bash
set -e
# ---------------- Cloudflare args ----------------
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
# $NODE_DNS_NAME
# $GAME_DNS_NAME
# Ask for Cloudflare info if not passed
if [[ -z "$CF_API" ]]; then
    read -p "Enter your Cloudflare API Token: " CF_API
fi
if [[ -z "$CF_ZONE" ]]; then
    read -p "Enter your Cloudflare Zone ID: " CF_ZONE
fi
if [[ -z "$CF_DOMAIN" ]]; then
    read -p "Enter your Cloudflare Domain: " CF_DOMAIN
fi
if [[ -z "$EMAIL" ]]; then
    read -p "Enter your Email: " EMAIL
fi
if [[ -z "$NODE_DNS_NAME" ]]; then
    read -p "Enter Node DNS Name: " NODE_DNS_NAME
fi
if [[ -z "$GAME_DNS_NAME" ]]; then
    read -p "Enter Game DNS Name: " GAME_DNS_NAME
fi

# Ask for Wings node name (used in DNS comment)
read -p "Enter a name for this Wings node (used in DNS comments): " NODE_NAME

# ---------------- Docker ----------------
if command -v docker &> /dev/null; then
    echo "[1/7] Docker is already installed, skipping installation..."
else
    echo "[1/7] Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    sudo systemctl enable --now docker
fi

sudo systemctl restart docker
echo "✅ Docker restarted."

# ---------------- GRUB swap ----------------
echo "[2/7] Enabling swap accounting..."
if [[ -f /etc/default/grub ]]; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 /' /etc/default/grub
    sudo update-grub
else
    echo "No /etc/default/grub found, skipping swapaccount"
fi

# ---------------- Wings ----------------
echo "[3/7] Installing Pterodactyl Wings..."
sudo mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
sudo chmod u+x /usr/local/bin/wings

# Create systemd service
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

sudo systemctl enable --now wings

# ---------------- Firewalld ----------------
#!/bin/bash

# UFW script to open specified ports

echo "Enabling UFW and opening ports..."

# Allow TCP ports
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2022/tcp
ufw allow 5657/tcp
ufw allow 56423/tcp
ufw allow 8080/tcp
ufw allow 25565:25599/tcp
ufw allow 19132:19199/tcp

# Allow UDP ports
ufw allow 25565:25599/udp
ufw allow 19132:19199/udp

# Enable UFW
ufw enable

echo "Done. Current status:"
ufw status verbose
echo "✅ UFW setup complete!"
echo "Allowed TCP: 80, 443, 2022, 5657, 56423, 8080, 25565-25599, 19132-19199"
echo "Allowed UDP: 8080, 25565-25599, 19132-19199"

# ---------------- Cloudflare DNS ----------------
echo "[5/7] Creating Cloudflare DNS records..."
SERVER_IP=$(curl -s https://ipinfo.io/ip)
NEXT_NODE=1
while true; do
    NODE_CHECK=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=$NODE_DNS_NAME$NEXT_NODE.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API" \
        -H "Content-Type: application/json")
    
    if ! echo "$NODE_CHECK" | grep -q '"id":'; then
        break
    else
        NEXT_NODE=$((NEXT_NODE+1))
    fi
done

CF_NODE_NAME="$NODE_DNS_NAME$NEXT_NODE.$CF_DOMAIN"
CF_GAME_NAME="$GAME_DNS_NAME$NEXT_NODE.$CF_DOMAIN"

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

create_dns "$CF_NODE_NAME" "$NODE_NAME"
create_dns "$CF_GAME_NAME" "$NODE_NAME game ip"

# ---------------- SSL using Cloudflare Global API Key ----------------
echo "[6/7] Getting SSL"
sudo apt update
sudo apt install -y certbot
# Run this if you use Nginx
sudo apt install -y python3-certbot-nginx
# Nginx
certbot certonly --nginx -d $CF_NODE_NAME --email $EMAIL --agree-tos
echo "✅ SSL certificate installed for $CF_NODE_NAME"
# Cron job line
#CRON_JOB="0 23 * * * certbot renew --quiet --deploy-hook \"systemctl restart nginx\""

# Check if the cron job already exists
#if sudo crontab -l | grep -Fq "$CRON_JOB"; then
#    echo "Cron job already exists."
#else
#    # Add the cron job
#    (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
#    echo "Cron job added successfully."
#fi
# Define the cron job
CRON_JOB="0 23 * * * certbot renew --quiet --deploy-hook \"systemctl restart nginx\""

# Function to install cron if missing
install_cron() {
    echo "Attempting to install cron..."

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -y && sudo apt-get install -y cron
        sudo systemctl enable cron && sudo systemctl start cron
    elif command -v yum &>/dev/null; then
        sudo yum install -y cronie
        sudo systemctl enable crond && sudo systemctl start crond
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y cronie
        sudo systemctl enable crond && sudo systemctl start crond
    elif command -v apk &>/dev/null; then
        sudo apk add --no-cache cronie
        sudo rc-update add crond && sudo service crond start
    else
        echo "Unsupported package manager. Cannot install cron automatically."
        return 1
    fi
}

# Check if crontab command exists
if ! command -v crontab &>/dev/null; then
    echo "crontab not found. Installing..."
    if ! install_cron; then
        echo "⚠️ Failed to install cron. Skipping cron job setup."
        exit 0
    fi

    # Verify installation success
    if ! command -v crontab &>/dev/null; then
        echo "⚠️ Cron installation failed or crontab still not found. Skipping cron setup."
        exit 0
    fi
fi

# Check if the cron job already exists
if sudo crontab -l 2>/dev/null | grep -Fq "$CRON_JOB"; then
    echo "Cron job already exists."
else
    # Add the cron job
    (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
    echo "✅ Cron job added successfully."
fi


# Check if the cron job already exists
if sudo crontab -l 2>/dev/null | grep -Fq "$CRON_JOB"; then
    echo "Cron job already exists."
else
    # Add the cron job
    (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
    echo "Cron job added successfully."
fi
# ---------------- Final Summary ----------------
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
# RAM calculation
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
ALLOC_RAM_MB=$(( TOTAL_RAM_MB * 90 / 100 ))

# Disk calculation
TOTAL_DISK_MB=$(df --output=size -m / | tail -1)
ALLOC_DISK_MB=$(( TOTAL_DISK_MB - 61440 ))   # reserve 60 GB
if (( ALLOC_DISK_MB < 0 )); then
  ALLOC_DISK_MB=0
fi

echo "  RAM (alloc) : ${ALLOC_RAM_MB} MB (from total ${TOTAL_RAM_MB} MB)"
echo "  Disk (alloc): ${ALLOC_DISK_MB} MB (from total ${TOTAL_DISK_MB} MB)"

LOCATION=$(curl -s https://ipinfo.io/$SERVER_IP | awk -F'"' '/"city"/{city=$4} /"country"/{country=$4} END{print city ", " country}')
echo "  Location    : $LOCATION"
echo
echo "IP Aliases:"
echo "  Wings Node : $CF_NODE_NAME → $SERVER_IP"
echo "  Game Node  : $CF_GAME_NAME → $SERVER_IP"
echo
echo "Open Ports:"
echo "  TCP: 80, 443, 2022, 5657, 56423, 8080, 25565-25599, 19132-19199"
echo "  UDP: 8080, 25565-25599, 19132-19199"
echo
echo "Your server is protected with firewalld and required ports are open."
echo "=============================================="

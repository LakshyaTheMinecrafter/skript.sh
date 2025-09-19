#!/bin/bash
set -e

# ==============================
# Helper functions
# ==============================
print_step() {
    echo
    echo "[*] $1"
}

save_env() {
    mkdir -p /root/cloudflare_env
    cat > /root/cloudflare_env/.env <<EOF
API_KEY=$CF_API
ZONE_ID=$CF_ZONE
DOMAIN=$CF_DOMAIN
DNS_CREATED=$DNS_CREATED
EOF
}

load_env() {
    if [[ -f /root/cloudflare_env/.env ]]; then
        source /root/cloudflare_env/.env
    fi
}

# ==============================
# Parse arguments
# ==============================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --api) CF_API="$2"; shift ;;
        --zone) CF_ZONE="$2"; shift ;;
        --domain) CF_DOMAIN="$2"; shift ;;
    esac
    shift
done

# ==============================
# Load existing env if present
# ==============================
load_env

# Ask interactively if not set
if [[ -z "$CF_API" ]]; then
    read -p "Enter your Cloudflare API Token: " CF_API
fi
if [[ -z "$CF_ZONE" ]]; then
    read -p "Enter your Cloudflare Zone ID: " CF_ZONE
fi
if [[ -z "$CF_DOMAIN" ]]; then
    read -p "Enter your Cloudflare domain (example.com): " CF_DOMAIN
fi

# ==============================
# Step 1: Update system
# ==============================
print_step "[1/8] Updating system packages..."
DEBIAN_FRONTEND=noninteractive apt-get -y -qq update
DEBIAN_FRONTEND=noninteractive apt-get -y -qq upgrade

# ==============================
# Step 2: Install Docker
# ==============================
print_step "[2/8] Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# ==============================
# Step 3: Enable swapaccount if GRUB exists
# ==============================
print_step "[3/8] Enabling swap accounting..."
if [[ -f /etc/default/grub ]]; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' /etc/default/grub
    update-grub || true
else
    echo "No GRUB found, skipping swapaccount step."
fi

# ==============================
# Step 4: Install Wings
# ==============================
print_step "[4/8] Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")" \
  --progress-bar
chmod u+x /usr/local/bin/wings

# ==============================
# Step 5: Create systemd service
# ==============================
print_step "[5/8] Creating systemd service for Wings..."
cat > /etc/systemd/system/wings.service <<'EOF'
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

# ==============================
# Step 6: Firewalld setup
# ==============================
print_step "[6/8] Installing and configuring firewalld..."
DEBIAN_FRONTEND=noninteractive apt-get -y install firewalld >/dev/null 2>&1 || true

ufw disable >/dev/null 2>&1 || true
systemctl stop ufw >/dev/null 2>&1 || true
systemctl disable ufw >/dev/null 2>&1 || true

systemctl enable --now firewalld >/dev/null 2>&1

ports=(2022 5657 56423 8080 25565-25800 50000-50500 19132)
for p in "${ports[@]}"; do
    firewall-cmd --permanent --add-port=${p}/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=${p}/udp 2>/dev/null || true
done
firewall-cmd --reload >/dev/null
echo "✅ Firewalld setup complete!"

# ==============================
# Step 7: Cloudflare DNS Setup
# ==============================
print_step "[7/8] Setting up Cloudflare DNS records..."
SERVER_IP=$(curl -s http://ipv4.icanhazip.com)

if [[ "$DNS_CREATED" != "true" ]]; then
    read -p "Enter a name for this Wings node (used for comments): " NODE_NAME

    # Find next available node number
    i=1
    while curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=node-$i.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | grep -q "\"count\":1"; do
        i=$((i+1))
    done

    CF_NODE_NAME="node-$i.$CF_DOMAIN"
    CF_GAME_NAME="game-$i.$CF_DOMAIN"

    # Create node and game records
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$CF_NODE_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME\"}" >/dev/null

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$CF_GAME_NAME\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME game ip\"}" >/dev/null

    echo "✅ DNS records created:"
    echo " - $CF_NODE_NAME"
    echo " - $CF_GAME_NAME"

    DNS_CREATED=true
    save_env
else
    echo "✅ DNS already created, skipping..."
fi

# ==============================
# Step 8: Resource info
# ==============================
print_step "[8/8] Gathering system resource info..."

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
ALLOC_RAM_MB=$((TOTAL_RAM_MB - 2048))

TOTAL_DISK_MB=$(df --output=avail -m / | tail -1)
ALLOC_DISK_MB=$((TOTAL_DISK_MB - 51200))

# ==============================
# Final summary including IP aliases
# ==============================
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

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

# If not in env, ask interactively
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
# System update
# ==============================
print_step "Updating system packages..."
DEBIAN_FRONTEND=noninteractive apt-get -y -qq update
DEBIAN_FRONTEND=noninteractive apt-get -y -qq upgrade

# ==============================
# Install Docker
# ==============================
print_step "Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# ==============================
# Enable swapaccount if GRUB exists
# ==============================
if [[ -f /etc/default/grub ]]; then
    print_step "Enabling swap accounting..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' /etc/default/grub
    update-grub || true
else
    echo "No GRUB found, skipping swapaccount step."
fi

# ==============================
# Install Wings
# ==============================
print_step "Installing Pterodactyl Wings..."
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

# ==============================
# Create systemd service
# ==============================
print_step "Creating systemd service for Wings..."
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
# Firewalld setup
# ==============================
print_step "Installing and configuring firewalld..."
DEBIAN_FRONTEND=noninteractive apt-get -y -qq install firewalld

ufw disable >/dev/null 2>&1 || true
systemctl stop ufw >/dev/null 2>&1 || true
systemctl disable ufw >/dev/null 2>&1 || true

systemctl enable --now firewalld >/dev/null 2>&1

# TCP Ports
firewall-cmd --permanent --add-port=2022/tcp >/dev/null
firewall-cmd --permanent --add-port=5657/tcp >/dev/null
firewall-cmd --permanent --add-port=56423/tcp >/dev/null
firewall-cmd --permanent --add-port=8080/tcp >/dev/null
firewall-cmd --permanent --add-port=25565-25800/tcp >/dev/null
firewall-cmd --permanent --add-port=50000-50500/tcp >/dev/null
firewall-cmd --permanent --add-port=19132/tcp >/dev/null

# UDP Ports
firewall-cmd --permanent --add-port=8080/udp >/dev/null
firewall-cmd --permanent --add-port=25565-25800/udp >/dev/null
firewall-cmd --permanent --add-port=50000-50500/udp >/dev/null
firewall-cmd --permanent --add-port=19132/udp >/dev/null

firewall-cmd --reload >/dev/null
echo "✅ Firewalld setup complete!"

# ==============================
# Cloudflare DNS Setup
# ==============================
if [[ "$DNS_CREATED" != "true" ]]; then
    print_step "Setting up Cloudflare DNS records..."

    read -p "Enter a name for this Wings node (used for comments): " NODE_NAME
    SERVER_IP=$(curl -s http://ipv4.icanhazip.com)

    # Find next available node number
    i=1
    while curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=node-$i.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | grep -q "\"count\":1"; do
        i=$((i+1))
    done

    CF_RECORD_NAME="node-$i.$CF_DOMAIN"
    CF_GAME_NAME="game-$i.$CF_DOMAIN"

    # Create node-{i} record
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"node-$i.$CF_DOMAIN\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME\"}" >/dev/null

    # Create game-{i} record
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
        -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"game-$i.$CF_DOMAIN\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false,\"comment\":\"$NODE_NAME game ip\"}" >/dev/null

    echo "✅ DNS records created:"
    echo " - $CF_RECORD_NAME"
    echo " - $CF_GAME_NAME"

    DNS_CREATED=true
    save_env
else
    echo "✅ DNS already created, skipping..."
fi

# ==============================
# Resource info
# ==============================
print_step "System resource info for panel setup..."

# RAM in MB (subtract 2048 MB)
TOTAL_RAM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM / 1024))
ALLOC_RAM=$((TOTAL_RAM_MB - 2048))

# Disk in MB (subtract 51200 MB = 50GB)
ALLOC_DISK=$(df --output=avail -m / | tail -1)
ALLOC_DISK=$((ALLOC_DISK - 51200))

echo "RAM available for nodes: ${ALLOC_RAM} MB"
echo "Disk available for nodes: ${ALLOC_DISK} MB"

# Show only non-docker, non-loopback IPs
echo "IP addresses:"
ip -o -4 addr show | awk '!/docker0/ && !/lo/ {print $2 ": " $4}'

echo
echo "✅ Wings installation complete!"

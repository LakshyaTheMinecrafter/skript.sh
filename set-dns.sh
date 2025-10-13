#!/bin/bash
# set-dns.sh
# Script to set custom DNS servers on Ubuntu/Debian VPS

# Your desired DNS servers
DNS_SERVERS=("8.8.8.8" "8.8.4.4" "1.1.1.1" "1.0.0.1")

# Disable systemd-resolved (if running)
if systemctl is-active --quiet systemd-resolved; then
    echo "Disabling systemd-resolved..."
    sudo systemctl disable --now systemd-resolved
fi

# Remove existing resolv.conf
if [ -f /etc/resolv.conf ]; then
    echo "Removing existing /etc/resolv.conf..."
    sudo rm /etc/resolv.conf
fi

# Create a new resolv.conf
echo "Creating new /etc/resolv.conf with custom DNS..."
sudo bash -c "cat > /etc/resolv.conf <<EOF
# Custom DNS configured by script
$(for dns in "${DNS_SERVERS[@]}"; do echo "nameserver $dns"; done)
EOF"

# Make it immutable to prevent overwrites
sudo chattr +i /etc/resolv.conf

echo "DNS has been updated and locked. Current /etc/resolv.conf:"
cat /etc/resolv.conf

echo "Done! Your VPS should now use the custom DNS."

#!/bin/bash
set -e

# Enable UFW without interaction
sudo ufw enable

# TCP ports
for port in 80 443 2022 5657 56423 8080 25565:25599 19132:19199; do
    sudo ufw allow ${port}/tcp
done

# UDP ports
for port in 80 443 2022 5657 56423 8080 25565:25599 19132:19199; do
    sudo ufw allow ${port}/udp
done

sudo ufw reload

echo "✅ UFW setup complete!"
echo "Allowed TCP & UDP: 80, 443, 2022, 5657, 56423, 8080, 25565-25599, 19132-19199"

#!/bin/bash

set -e

echo "[1/4] Installing firewalld..."
sudo apt update -y
sudo apt install -y firewalld

echo "[2/4] Preparing..."
echo "[3/4] Enabling firewalld..."
sudo systemctl enable --now firewalld

echo "[4/4] Configuring allowed ports..."

# TCP ports
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --zone=public --add-port=443/tcp
sudo firewall-cmd --permanent --add-port=2022/tcp
sudo firewall-cmd --permanent --add-port=5657/tcp
sudo firewall-cmd --permanent --add-port=56423/tcp
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --add-port=25565-25599/tcp
sudo firewall-cmd --permanent --add-port=19132-19199/tcp
sudo firewall-cmd --permanent --add-port=3306/tcp
# UDP ports
sudo firewall-cmd --permanent --add-port=8080/udp
sudo firewall-cmd --permanent --add-port=25565-25599/udp
sudo firewall-cmd --permanent --add-port=19132-19199/udp

# Reload rules
sudo firewall-cmd --reload

echo "✅ Firewalld setup complete!"
echo "Allowed TCP: 80, 443, 3306, 2022, 5657, 56423, 8080, 25565-25599, 19132-19199"
echo "Allowed UDP: 8080, 25565-25599, 19132-19199"

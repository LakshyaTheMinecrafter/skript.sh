#!/bin/bash

# UFW script to open specified ports

echo "Enabling UFW and opening ports..."

# Allow TCP ports/
ufw allow 22/tcp
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

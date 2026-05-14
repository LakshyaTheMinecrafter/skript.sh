#!/bin/bash

set -e

# Require root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

echo "[INFO] Updating packages..."
apt update -y

# Python3
if ! command -v python3 >/dev/null 2>&1; then
    echo "[INFO] Installing python3..."
    apt install -y python3
else
    echo "[INFO] python3 already installed. Skipping."
fi

# pip3
if ! command -v pip3 >/dev/null 2>&1; then
    echo "[INFO] Installing pip3..."
    apt install -y python3-pip
else
    echo "[INFO] pip3 already installed. Skipping."
fi

# requests module
if ! python3 -c "import requests" >/dev/null 2>&1; then
    echo "[INFO] Installing python3-requests..."
    apt install -y python3-requests
else
    echo "[INFO] requests already installed. Skipping."
fi

# curl
if ! command -v curl >/dev/null 2>&1; then
    echo "[INFO] Installing curl..."
    apt install -y curl
else
    echo "[INFO] curl already installed. Skipping."
fi

echo
echo "[INFO] Downloading Python script..."
curl -fsSL \
https://raw.githubusercontent.com/LakshyaTheMinecrafter/skript.sh/main/ddos-proc.py \
-o /tmp/ddos-proc.py

chmod +x /tmp/ddos-proc.py

echo
echo "[INFO] Setup complete."
echo "[INFO] Run the script manually using:"
echo
echo "python3 /tmp/ddos-proc.py"
echo

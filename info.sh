#!/bin/bash

# ===== Color setup =====
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}===== VPS INFORMATION REPORT =====${RESET}\n"

# --- Date & Hostname ---
echo -e "${YELLOW}Date:${RESET} $(date)"
echo -e "${YELLOW}Hostname:${RESET} $(hostname)"
echo -e "${YELLOW}Uptime:${RESET} $(uptime -p)\n"

# --- Public IP & Geolocation ---
IP=$(curl -s ifconfig.me)
echo -e "${YELLOW}Public IP:${RESET} $IP"
GEO=$(curl -s ipinfo.io/$IP)
CITY=$(echo $GEO | grep -oP '(?<="city":")[^"]*')
REGION=$(echo $GEO | grep -oP '(?<="region":")[^"]*')
COUNTRY=$(echo $GEO | grep -oP '(?<="country":")[^"]*')
ISP=$(echo $GEO | grep -oP '(?<="org":")[^"]*')
echo -e "${YELLOW}Location:${RESET} $CITY, $REGION, $COUNTRY"
echo -e "${YELLOW}ISP:${RESET} $ISP\n"

# --- CPU Info ---
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
CPU_CORES=$(nproc)
CPU_ARCH=$(uname -m)
CPU_FREQ=$(grep -m1 "cpu MHz" /proc/cpuinfo | awk '{print $4}') 
echo -e "${GREEN}CPU Model:${RESET} $CPU_MODEL"
echo -e "${GREEN}CPU Architecture:${RESET} $CPU_ARCH"
echo -e "${GREEN}CPU Cores:${RESET} $CPU_CORES"
echo -e "${GREEN}CPU Frequency:${RESET} $CPU_FREQ MHz\n"

# --- RAM Info ---
TOTAL_RAM=$(free -h | grep Mem | awk '{print $2}')
USED_RAM=$(free -h | grep Mem | awk '{print $3}')
echo -e "${CYAN}RAM:${RESET} $USED_RAM / $TOTAL_RAM\n"

# --- Disk Usage ---
DISK_INFO=$(df -h / | tail -1 | awk '{print $3 " used of " $2 " (" $5 " used)"}')
echo -e "${CYAN}Disk:${RESET} $DISK_INFO\n"

# --- Network Info ---
echo -e "${YELLOW}Local IPs:${RESET} $(hostname -I)"
echo -e "${YELLOW}Default Gateway:${RESET} $(ip route | grep default | awk '{print $3}')\n"

# --- OS Info ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "${GREEN}OS:${RESET} $PRETTY_NAME"
else
    echo -e "${GREEN}OS:${RESET} $(uname -s) $(uname -r)"
fi

# --- Load Average ---
echo -e "${YELLOW}Load Average:${RESET} $(uptime | awk -F'load average:' '{print $2}' | xargs)\n"

# --- Top Processes ---
echo -e "${RED}Top Processes (by CPU usage):${RESET}"
ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -6
echo ""

# --- Virtualization Check ---
VIRT_TYPE=$(systemd-detect-virt 2>/dev/null)
if [ -z "$VIRT_TYPE" ]; then
    # fallback
    if [ -f /proc/user_beancounters ]; then
        VIRT_TYPE="OpenVZ/LXC"
    elif grep -q "lxc" /proc/1/environ 2>/dev/null; then
        VIRT_TYPE="LXC"
    else
        VIRT_TYPE="Unknown/Physical"
    fi
fi
echo -e "${BOLD}VPS Virtualization Type:${RESET} $VIRT_TYPE"

echo -e "\n${BOLD}${CYAN}===== END OF REPORT =====${RESET}"

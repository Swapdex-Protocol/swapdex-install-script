#!/bin/bash

# run this script as root
# wget https://raw.githubusercontent.com/starkleytech/swapdex-install-script/main/install_swapdex.sh
# chmod +x install_swapdex.sh
# ./install_swapdex.sh

set -e

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if the script is executed as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Create swapdex user if it doesn't exist
echo -e "${GREEN}Creating swapdex user if it doesn't exist...${NC}"
if ! id -u swapdex > /dev/null 2>&1; then
    useradd -m -s /bin/bash swapdex
fi

# Install required packages
echo -e "${GREEN}Installing required packages...${NC}"
if grep -q "ubuntu" /etc/os-release; then
    apt-get update
    apt-get install -y curl ntp fail2ban ufw jq
elif grep -q "rocky" /etc/os-release; then
    dnf install -y curl ntp fail2ban firewalld jq
    systemctl start firewalld
    systemctl enable firewalld
else
    echo -e "${RED}Unsupported OS${NC}"
    exit 1
fi

# Configure and enable the time server
echo -e "${GREEN}Configuring and enabling the time server...${NC}"
systemctl enable ntp
systemctl start ntp

# Configure the firewall
echo -e "${GREEN}Configuring the firewall...${NC}"
if grep -q "ubuntu" /etc/os-release; then
    ufw allow 22
    ufw allow 30333/tcp
    ufw allow 30333/udp
    ufw allow ntp
    ufw --force enable
elif grep -q "rocky" /etc/os-release; then
    firewall-cmd --zone=public --permanent --add-service=ssh
    firewall-cmd --zone=public --permanent --add-port=30333/tcp
    firewall-cmd --zone=public --permanent --add-port=30333/udp
    firewall-cmd --zone=public --permanent --add-service=ntp
    firewall-cmd --reload
fi

# Install and configure fail2ban
echo -e "${GREEN}Installing and configuring fail2ban...${NC}"
systemctl enable fail2ban
systemctl start fail2ban

# Download the swapdex binary
echo -e "${GREEN}Downloading the swapdex binary...${NC}"
if grep -q "ubuntu" /etc/os-release; then
    URL="https://download.starkleytech.com/swapdex/swapdex_ubuntu"
elif grep -q "rocky" /etc/os-release; then
    URL="https://download.starkleytech.com/swapdex/swapdex_rocky_linux"
fi

curl -L -o /usr/bin/swapdex $URL
chmod +x /usr/bin/swapdex

# Create swapdex service file
echo -e "${GREEN}Creating swapdex service file...${NC}"
cat >/lib/systemd/system/swapdex.service <<EOL
[Unit]
Description=SwapDEX Validator
After=network-online.target

[Service]
ExecStart=/usr/bin/swapdex --port "30333" --name A Node Name --validator --chain swapdex 
User=swapdex
Restart=always
ExecStartPre=/bin/sleep 5
RestartSec=30s
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOL

# Prompt user for node name and replace placeholder in service file
NODE_NAME=""
while true; do
    read -p "Enter a valid node name (alphanumeric, spaces, hyphens, and underscores only): " NODE_NAME
    if echo "$NODE_NAME" | grep -Eq '^[a-zA-Z0-9 _-]+$'; then
        break
    else
        echo -e "${RED}Invalid node name. Please use only alphanumeric characters, spaces, hyphens, and underscores.${NC}"
    fi
done

sed -i "s|A Node Name|\"${NODE_NAME}\"|g" /lib/systemd/system/swapdex.service




# Start and enable the service
echo -e "${GREEN}Starting and enabling the swapdex service...${NC}"
systemctl daemon-reload
systemctl enable swapdex
systemctl start swapdex



# Check if the node is syncing
echo -e "${GREEN}Checking if the node is syncing...${NC}"
sleep 60
sync_status_json=$(curl -s -H "Content-Type: application/json" --data '{"id":1, "jsonrpc":"2.0", "method":"system_syncState", "params":[]}' http://localhost:9933/)
sync_status=$(echo "$sync_status_json" | jq '.result.currentBlock')

if [ -z "$sync_status" ]; then
    echo -e "${RED}Failed to retrieve sync status. Please check the logs for more information.${NC}"
    exit 1
elif [ $sync_status != "null" ] && [ $sync_status -gt 0 ]; then
    echo -e "${GREEN}Node is syncing. Current block: $sync_status${NC}"
else
    echo -e "${RED}Node is not syncing. Please check the logs for more information.${NC}"
    exit 1
fi

# Generate session key
session_key_json=$(curl -s -H "Content-Type: application/json" -d '{"id":1, "jsonrpc":"2.0", "method": "author_rotateKeys", "params":[]}' http://localhost:9933/)
session_key=$(echo "$session_key_json" | jq -r '.result')
echo -e "${GREEN}Session key generated: $session_key${NC}"

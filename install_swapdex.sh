#!/bin/bash

# run this script as root
# wget https://raw.githubusercontent.com/starkleytech/swapdex-install-script/main/install_swapdex.sh
# chmod +x install_swapdex.sh
# ./install_swapdex.sh

set -e

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
LIGHT_PINK='\033[1;35m'

NC='\033[0m' # No Color

# Check if the script is executed as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Check if the OS is Ubuntu 22.04 or Rocky Linux 8
if grep -Eq 'ubuntu' /etc/os-release && grep -Eq '22.04' /etc/os-release; then
    echo -e "${GREEN}Running on Ubuntu 22.04${NC}"
elif grep -Eq 'rocky' /etc/os-release && grep -Eq '8.' /etc/os-release; then
    echo -e "${GREEN}Running on Rocky Linux 8${NC}"
else
    echo -e "${RED}Unsupported OS. This script supports Ubuntu 22.04 and Rocky Linux 8 only.${NC}"
    exit 1
fi


# Prompt user if they want to install Kusari
while true; do
    echo -ne "${YELLOW}Do you want to install Kusari (Y) or SwapDEX (N)  (Y/N)? ${NC}"
    read install_kusari

    case $install_kusari in
        [Yy]* ) install_kusari=true; break;;
        [Nn]* ) install_kusari=false; break;;
        * ) echo -e "${RED}Please answer Y or N.${NC}";;
    esac
done

if [ "$install_kusari" = true ]; then
    service_name="kusari"
    user_name="kusari"
    chain_name="kusari"
    ubuntu_url="https://download.starkleytech.com/kusari/swapdex_ubuntu_21_04"
    rocky_url="https://download.starkleytech.com/kusari/swapdex_rocky_linux_8"
else
    service_name="swapdex"
    user_name="swapdex"
    chain_name="swapdex"
    ubuntu_url="https://download.starkleytech.com/swapdex/swapdex_ubuntu"
    rocky_url="https://download.starkleytech.com/swapdex/swapdex_rocky_linux"
fi


# Check if previous swapdex or kusari was active and prompt user if they want to delete the database
if systemctl is-active --quiet swapdex || systemctl is-active --quiet kusari; then
    # Stop service swapdex
    echo -e "${GREEN}Stop service $service_name if it exists and is active...${NC}"
    if systemctl is-active --quiet $service_name; then
        systemctl stop $service_name > /dev/null 2>&1
    fi
    while true; do
        echo -ne "${YELLOW}Do you want to delete the previous database (Y/N)? ${NC}"
        read delete_database

        case $delete_database in
            [Yy]* )
                if [ "$install_kusari" = true ]; then
                    sudo -u $user_name swapdex purge-chain --chain $chain_name -y
                else
                    sudo -u $user_name swapdex purge-chain --chain $chain_name -y
                fi
                break;;
            [Nn]* ) break;;
            * ) echo -e "${RED}Please answer Y or N.${NC}";;
        esac
    done
fi






# Create swapdex user if it doesn't exist
echo -e "${GREEN}Creating $user_name user if it doesn't exist...${NC}"
if ! id -u $user_name > /dev/null 2>&1; then
    useradd -m -s /bin/bash $user_name
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
echo -e "${GREEN}Downloading the $service_name binary...${NC}"
if grep -q "ubuntu" /etc/os-release; then
    URL=$ubuntu_url
elif grep -q "rocky" /etc/os-release; then
    URL=$rocky_url
fi

curl -L -o /usr/bin/$service_name $URL
chmod +x /usr/bin/$service_name

# Create swapdex service file
echo -e "${GREEN}Creating $service_name service file...${NC}"
cat >/lib/systemd/system/$service_name.service <<EOL
[Unit]
Description=$service_name Validator
After=network-online.target

[Service]
ExecStart=/usr/bin/$service_name --port "30333" --name A Node Name --validator --chain $chain_name
User=$user_name
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
    echo -ne "${YELLOW}Enter a valid node name (alphanumeric, spaces, hyphens, and underscores only): ${NC}"
    read NODE_NAME

    if echo "$NODE_NAME" | grep -Eq '^[a-zA-Z0-9 _-]+$'; then
        break
    else
        echo -e "${RED}Invalid node name. Please use only alphanumeric characters, spaces, hyphens, and underscores.${NC}"
    fi
done

sed -i "s|A Node Name|\"${NODE_NAME}\"|g" /lib/systemd/system/$service_name.service

# Start and enable the service
echo -e "${GREEN}Starting and enabling the $service_name service...${NC}"
systemctl daemon-reload
systemctl enable $service_name
systemctl start $service_name

# Check if the node is syncing
echo -e "${GREEN}Checking if the node is syncing...${NC}"

max_attempts=10
attempt=1
sync_status=""

while [ -z "$sync_status" ] && [ $attempt -le $max_attempts ]; do
    echo -e "${GREEN}Attempt $attempt/$max_attempts${NC}"
    sleep 30
    sync_status_json=$(curl -s -H "Content-Type: application/json" --data '{"id":1, "jsonrpc":"2.0", "method":"system_syncState", "params":[]}' http://localhost:9933/ 2>/dev/null)
    sync_status=$(echo "$sync_status_json" | jq '.result.currentBlock' 2>/dev/null)

    if [ -n "$sync_status" ] && [ "$sync_status" != "null" ] && [ "$sync_status" -gt 0 ]; then
        echo -e "${GREEN}Node is syncing. Current block: $sync_status${NC}"
    else
        sync_status=""
        attempt=$((attempt + 1))
    fi
done

if [ -z "$sync_status" ]; then
    echo -e "${RED}Failed to retrieve sync status after $max_attempts attempts. Please check the logs for more information.${NC}"
    exit 1
fi

# Prompt the user if they want to generate a session key
generate_key=""

while true; do
    echo -ne "${YELLOW}Do you want to generate a session key? (Y/n): ${NC}"
    read generate_key

    case $generate_key in
        [Yy]* )
            session_key_json=$(curl -s -H "Content-Type: application/json" -d '{"id":1, "jsonrpc":"2.0", "method": "author_rotateKeys", "params":[]}' http://localhost:9933/)
            session_key=$(echo "$session_key_json" | jq -r '.result')
            echo -e "${LIGHT_PINK}Session key generated:${NC}"
            echo -e "${LIGHT_PINK}$session_key${NC}"
            break
            ;;
        [Nn]* )
            echo -e "${GREEN}Skipping session key generation.${NC}"
            break
            ;;
        * )
            echo -e "${RED}Please answer yes (Y) or no (n).${NC}"
            ;;
    esac
done

#!/bin/bash

init_ufw() {
# Check if ufw is installed, if not, install it
if ! command -v ufw &> /dev/null; then
    echo "Installing ufw..."
    sudo apt-get update
    sudo apt-get install -y ufw
fi
}

# Function to extract ports from config.json
extract_ports() {
    jq -r '.inbounds[].port' /usr/local/x-ui/bin/config.json
}

open_deffult_ports() {
# Add default ports to ufw if not already added
IFS=',' read -ra default_ports_array <<< "$default_ports"
for port in "${default_ports_array[@]}"; do
    sudo ufw allow $port
done
}

auto_ports() {
            # Close all ports except those in config.json
            echo "从config.json中提取并开启端口:"
            config_ports=$(extract_ports)
            
            # Close ports not in config.json
            current_ports=$(sudo ufw status numbered | awk '$1 ~ /^[0-9]+$/ {print $NF}')
            IFS=$'\n' read -ra current_ports_array <<< "$current_ports"
            for port in "${current_ports_array[@]}"; do
                if [[ ! " ${config_ports[@]} " =~ " $port " && ! " ${default_ports_array[@]} " =~ " $port " ]]; then
                    sudo ufw delete allow $port
                    echo "关闭端口 $port"
                fi
            done
}

show_ports() {
            echo "已开放的端口:"
            netstat -ntulp | awk '$6 == "LISTEN" {print $4}' | awk -F ":" '{print $NF}' | sort -nu
}

show_menu() {
init_ufw
while true; do
    show_ports
    echo "1. 开放默认端口"
    echo "2. 从config.json中提取并开启端口"
    echo "0. 退出"
    read -p "请选择操作（0-2）: " choice

        case $choice in
            1) open_deffult_ports ;;
            2) auto_ports ;;
            0) echo "退出程序。"; exit 0 ;;
            *) echo "无效选择";;
        esac
done
}

# Default open ports
default_ports="22,3337,51888"

# 调用主菜单
show_menu

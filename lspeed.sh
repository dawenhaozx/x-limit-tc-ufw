#!/bin/bash

# Default open ports
default_ports="22,3337,51888"

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

####################################################### 获取网络接口名称
get_network_interface() {
    local interface=$(ip link | awk -F: '/^[0-9]+: (eth|ens|enp)[^@]*(@[^:]+)?:/{print $2;exit}' | xargs | sed 's/@.*//')
    echo $interface
}

# 初始化 tc
init_tc() {
    IFACE=$(get_network_interface)
    if [ -z "$IFACE" ]; then
        echo "无法自动检测网络接口。"
        read -p "输入网络接口名称（如 eth0）: " IFACE
    fi

    # 检查是否已经存在 tc 规则
    if tc qdisc show dev $IFACE | grep -q 'htb'; then
        echo "TC 规则已经存在于 $IFACE。"
    else
        # 清除现有的队列规则
        tc qdisc del dev $IFACE root 2>/dev/null

        # 添加新的队列规则
        tc qdisc add dev $IFACE root handle 1: htb r2q 10
        tc class add dev $IFACE parent 1: classid 1:1 htb rate 10000mbit
        echo "TC 初始化完成。"
    fi
}

# 函数：提取 config.json 中的端口
extract_ports() {
    jq -r '.inbounds[].port' /usr/local/x-ui/bin/config.json
}

# 函数：检查并设置限速
check_and_set_limit() {
    PORT=$1
    BANDWIDTH=$2
    CLASSID=$3

    # 检查是否已经设置了限速规则
    if tc class show dev $IFACE | grep "1:$CLASSID"; then
        read -p "端口 $PORT 已有限速规则。是否覆盖? (y/n): " choice
        if [ "$choice" != "y" ]; then
            return
        fi
    fi

    # 设置限速规则
    tc class replace dev $IFACE parent 1:1 classid 1:$CLASSID htb rate ${BANDWIDTH}mbit ceil ${BANDWIDTH}mbit
    tc filter replace dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip dport $PORT 0xffff flowid 1:$CLASSID
    tc filter replace dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip sport $PORT 0xffff flowid 1:$CLASSID
}

# 函数：手动设置限速
manual_limit() {
    echo "可用端口："
    PORTS=$(extract_ports)
    echo $PORTS
    read -p "选择端口号: " PORT
    read -p "输入限速值（Mbps，不带单位）: " BANDWIDTH
    CLASSID=1001
    for P in $PORTS; do
        if [ "$P" == "$PORT" ]; then
            check_and_set_limit $PORT $BANDWIDTH $CLASSID
            break
        fi
        CLASSID=$((CLASSID+1))
    done
}

# 函数：分析并获取最常见的限速值
get_most_common_speed() {
    PORTS=$(extract_ports)
    CLASSID=1001
    declare -A speed_count
    for PORT in $PORTS; do
        SPEED=$(tc class show dev $IFACE | grep "1:$CLASSID" | awk '{for(i=1;i<=NF;i++) if ($i=="rate") print $(i+1)}' | sed 's/mbit//;s/kbit/Kbps/;s/gbit/Gbps/')
        if [ ! -z "$SPEED" ]; then
            ((speed_count[$SPEED]++))
        fi
        CLASSID=$((CLASSID+1))
    done
    # 返回出现次数最多的限速值
    most_common_speed=""
    max_count=0
    for speed in "${!speed_count[@]}"; do
        if [[ ${speed_count[$speed]} -gt $max_count ]]; then
            max_count=${speed_count[$speed]}
            most_common_speed=$speed
        fi
    done
    echo $most_common_speed
}

# 函数：自动设置限速
auto_limit() {
    MOST_COMMON_SPEED=$(get_most_common_speed)
    if [ ! -z "$MOST_COMMON_SPEED" ]; then
        echo "最常见的限速是 $MOST_COMMON_SPEED Mbps。是否覆盖除此之外的端口限速? (y/n): "
        read OVERRIDE_CHOICE
    else
        OVERRIDE_CHOICE="y"
    fi

    read -p "输入限速值（Mbps，不带单位）: " BANDWIDTH
    CLASSID=1001
    for PORT in $(extract_ports); do
        CURRENT_SPEED=$(tc class show dev $IFACE | grep "1:$CLASSID" | awk '{for(i=1;i<=NF;i++) if ($i=="rate") print $(i+1)}' | sed 's/mbit//;s/kbit/Kbps/;s/gbit/Gbps/')
        if [ "$OVERRIDE_CHOICE" == "y" ] || [ "$CURRENT_SPEED" == "$MOST_COMMON_SPEED" ] || [ -z "$CURRENT_SPEED" ]; then
            tc class replace dev $IFACE parent 1:1 classid 1:$CLASSID htb rate ${BANDWIDTH}mbit ceil ${BANDWIDTH}mbit
            tc filter replace dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip dport $PORT 0xffff flowid 1:$CLASSID
            tc filter replace dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip sport $PORT 0xffff flowid 1:$CLASSID
        fi
        CLASSID=$((CLASSID+1))
    done
}

# 函数：取消所有限速
remove_all_limits() {
    tc qdisc del dev $IFACE root
    init_tc  # 重新初始化 tc
}

# 函数：显示已设置的端口限速
show_limits() {
    echo "当前端口限速设置："
    PORTS=$(extract_ports)
    CLASSID=1001
    for PORT in $PORTS; do
        SPEED=$(tc class show dev $IFACE | grep "1:$CLASSID" | awk '{for(i=1;i<=NF;i++) if ($i=="rate") print $(i+1)}' | sed 's/mbit//;s/kbit/Kbps/;s/gbit/Gbps/')
        if [ ! -z "$SPEED" ]; then
            echo "端口 $PORT: 限速 $SPEED"
        else
            echo "端口 $PORT: 未设置限速"
        fi
        CLASSID=$((CLASSID+1))
    done
}

# 主菜单
show_menu() {
    IFACE=$(get_network_interface)
    init_tc  # 脚本启动时初始化 tc
    init_ufw
    while true; do
        show_ports
        show_limits
        echo "1) 手动设置端口限速"
        echo "2) 自动读取 config.json 端口限速"
        echo "3) 取消全部限速"
        echo "4) 开放默认端口"
        echo "5) 从config.json中提取并开启端口"
        echo "0) 退出"
        read -p "请选择操作（0-3）: " choice

        case $choice in
            1) manual_limit ;;
            2) auto_limit ;;
            3) remove_all_limits ;;
            4) open_deffult_ports ;;
            5) auto_ports ;;
            0) echo "退出程序。"; exit 0 ;;
            *) echo "无效选择";;
        esac
    done
}

# 调用主菜单
show_menu

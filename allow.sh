#!/bin/bash

# 设置A.json文件路径
json_file="$(pwd)/A.json"

# 检查A.json文件是否存在
if [ ! -f "$json_file" ]; then
    echo "错误: $json_file 文件不存在。"
    exit 1
fi

# 提取SSH端口
SSH_PORT=$(grep -oP "(?<=Port\s)\d+" /etc/ssh/sshd_config)
SSH_PORT=${SSH_PORT:-22}  # 如果没有提取到端口，默认为22

# 输出SSH端口
echo "当前SSH端口为: $SSH_PORT"

# 读取A.json文件中的域名列表和端口列表
readarray -t domains < <(jq -r '.domain[]' "$json_file")
readarray -t ports < <(jq -r '.port[]' "$json_file")
ports+=("$SSH_PORT")  # 将SSH端口加入到ports数组中

# 解析域名并存储IP地址
ips=()
for domain in "${domains[@]}"; do
    ip=$(dig +short "$domain" | head -n1)
    [ -n "$ip" ] && ips+=("$ip") || echo "无法解析域名 $domain"
done

# 在user.rules中查找与SSH端口对应的IP
ufwips=($(grep -oP "allow\s+any\s+$SSH_PORT\s+0\.0\.0\.0/0\s+any\s+\K\S+" /etc/ufw/user.rules))

# 打印IP地址和端口
echo "IP地址: ${ips[*]}"
echo "端口: ${ports[*]}"

# 计算差异IP地址
ips_diff=()
ufwips_diff=()

# 计算ips中减去ufwips的差集
ips_diff=($(comm -13 <(printf "%s\n" "${ufwips[@]}" | sort) <(printf "%s\n" "${ips[@]}" | sort)))

# 计算ufwips中减去ips的差集
ufwips_diff=($(comm -13 <(printf "%s\n" "${ips[@]}" | sort) <(printf "%s\n" "${ufwips[@]}" | sort)))

# 输出结果
echo "ips 减去 (ips 和 ufwips 的交集) = ${ips_diff[*]}"
echo "ufwips 减去 (ips 和 ufwips 的交集) = ${ufwips_diff[*]}"

# 函数：管理UFW规则
ufw_rule() {
    local action="$1"
    local ip="$2"
    local port="$3"

    # 判断是否为0.0.0.0/0，直接执行相应操作
    if [ "$ip" = "0.0.0.0/0" ]; then
        case "$action" in
            "allow")
                ufw "$action" "$port" > /dev/null && echo "已执行操作：$action any port $port"
                ;;
            "delete")
                ufw delete allow "$port" > /dev/null && echo "已执行操作：$action any port $port"
                ;;
            *)
                echo "无效的操作：$action"
                return 1
                ;;
        esac
    else
        case "$action" in
            "allow")
                ufw "$action" from "$ip" to any port "$port" > /dev/null && echo "已执行操作：$action allow from $ip to any port $port"
                ;;
            "delete")
                ufw delete allow from "$ip" to any port "$port" > /dev/null && echo "已执行操作：$action allow from $ip to any port $port"
                ;;
            *)
                echo "无效的操作：$action"
                return 1
                ;;
        esac
    fi
}

# 添加ips_diff到ports
for ip in "${ips_diff[@]}"; do
    for port in "${ports[@]}"; do
        ufw_rule "allow" "$ip" "$port"
    done
done

# 删除ufwips_diff到ports
for ip in "${ufwips_diff[@]}"; do
    for port in "${ports[@]}"; do
        ufw_rule "delete" "$ip" "$port"
    done
done

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

# 检查是否成功提取端口
if [ -z "$SSH_PORT" ]; then
    echo "无法提取SSH端口。请检查sshd_config文件。默认使用端口22。"
    SSH_PORT=22
else
    echo "当前SSH端口为: $SSH_PORT"
fi

# 函数：解析域名为IP
resolve_domain() {
    local domain="$1"
    local result
    result=$(dig +short "$domain")

    # 检查是否成功解析域名
    if [ -z "$result" ]; then
        echo "错误: 无法解析域名 $domain。"
        return 1
    else
        echo "$result"
    fi
}

# 函数：添加UFW规则
add_ufw_rule() {
    local ip="$1"
    local port="$2"
    local rule="allow from $ip to any port $port"

    # 检查规则是否已存在
    if ! ufw status | grep -F -q -- "$rule"; then
        ufw allow from "$ip" to any port "$port"
        echo "添加规则：$rule"
    else
        echo "规则已存在：$rule"
    fi
}

# 函数：删除UFW规则
delete_ufw_rule() {
    local port="$1"

    # 获取UFW规则中允许的IP列表
    local ufw_status=$(grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" /etc/ufw/user.rules | sort -u)
    
    # 输出UFW规则中允许的IP
    echo "UFW规则中允许的IP（$SSH_PORT端口）："
    for allowed_ip in ${ufw_status[@]}; do
        echo "$allowed_ip"
    done

    # 从A.json中提取的IP
    local domains=($(jq -r '.domain[]' "$json_file"))
    local resolved_ips=()
    for domain in "${domains[@]}"; do
        ip=$(resolve_domain "$domain")

        # 检查是否成功解析域名
        if [ $? -eq 0 ]; then
            resolved_ips+=("$ip")
        fi
    done

    # 执行UFW删除多余的规则
    for existing_ip in ${ufw_status[@]}; do
        # 如果该IP不在解析后的IP列表中，删除规则
        if [[ ! " ${resolved_ips[@]} " =~ " ${existing_ip} " ]]; then
            ufw delete allow from "$existing_ip" to any port "$port"
            echo "删除规则：allow from $existing_ip to any port $port"
        fi
    done
}

# 读取A.json文件
domains=($(jq -r '.domain[]' "$json_file"))

# 存储解析后的IP
resolved_ips=()
for domain in "${domains[@]}"; do
    ip=$(resolve_domain "$domain")

    # 检查是否成功解析域名
    if [ $? -eq 0 ]; then
        resolved_ips+=("$ip")
    fi
done

# 执行UFW操作
for ip in "${resolved_ips[@]}"; do
    add_ufw_rule "$ip" "$SSH_PORT"
done

# 删除多余的UFW规则
delete_ufw_rule "$SSH_PORT"

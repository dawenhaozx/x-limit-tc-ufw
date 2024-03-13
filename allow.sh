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
    dig +short "$domain"
}

# 函数：添加UFW规则
add_ufw_rule() {
    local ip="$1"
    local port="$2"
    local rule="allow from $ip to any port $port"

    # 检查规则是否已存在
    if ! ufw status | grep -q "$rule"; then
        ufw $rule comment "允许 $domain 访问端口 $port"
        echo "添加规则：$rule"
    else
        echo "规则已存在：$rule"
    fi
}

# 函数：删除UFW规则
delete_ufw_rule() {
    local port="$1"
    
    # 列出待删除的规则
    local rules_to_delete=$(ufw status | grep "ALLOW" | grep -vE "(${domains[@]// /|})" | grep "ALLOW.*$port" | awk '{print $2}')

    # 删除规则
    for source_ip in $rules_to_delete; do
        ufw delete allow from "$source_ip" to any port "$port"
        echo "删除规则：allow from $source_ip to any port $port"
    done
}

# 读取A.json文件
domains=($(jq -r '.domain[]' "$json_file"))
ports=("ssh" $(jq -r '.port[]' "$json_file"))

# 遍历域名，解析成IP并配置UFW规则
for domain in "${domains[@]}"; do
    ip=$(resolve_domain "$domain")

    # 检查是否成功解析域名
    if [ -z "$ip" ]; then
        echo "错误: 无法解析域名 $domain。"
    else
        add_ufw_rule "$ip" "$SSH_PORT"
        # 遍历端口配置，添加UFW规则
        for port in "${ports[@]}"; do
            add_ufw_rule "$ip" "$port"
        done
    fi
done

# 删除不在解析域名IP列表中的对应端口规则
for port in "${ports[@]}"; do
    delete_ufw_rule "$port"

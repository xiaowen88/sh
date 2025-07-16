#!/bin/sh

# OpenWrt 3WAN配置脚本
# 作者: 振段通讯
# 用途: 自动配置3个WAN口 (eth4=WAN1, eth3=WAN2, eth2=WAN3, eth0-1=LAN)

set -e

LOG_FILE="/tmp/3wan_setup.log"
BACKUP_DIR="/tmp/config_backup_$(date +%Y%m%d_%H%M%S)"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 错误处理
error_exit() {
    log "错误: $1"
    exit 1
}

# 检查是否为root用户
check_root() {
    if [ "$(id -u)" != "0" ]; then
        error_exit "此脚本需要root权限运行"
    fi
}

# 备份当前配置
backup_config() {
    log "开始备份当前配置到 $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # 备份关键配置文件
    cp /etc/config/network "$BACKUP_DIR/network.bak" || error_exit "备份network配置失败"
    cp /etc/config/dualwan "$BACKUP_DIR/dualwan.bak" || error_exit "备份dualwan配置失败"
    cp /etc/config/misc "$BACKUP_DIR/misc.bak" || error_exit "备份misc配置失败"
    cp /etc/config/firewall "$BACKUP_DIR/firewall.bak" || error_exit "备份firewall配置失败"
    
    log "配置备份完成"
}

# 检查当前状态
check_current_status() {
    log "检查当前网络配置状态..."
    
    local current_lan=$(uci -q get network.lan.ifname)
    local dualwan_enable=$(uci -q get dualwan.common.enable)
    local wan2_exists=$(uci -q get network.wan2.ifname 2>/dev/null || echo "")
    
    log "当前LAN接口: $current_lan"
    log "Dualwan状态: $dualwan_enable"
    log "WAN2接口: ${wan2_exists:-'不存在'}"
}

# 配置3WAN网络
configure_3wan_network() {
    log "开始配置3WAN网络接口..."
    
    # 修改LAN接口，只保留eth0和eth1
    uci set network.lan.ifname='eth0 eth1' || error_exit "设置LAN接口失败"
    
    # 确保WAN接口存在
    uci set network.wan.proto='dhcp'
    uci set network.wan.mtu='1500'
    uci set network.wan.ifname='eth4'
    
    # 配置WAN2接口
    uci set network.wan2.proto='dhcp'
    uci set network.wan2.mtu='1500'
    uci set network.wan2.ifname='eth3'
    
    # 配置WAN3接口 (新增)
    uci set network.wan3='interface'
    uci set network.wan3.proto='dhcp'
    uci set network.wan3.mtu='1500'
    uci set network.wan3.ifname='eth2'
    
    # 配置WAN3的IPv6接口 (可选)
    uci set network.wan3_6='interface'
    uci set network.wan3_6.ifname='eth2'
    uci set network.wan3_6.proto='dhcpv6'
    uci set network.wan3_6.reqaddress='try'
    uci set network.wan3_6.reqprefix='auto'
    
    uci commit network || error_exit "提交网络配置失败"
    log "3WAN网络接口配置完成"
}

# 配置dualwan (扩展为支持3wan)
configure_3wan_dualwan() {
    log "配置3WAN管理功能..."
    
    # 启用dualwan功能
    uci set dualwan.common.enable='1'
    
    # 添加WAN3相关配置
    uci set dualwan.common.wan3_enable='1'
    uci set dualwan.common.wan3_link_error='1'
    
    # 设置负载均衡权重 (可根据需要调整)
    uci set dualwan.common.weight_wan1='1'
    uci set dualwan.common.weight_wan2='1'
    uci set dualwan.common.weight_wan3='1'
    
    uci commit dualwan || error_exit "提交dualwan配置失败"
    log "3WAN管理功能配置完成"
}

# 配置交换机端口
configure_switch_ports() {
    log "配置交换机端口..."
    
    # 修改交换机LAN端口配置
    uci set misc.sw_reg.sw_lan_ports='1 2'
    
    # 修改Samba网络接口配置
    uci set misc.samba.et_ifname='eth0 eth1'
    
    uci commit misc || error_exit "提交misc配置失败"
    log "交换机端口配置完成"
}

# 配置防火墙
configure_firewall() {
    log "配置防火墙规则..."
    
    # 获取当前wan zone的网络列表
    local wan_networks=$(uci -q get firewall.@zone[1].network)
    
    # 检查是否已包含wan3
    if ! echo "$wan_networks" | grep -q "wan3"; then
        uci set firewall.@zone[1].network="$wan_networks wan3"
        log "已将wan3添加到防火墙wan区域"
    else
        log "wan3已存在于防火墙配置中"
    fi
    
    # 为WAN3添加DHCP续租规则
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-DHCP-Renew-WAN3'
    uci set firewall.@rule[-1].src='wan3'
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].dest_port='68'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci set firewall.@rule[-1].family='ipv4'
    
    # 为WAN3添加ping规则
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-Ping-WAN3'
    uci set firewall.@rule[-1].src='wan3'
    uci set firewall.@rule[-1].proto='icmp'
    uci set firewall.@rule[-1].icmp_type='echo-request'
    uci set firewall.@rule[-1].family='ipv4'
    uci set firewall.@rule[-1].target='ACCEPT'
    
    uci commit firewall || error_exit "提交防火墙配置失败"
    log "防火墙配置完成"
}

# 配置DHCP
configure_dhcp() {
    log "配置DHCP服务..."
    
    # 为WAN3配置DHCP客户端设置
    uci set dhcp.wan3='dhcp'
    uci set dhcp.wan3.interface='wan3'
    uci set dhcp.wan3.ignore='1'
    
    uci commit dhcp || error_exit "提交DHCP配置失败"
    log "DHCP配置完成"
}

# 创建3WAN管理脚本
create_3wan_scripts() {
    log "创建3WAN管理脚本..."
    
    # 创建3WAN状态检查脚本
    cat > /usr/bin/3wan_status << 'EOF'
#!/bin/sh
echo "=== 3WAN状态检查 ==="
echo "WAN1 (eth4): $(ifstatus wan | jsonfilter -e '@.up')"
echo "WAN2 (eth3): $(ifstatus wan2 | jsonfilter -e '@.up')"
echo "WAN3 (eth2): $(ifstatus wan3 | jsonfilter -e '@.up')"
echo ""
echo "=== IP地址信息 ==="
ip addr show eth4 | grep "inet " || echo "WAN1: 未获取IP"
ip addr show eth3 | grep "inet " || echo "WAN2: 未获取IP"
ip addr show eth2 | grep "inet " || echo "WAN3: 未获取IP"
EOF
    chmod +x /usr/bin/3wan_status
    
    # 创建3WAN重启脚本
    cat > /usr/bin/3wan_restart << 'EOF'
#!/bin/sh
echo "重启3WAN接口..."
ifdown wan wan2 wan3
sleep 2
ifup wan wan2 wan3
echo "3WAN接口重启完成"
EOF
    chmod +x /usr/bin/3wan_restart
    
    log "3WAN管理脚本创建完成"
}

# 重启服务
restart_services() {
    log "重启相关服务..."
    
    # 重启网络服务
    /etc/init.d/network restart || log "警告: 网络服务重启失败"
    sleep 5
    
    # 重启防火墙
    /etc/init.d/firewall restart || log "警告: 防火墙重启失败"
    
    # 重启dnsmasq
    /etc/init.d/dnsmasq restart || log "警告: dnsmasq重启失败"
    
    log "服务重启完成"
}

# 验证配置
verify_config() {
    log "验证3WAN配置..."
    
    sleep 10  # 等待接口启动
    
    local wan1_status=$(ifstatus wan | jsonfilter -e '@.up' 2>/dev/null || echo "false")
    local wan2_status=$(ifstatus wan2 | jsonfilter -e '@.up' 2>/dev/null || echo "false")
    local wan3_status=$(ifstatus wan3 | jsonfilter -e '@.up' 2>/dev/null || echo "false")
    
    log "WAN1状态: $wan1_status"
    log "WAN2状态: $wan2_status" 
    log "WAN3状态: $wan3_status"
    
    if [ "$wan1_status" = "true" ] || [ "$wan2_status" = "true" ] || [ "$wan3_status" = "true" ]; then
        log "✅ 至少有一个WAN接口工作正常"
    else
        log "⚠️  警告: 所有WAN接口都未启动，请检查网线连接"
    fi
}

# 显示使用说明
show_usage() {
    cat << EOF

=== 3WAN配置完成 ===

端口分配:
- LAN口: eth0, eth1 (2个)
- WAN1: eth4 (主WAN)
- WAN2: eth3 (第二WAN)  
- WAN3: eth2 (第三WAN)

管理命令:
- 查看状态: 3wan_status
- 重启接口: 3wan_restart
- 查看路由: ip route show table all

配置文件备份位置: $BACKUP_DIR

注意事项:
1. 请确保每个WAN口都连接了网线
2. 如需恢复原配置，请使用备份文件
3. 重启路由器后配置仍然有效

EOF
}

# 主函数
main() {
    log "开始执行3WAN配置脚本"
    
    check_root
    check_current_status
    backup_config
    configure_3wan_network
    configure_3wan_dualwan
    configure_switch_ports
    configure_firewall
    configure_dhcp
    create_3wan_scripts
    restart_services
    verify_config
    show_usage
    
    log "3WAN配置脚本执行完成！"
    echo ""
    echo "🎉 3WAN配置已完成！请检查各WAN口连接状态。"
    echo "📁 配置备份: $BACKUP_DIR"
    echo "📊 查看状态: 3wan_status"
}

# 执行主函数
main "$@" 
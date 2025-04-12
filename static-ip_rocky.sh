#!/bin/bash
# Rocky Linux Static IP Configuration Script with NetworkManager Detection
# Usage: sudo ./rocky_static_ip.sh <interface> <ip_address> <gateway> <dns_servers>

set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Validate arguments
if [ $# -ne 4 ]; then
    echo "Usage: $0 <interface> <ip_address> <gateway> <dns_servers>"
    echo "Example: $0 ens192 192.168.1.100/24 192.168.1.1 8.8.8.8,8.8.4.4"
    exit 1
fi

# Detect network configuration system
if systemctl is-active --quiet NetworkManager; then
    echo "Detected NetworkManager is running"
    CONFIG_SYSTEM="networkmanager"
elif [ -f /etc/sysconfig/network-scripts/ifcfg-* ]; then
    echo "Detected legacy network-scripts configuration"
    CONFIG_SYSTEM="network-scripts"
else
    echo "ERROR: Could not determine network configuration system"
    exit 1
fi

INTERFACE=$1
IP_ADDRESS=$2
GATEWAY=$3
DNS_SERVERS=$4

configure_networkmanager() {
    echo "Configuring static IP using NetworkManager..."
    # Get the current connection name
    CONN_NAME=$(nmcli -t -f NAME,DEVICE con show | grep "$INTERFACE" | cut -d: -f1 | head -n1)

    if [ -z "$CONN_NAME" ]; then
        CONN_NAME="static-$INTERFACE"
        echo "Creating new connection profile: $CONN_NAME"
        nmcli con add con-name "$CONN_NAME" type ethernet ifname "$INTERFACE"
    fi

    # Configure static IP
    nmcli con mod "$CONN_NAME" ipv4.method manual
    nmcli con mod "$CONN_NAME" ipv4.addresses "$IP_ADDRESS"
    nmcli con mod "$CONN_NAME" ipv4.gateway "$GATEWAY"
    nmcli con mod "$CONN_NAME" ipv4.dns "$DNS_SERVERS"
    nmcli con mod "$CONN_NAME" ipv6.method disabled

    # Restart the connection
    nmcli con down "$CONN_NAME"
    nmcli con up "$CONN_NAME"
}

configure_network_scripts() {
    echo "Configuring static IP using network-scripts..."
    # Backup existing config
    if [ -f /etc/sysconfig/network-scripts/ifcfg-$INTERFACE ]; then
        cp /etc/sysconfig/network-scripts/ifcfg-$INTERFACE /etc/sysconfig/network-scripts/ifcfg-$INTERFACE.backup_$(date +%Y%m%d%H%M%S)
    fi

    # Extract IP and netmask
    IP=${IP_ADDRESS%%/*}
    PREFIX=${IP_ADDRESS##*/}
    NETMASK=$(ipcalc -m $IP/$PREFIX | cut -d= -f2)

    # Create new config
    cat > /etc/sysconfig/network-scripts/ifcfg-$INTERFACE <<EOF
DEVICE=$INTERFACE
BOOTPROTO=none
ONBOOT=yes
IPADDR=$IP
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=${DNS_SERVERS%%,*}
EOF

    # Add secondary DNS if provided
    if [[ $DNS_SERVERS == *,* ]]; then
        echo "DNS2=${DNS_SERVERS#*,}" >> /etc/sysconfig/network-scripts/ifcfg-$INTERFACE
    fi

    # Restart network
    systemctl restart network
}

case $CONFIG_SYSTEM in
    networkmanager)
        configure_networkmanager
        ;;
    network-scripts)
        configure_network_scripts
        ;;
    *)
        echo "Unsupported network configuration system"
        exit 1
        ;;
esac

# Verify the configuration
echo -e "\nVerifying new network settings..."
ip addr show $INTERFACE
echo -e "\nNetwork configuration applied successfully using $CONFIG_SYSTEM."

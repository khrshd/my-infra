#!/bin/bash
# Ubuntu Static IP Configuration Script with Netplan Detection
# Usage: sudo ./ubuntu_static_ip.sh <interface> <ip_address> <gateway> <dns_servers>

set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Validate arguments
if [ $# -ne 4 ]; then
    echo "Usage: $0 <interface> <ip_address> <gateway> <dns_servers>"
    echo "Example: $0 ens33 192.168.1.100/24 192.168.1.1 8.8.8.8,8.8.4.4"
    exit 1
fi

# Detect network configuration system
if [ -d /etc/netplan ] && command -v netplan &>/dev/null; then
    echo "Detected Netplan network configuration system"
    CONFIG_SYSTEM="netplan"
elif systemctl is-active --quiet NetworkManager; then
    echo "Detected NetworkManager is running"
    CONFIG_SYSTEM="networkmanager"
elif [ -f /etc/network/interfaces ]; then
    echo "Detected legacy ifupdown network configuration"
    CONFIG_SYSTEM="ifupdown"
else
    echo "ERROR: Could not determine network configuration system"
    exit 1
fi

INTERFACE=$1
IP_ADDRESS=$2
GATEWAY=$3
DNS_SERVERS=$4

configure_netplan() {
    echo "Configuring static IP using Netplan..."
    # Backup existing netplan configuration
    echo "Backing up current Netplan configuration..."
    cp /etc/netplan/*.yaml /etc/netplan/backup_$(date +%Y%m%d%H%M%S).yaml 2>/dev/null || true

    # Create new netplan configuration
    cat > /etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses: [$IP_ADDRESS]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [${DNS_SERVERS//,/ }]
EOF

    # Apply the new configuration
    netplan apply
}

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

configure_ifupdown() {
    echo "Configuring static IP using ifupdown..."
    # Backup existing interfaces file
    cp /etc/network/interfaces /etc/network/interfaces.backup_$(date +%Y%m%d%H%M%S)

    # Configure static IP
    cat > /etc/network/interfaces <<EOF
# The loopback network interface
auto lo
iface lo inet loopback

# Primary network interface
auto $INTERFACE
iface $INTERFACE inet static
    address ${IP_ADDRESS%%/*}
    netmask $(ipcalc -m $IP_ADDRESS | cut -d= -f2)
    gateway $GATEWAY
    dns-nameservers ${DNS_SERVERS//,/ }
EOF

    # Restart networking
    systemctl restart networking
}

case $CONFIG_SYSTEM in
    netplan)
        configure_netplan
        ;;
    networkmanager)
        configure_networkmanager
        ;;
    ifupdown)
        configure_ifupdown
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

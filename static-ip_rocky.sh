#!/bin/bash
# Rocky Linux 9 Static IP Configuration Script (NetworkManager focused)
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

INTERFACE=$1
IP_ADDRESS=$2
GATEWAY=$3
DNS_SERVERS=$4

# Function to check if NetworkManager is active and working
is_network_manager_active() {
    if command -v nmcli >/dev/null && systemctl is-active NetworkManager >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to configure using NetworkManager
configure_networkmanager() {
    echo "Configuring static IP using NetworkManager..."
    
    # Get the current connection name (handle cases where grep finds nothing)
    CONN_NAME=$(nmcli -t -f NAME,DEVICE con show | grep ":${INTERFACE}$" | cut -d: -f1 | head -n1)

    if [ -z "$CONN_NAME" ]; then
        CONN_NAME="static-$INTERFACE"
        echo "Creating new connection profile: $CONN_NAME"
        if ! nmcli con add con-name "$CONN_NAME" type ethernet ifname "$INTERFACE"; then
            echo "Failed to create new connection profile"
            return 1
        fi
    fi

    # Configure static IP
    if ! nmcli con mod "$CONN_NAME" ipv4.method manual \
        ipv4.addresses "$IP_ADDRESS" \
        ipv4.gateway "$GATEWAY" \
        ipv4.dns "$DNS_SERVERS" \
        ipv6.method disabled; then
        echo "Failed to modify connection settings"
        return 1
    fi

    # Restart the connection
    echo "Restarting network connection..."
    nmcli con down "$CONN_NAME" || true
    if ! nmcli con up "$CONN_NAME"; then
        echo "Failed to bring up connection"
        return 1
    fi

    return 0
}

# Function to configure using legacy network-scripts
configure_legacy() {
    echo "Configuring static IP using legacy network-scripts..."
    
    # Backup existing config
    if [ -f "/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}" ]; then
        cp "/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}" \
           "/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}.backup_$(date +%Y%m%d%H%M%S)"
    fi

    # Extract IP and prefix
    IP=${IP_ADDRESS%%/*}
    PREFIX=${IP_ADDRESS##*/}

    # Create new config
    cat > "/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}" <<EOF
DEVICE=${INTERFACE}
BOOTPROTO=none
ONBOOT=yes
IPADDR=${IP}
PREFIX=${PREFIX}
GATEWAY=${GATEWAY}
DNS1=${DNS_SERVERS%%,*}
EOF

    # Add secondary DNS if provided
    if [[ $DNS_SERVERS == *,* ]]; then
        echo "DNS2=${DNS_SERVERS#*,}" >> "/etc/sysconfig/network-scripts/ifcfg-${INTERFACE}"
    fi

    # Restart network
    echo "Restarting network service..."
    if systemctl restart NetworkManager; then
        return 0
    elif systemctl restart network; then
        return 0
    else
        echo "Failed to restart network services"
        return 1
    fi
}

# Main execution
echo "Starting network configuration..."

# Verify interface exists
if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "Error: Network interface $INTERFACE not found!"
    exit 1
fi

# Try NetworkManager first if available
if is_network_manager_active; then
    if configure_networkmanager; then
        CONFIG_METHOD="NetworkManager"
    else
        echo "NetworkManager configuration failed, trying legacy method..."
        if configure_legacy; then
            CONFIG_METHOD="legacy network-scripts"
        else
            echo "All configuration methods failed!"
            exit 1
        fi
    fi
else
    if configure_legacy; then
        CONFIG_METHOD="legacy network-scripts"
    else
        echo "Legacy configuration failed!"
        exit 1
    fi
fi

# Verification
echo -e "\nVerification:"
echo "Interface $INTERFACE configuration:"
ip addr show "$INTERFACE"
echo -e "\nRouting table:"
ip route show
echo -e "\nDNS configuration:"
cat /etc/resolv.conf

echo -e "\nStatic IP configuration completed successfully using $CONFIG_METHOD!"

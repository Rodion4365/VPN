#!/bin/bash

#############################################
# WireGuard Installation Script for Selectel
# Optimized for minimal resource usage
# Compatible with Docker
#############################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
WG_CONFIG="/etc/wireguard/wg0.conf"
WG_PORT="${WG_PORT:-51820}"
WG_NET="10.66.66.0/24"
WG_SERVER_IP="10.66.66.1"

print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

print_message "========================================"
print_message "WireGuard Installation Starting..."
print_message "========================================"
echo ""

# Detect OS
detect_os() {
    if [[ -e /etc/debian_version ]]; then
        OS="ubuntu"
        print_message "Detected Ubuntu/Debian system"
    elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
        OS="centos"
        print_message "Detected CentOS/RHEL system"
    else
        print_error "Unsupported OS"
        exit 1
    fi
}

# Install WireGuard
install_wireguard() {
    print_message "Installing WireGuard..."

    if [[ "$OS" == "ubuntu" ]]; then
        apt update
        apt install -y wireguard wireguard-tools qrencode iptables
    elif [[ "$OS" == "centos" ]]; then
        yum install -y epel-release
        yum install -y wireguard-tools qrencode iptables
    fi

    print_message "WireGuard installed successfully"
}

# Get server's public IP
get_server_ip() {
    SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || wget -qO- -4 ifconfig.me 2>/dev/null || echo "")

    if [[ -z "$SERVER_IP" ]]; then
        print_warning "Could not detect public IP automatically"
        read -p "Enter your server's public IP: " SERVER_IP
    fi

    print_message "Server public IP: $SERVER_IP"
}

# Get network interface
get_network_interface() {
    NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    if [[ -z "$NIC" ]]; then
        print_error "Could not detect network interface"
        exit 1
    fi

    print_message "Network interface: $NIC"
}

# Generate server keys
generate_server_keys() {
    print_message "Generating server keys..."

    cd /etc/wireguard/
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    chmod 600 server_private.key

    SERVER_PRIV_KEY=$(cat server_private.key)
    SERVER_PUB_KEY=$(cat server_public.key)

    print_message "Server keys generated"
}

# Create server configuration
create_server_config() {
    print_message "Creating WireGuard server configuration..."

    cat > ${WG_CONFIG} <<EOF
# WireGuard Server Configuration
# Generated on $(date)

[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV_KEY}

# Firewall rules
PostUp = iptables -I FORWARD -i wg0 -j ACCEPT
PostUp = iptables -I FORWARD -o wg0 -j ACCEPT
PostUp = iptables -I INPUT -i wg0 -j ACCEPT
PostUp = iptables -I OUTPUT -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${NIC} -j MASQUERADE

# Docker compatibility rules
PostUp = iptables -I DOCKER-USER -i wg0 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I DOCKER-USER -o wg0 -j ACCEPT 2>/dev/null || true

PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D INPUT -i wg0 -j ACCEPT
PostDown = iptables -D OUTPUT -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${NIC} -j MASQUERADE

PostDown = iptables -D DOCKER-USER -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D DOCKER-USER -o wg0 -j ACCEPT 2>/dev/null || true

# Clients will be added below by manage-wireguard.sh
EOF

    chmod 600 ${WG_CONFIG}
    print_message "Server configuration created"
}

# Enable IP forwarding
enable_ip_forwarding() {
    print_message "Enabling IP forwarding..."

    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
    sysctl -p /etc/sysctl.d/99-wireguard.conf

    print_message "IP forwarding enabled"
}

# Configure firewall
configure_firewall() {
    print_message "Configuring firewall..."

    # Allow WireGuard port
    iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT

    # Save iptables rules
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
    elif [[ -f /etc/debian_version ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    print_message "Firewall configured"
}

# Enable and start WireGuard
start_wireguard() {
    print_message "Starting WireGuard..."

    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0

    sleep 2

    if systemctl is-active --quiet wg-quick@wg0; then
        print_message "WireGuard started successfully"
    else
        print_error "Failed to start WireGuard"
        systemctl status wg-quick@wg0
        exit 1
    fi
}

# Save configuration info
save_config_info() {
    cat > /etc/wireguard/server_info.txt <<EOF
WireGuard Server Configuration
===============================
Server Public IP: ${SERVER_IP}
Server Public Key: ${SERVER_PUB_KEY}
Listen Port: ${WG_PORT}
VPN Network: ${WG_NET}
Server VPN IP: ${WG_SERVER_IP}

Network Interface: ${NIC}

Installation Date: $(date)
EOF

    print_message "Configuration info saved to /etc/wireguard/server_info.txt"
}

# Main installation flow
main() {
    detect_os
    get_server_ip
    get_network_interface
    install_wireguard
    generate_server_keys
    create_server_config
    enable_ip_forwarding
    configure_firewall
    start_wireguard
    save_config_info

    echo ""
    print_message "========================================"
    print_message "WireGuard Installation Complete!"
    print_message "========================================"
    echo ""
    print_message "Server Information:"
    print_message "  Public IP: ${SERVER_IP}"
    print_message "  Listen Port: ${WG_PORT}"
    print_message "  VPN Network: ${WG_NET}"
    echo ""
    print_message "Next steps:"
    print_message "1. Use manage-wireguard.sh to add clients"
    print_message "2. Open port ${WG_PORT}/UDP in Selectel firewall"
    print_message "3. Check status: systemctl status wg-quick@wg0"
    print_message "4. View interface: wg show"
    echo ""
    print_message "Resource usage:"
    print_message "  WireGuard uses <1% CPU and ~10-20 MB RAM"
    print_message "  Perfect for running alongside your projects"
    echo ""
}

# Run main function
main

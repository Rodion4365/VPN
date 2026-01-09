#!/bin/bash

#############################################
# OpenVPN Installation Script for Selectel
# Optimized for minimal resource usage
#############################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
OPENVPN_DIR="/etc/openvpn"
EASY_RSA_DIR="/etc/openvpn/easy-rsa"
SERVER_CONFIG="${OPENVPN_DIR}/server.conf"
VPN_PORT="${VPN_PORT:-1194}"
VPN_PROTOCOL="${VPN_PROTOCOL:-udp}"
VPN_NETWORK="10.8.0.0"
VPN_NETMASK="255.255.255.0"

# Function to print colored messages
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

# Detect OS
detect_os() {
    if [[ -e /etc/debian_version ]]; then
        OS="debian"
        print_message "Detected Debian/Ubuntu system"
    elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
        OS="centos"
        print_message "Detected CentOS/RHEL system"
    else
        print_error "Unsupported OS. This script supports Debian/Ubuntu and CentOS/RHEL"
        exit 1
    fi
}

# Install required packages
install_packages() {
    print_message "Installing required packages..."

    if [[ "$OS" == "debian" ]]; then
        apt-get update
        apt-get install -y openvpn easy-rsa iptables openssl ca-certificates
    elif [[ "$OS" == "centos" ]]; then
        yum install -y epel-release
        yum install -y openvpn easy-rsa iptables openssl
    fi

    print_message "Packages installed successfully"
}

# Setup Easy-RSA for certificate management
setup_easy_rsa() {
    print_message "Setting up Easy-RSA..."

    # Create Easy-RSA directory
    make-cadir ${EASY_RSA_DIR}
    cd ${EASY_RSA_DIR}

    # Configure Easy-RSA vars
    cat > ${EASY_RSA_DIR}/vars <<EOF
set_var EASYRSA_REQ_COUNTRY    "RU"
set_var EASYRSA_REQ_PROVINCE   "Moscow"
set_var EASYRSA_REQ_CITY       "Moscow"
set_var EASYRSA_REQ_ORG        "Personal VPN"
set_var EASYRSA_REQ_EMAIL      "admin@example.com"
set_var EASYRSA_REQ_OU         "VPN Server"
set_var EASYRSA_KEY_SIZE       2048
set_var EASYRSA_CA_EXPIRE      3650
set_var EASYRSA_CERT_EXPIRE    3650
EOF

    # Initialize PKI
    ./easyrsa init-pki

    # Build CA
    print_message "Building Certificate Authority..."
    ./easyrsa --batch build-ca nopass

    # Generate server certificate
    print_message "Generating server certificate..."
    ./easyrsa --batch build-server-full server nopass

    # Generate DH parameters (2048 bit for balance between security and performance)
    print_message "Generating Diffie-Hellman parameters (this may take a while)..."
    ./easyrsa gen-dh

    # Generate TLS-Auth key for additional security
    print_message "Generating TLS-Auth key..."
    openvpn --genkey secret ${OPENVPN_DIR}/ta.key

    # Copy certificates to OpenVPN directory
    cp pki/ca.crt ${OPENVPN_DIR}/
    cp pki/issued/server.crt ${OPENVPN_DIR}/
    cp pki/private/server.key ${OPENVPN_DIR}/
    cp pki/dh.pem ${OPENVPN_DIR}/

    print_message "Easy-RSA setup completed"
}

# Create optimized server configuration
create_server_config() {
    print_message "Creating optimized server configuration..."

    # Get server's public IP
    SERVER_IP=$(curl -s ifconfig.me || wget -qO- ifconfig.me || echo "YOUR_SERVER_IP")

    cat > ${SERVER_CONFIG} <<EOF
# OpenVPN Server Configuration
# Optimized for minimal resource usage

# Network settings
port ${VPN_PORT}
proto ${VPN_PROTOCOL}
dev tun

# Certificates and keys
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0

# Network topology
server ${VPN_NETWORK} ${VPN_NETMASK}
topology subnet

# IP pool persistence
ifconfig-pool-persist ipp.txt

# Push routes to clients
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"

# Client configuration
client-to-client
keepalive 10 120

# Security settings
cipher AES-128-GCM
auth SHA256
tls-version-min 1.2

# Performance optimization
# Reduce CPU usage by using smaller key sizes and efficient ciphers
comp-lzo no
sndbuf 393216
rcvbuf 393216
push "sndbuf 393216"
push "rcvbuf 393216"

# Reduce memory usage
max-clients 10
txqueuelen 1000

# Process priority (nice value) to not interfere with other services
nice 10

# Privileges
user nobody
group nogroup
persist-key
persist-tun

# Logging (minimal for performance)
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/openvpn.log
verb 3
mute 20

# Explicit exit notify
explicit-exit-notify 1
EOF

    # Create log directory
    mkdir -p /var/log/openvpn

    print_message "Server configuration created at ${SERVER_CONFIG}"
    print_message "Server IP detected: ${SERVER_IP}"
}

# Configure firewall and routing
configure_firewall() {
    print_message "Configuring firewall and routing..."

    # Enable IP forwarding
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    sysctl -p

    # Get the network interface
    NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    # Configure iptables
    iptables -t nat -A POSTROUTING -s ${VPN_NETWORK}/24 -o ${NIC} -j MASQUERADE
    iptables -A INPUT -p ${VPN_PROTOCOL} --dport ${VPN_PORT} -j ACCEPT
    iptables -A FORWARD -s ${VPN_NETWORK}/24 -j ACCEPT
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Save iptables rules
    if [[ "$OS" == "debian" ]]; then
        apt-get install -y iptables-persistent
        netfilter-persistent save
    elif [[ "$OS" == "centos" ]]; then
        service iptables save
    fi

    print_message "Firewall configured successfully"
}

# Enable and start OpenVPN service
enable_service() {
    print_message "Enabling OpenVPN service..."

    systemctl enable openvpn@server
    systemctl start openvpn@server

    # Check service status
    if systemctl is-active --quiet openvpn@server; then
        print_message "OpenVPN service started successfully"
    else
        print_error "Failed to start OpenVPN service"
        systemctl status openvpn@server
        exit 1
    fi
}

# Create client management script placeholder
create_client_script() {
    print_message "Creating client management script..."

    cat > /usr/local/bin/openvpn-client <<'EOF'
#!/bin/bash
# Client management will be handled by manage-clients.sh
echo "Please use manage-clients.sh script for client management"
exit 0
EOF

    chmod +x /usr/local/bin/openvpn-client
}

# Main installation flow
main() {
    print_message "Starting OpenVPN installation..."
    print_message "Configuration: Port=${VPN_PORT}, Protocol=${VPN_PROTOCOL}"

    detect_os
    install_packages
    setup_easy_rsa
    create_server_config
    configure_firewall
    enable_service
    create_client_script

    print_message "========================================"
    print_message "OpenVPN installation completed!"
    print_message "========================================"
    print_message ""
    print_message "Next steps:"
    print_message "1. Use manage-clients.sh to create client profiles"
    print_message "2. Configure your firewall to allow port ${VPN_PORT}/${VPN_PROTOCOL}"
    print_message "3. Check service status: systemctl status openvpn@server"
    print_message "4. View logs: tail -f /var/log/openvpn/openvpn.log"
    print_message ""
    print_message "Resource optimization enabled:"
    print_message "- Process priority set to 'nice 10' (lower priority)"
    print_message "- Maximum 10 concurrent clients"
    print_message "- Efficient AES-128-GCM cipher for low CPU usage"
    print_message "- Optimized buffer sizes for network performance"
}

# Run main function
main

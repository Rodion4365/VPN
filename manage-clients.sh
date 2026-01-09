#!/bin/bash

#############################################
# OpenVPN Client Management Script
# Add, remove, and list VPN clients
#############################################

set -e

# Configuration
OPENVPN_DIR="/etc/openvpn"
EASY_RSA_DIR="/etc/openvpn/easy-rsa"
CLIENT_DIR="${HOME}/openvpn-clients"
SERVER_IP=$(curl -s ifconfig.me || wget -qO- ifconfig.me || echo "YOUR_SERVER_IP")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR]${NC} This script must be run as root"
   exit 1
fi

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

# Create client directory if it doesn't exist
mkdir -p ${CLIENT_DIR}

# Function to add a new client
add_client() {
    local CLIENT_NAME=$1

    if [[ -z "$CLIENT_NAME" ]]; then
        print_error "Client name cannot be empty"
        echo "Usage: $0 add <client-name>"
        exit 1
    fi

    # Check if client already exists
    if [[ -f "${EASY_RSA_DIR}/pki/issued/${CLIENT_NAME}.crt" ]]; then
        print_error "Client '${CLIENT_NAME}' already exists"
        exit 1
    fi

    print_message "Creating client certificate for '${CLIENT_NAME}'..."

    # Generate client certificate
    cd ${EASY_RSA_DIR}
    ./easyrsa --batch build-client-full ${CLIENT_NAME} nopass

    # Create client configuration file
    local CLIENT_CONFIG="${CLIENT_DIR}/${CLIENT_NAME}.ovpn"

    print_message "Generating client configuration file..."

    cat > ${CLIENT_CONFIG} <<EOF
# OpenVPN Client Configuration
# Client: ${CLIENT_NAME}
# Generated: $(date)

client
dev tun
proto udp
remote ${SERVER_IP} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-128-GCM
auth SHA256
key-direction 1
verb 3
mute 20

# Performance optimization
comp-lzo no
sndbuf 393216
rcvbuf 393216

<ca>
EOF

    # Append CA certificate
    cat ${OPENVPN_DIR}/ca.crt >> ${CLIENT_CONFIG}

    cat >> ${CLIENT_CONFIG} <<EOF
</ca>

<cert>
EOF

    # Append client certificate
    sed -ne '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' ${EASY_RSA_DIR}/pki/issued/${CLIENT_NAME}.crt >> ${CLIENT_CONFIG}

    cat >> ${CLIENT_CONFIG} <<EOF
</cert>

<key>
EOF

    # Append client private key
    cat ${EASY_RSA_DIR}/pki/private/${CLIENT_NAME}.key >> ${CLIENT_CONFIG}

    cat >> ${CLIENT_CONFIG} <<EOF
</key>

<tls-auth>
EOF

    # Append TLS-Auth key
    cat ${OPENVPN_DIR}/ta.key >> ${CLIENT_CONFIG}

    cat >> ${CLIENT_CONFIG} <<EOF
</tls-auth>
EOF

    print_message "========================================"
    print_message "Client '${CLIENT_NAME}' created successfully!"
    print_message "========================================"
    print_message ""
    print_message "Configuration file: ${CLIENT_CONFIG}"
    print_message ""
    print_message "How to use:"
    print_message "1. Download the file: scp root@${SERVER_IP}:${CLIENT_CONFIG} ."
    print_message "2. Import it to your OpenVPN client"
    print_message "3. Connect to the VPN"
    print_message ""
}

# Function to remove a client
remove_client() {
    local CLIENT_NAME=$1

    if [[ -z "$CLIENT_NAME" ]]; then
        print_error "Client name cannot be empty"
        echo "Usage: $0 remove <client-name>"
        exit 1
    fi

    # Check if client exists
    if [[ ! -f "${EASY_RSA_DIR}/pki/issued/${CLIENT_NAME}.crt" ]]; then
        print_error "Client '${CLIENT_NAME}' does not exist"
        exit 1
    fi

    print_warning "Revoking client certificate for '${CLIENT_NAME}'..."

    # Revoke the certificate
    cd ${EASY_RSA_DIR}
    ./easyrsa --batch revoke ${CLIENT_NAME}
    ./easyrsa gen-crl

    # Copy CRL to OpenVPN directory
    cp ${EASY_RSA_DIR}/pki/crl.pem ${OPENVPN_DIR}/

    # Update server configuration to use CRL (if not already configured)
    if ! grep -q "^crl-verify" ${OPENVPN_DIR}/server.conf; then
        echo "crl-verify crl.pem" >> ${OPENVPN_DIR}/server.conf
        systemctl restart openvpn@server
        print_message "Server restarted to apply CRL"
    fi

    # Remove client configuration file
    if [[ -f "${CLIENT_DIR}/${CLIENT_NAME}.ovpn" ]]; then
        rm -f "${CLIENT_DIR}/${CLIENT_NAME}.ovpn"
    fi

    print_message "========================================"
    print_message "Client '${CLIENT_NAME}' revoked successfully!"
    print_message "========================================"
}

# Function to list all clients
list_clients() {
    print_message "Active OpenVPN clients:"
    print_message "========================================"

    if [[ ! -d "${EASY_RSA_DIR}/pki/issued" ]]; then
        print_warning "No clients found"
        return
    fi

    local COUNT=0
    for cert in ${EASY_RSA_DIR}/pki/issued/*.crt; do
        if [[ -f "$cert" ]]; then
            local CLIENT_NAME=$(basename "$cert" .crt)
            # Skip server certificate
            if [[ "$CLIENT_NAME" != "server" ]]; then
                COUNT=$((COUNT + 1))
                local EXPIRY=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
                echo -e "${BLUE}${COUNT}.${NC} ${CLIENT_NAME} (expires: ${EXPIRY})"
            fi
        fi
    done

    if [[ $COUNT -eq 0 ]]; then
        print_warning "No clients found"
    else
        print_message "========================================"
        print_message "Total clients: ${COUNT}"
    fi
}

# Function to show connected clients
show_connected() {
    print_message "Currently connected clients:"
    print_message "========================================"

    if [[ ! -f /var/log/openvpn/openvpn-status.log ]]; then
        print_warning "Status log not found"
        return
    fi

    # Parse status log
    awk '/^CLIENT_LIST/ {print $2, $3, $4, $5}' /var/log/openvpn/openvpn-status.log | while read -r client ip port connected; do
        if [[ -n "$client" ]]; then
            echo -e "${BLUE}Client:${NC} $client"
            echo -e "${BLUE}  IP:${NC} $ip"
            echo -e "${BLUE}  Connected since:${NC} $connected"
            echo ""
        fi
    done
}

# Function to show help
show_help() {
    cat <<EOF
OpenVPN Client Management Script

Usage:
    $0 add <client-name>       - Add a new client
    $0 remove <client-name>    - Remove and revoke a client
    $0 list                    - List all clients
    $0 connected               - Show currently connected clients
    $0 help                    - Show this help message

Examples:
    $0 add laptop
    $0 add phone-android
    $0 remove old-device
    $0 list
    $0 connected

Client configuration files are saved to: ${CLIENT_DIR}
EOF
}

# Main script logic
case "${1:-}" in
    add)
        add_client "$2"
        ;;
    remove|revoke)
        remove_client "$2"
        ;;
    list)
        list_clients
        ;;
    connected|status)
        show_connected
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        print_error "Invalid command"
        echo ""
        show_help
        exit 1
        ;;
esac

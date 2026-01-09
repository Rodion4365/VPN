#!/bin/bash

#############################################
# WireGuard Client Management Script
# Add, remove, list clients
#############################################

set -e

# Configuration
WG_CONFIG="/etc/wireguard/wg0.conf"
WG_SERVER_INFO="/etc/wireguard/server_info.txt"
CLIENT_DIR="/root/wireguard-clients"
WG_NET="10.66.66"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR]${NC} This script must be run as root"
   exit 1
fi

# Create client directory
mkdir -p ${CLIENT_DIR}

print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get server info
get_server_info() {
    if [[ ! -f ${WG_SERVER_INFO} ]]; then
        print_error "Server info file not found. Please run install-wireguard.sh first"
        exit 1
    fi

    SERVER_PUB_KEY=$(grep "Server Public Key:" ${WG_SERVER_INFO} | awk '{print $4}')
    SERVER_IP=$(grep "Server Public IP:" ${WG_SERVER_INFO} | awk '{print $4}')
    WG_PORT=$(grep "Listen Port:" ${WG_SERVER_INFO} | awk '{print $3}')
}

# Get next available IP
get_next_ip() {
    LAST_IP=$(grep -oP "${WG_NET}\.\K[0-9]+" ${WG_CONFIG} | sort -n | tail -1)

    if [[ -z "$LAST_IP" ]]; then
        NEXT_IP="${WG_NET}.2"
    else
        NEXT_IP="${WG_NET}.$((LAST_IP + 1))"
    fi

    # Check if IP would exceed limit
    if [[ $((LAST_IP + 1)) -gt 254 ]]; then
        print_error "Maximum number of clients (253) reached"
        exit 1
    fi
}

# Add a new client
add_client() {
    local CLIENT_NAME=$1

    if [[ -z "$CLIENT_NAME" ]]; then
        print_error "Client name cannot be empty"
        echo "Usage: $0 add <client-name>"
        exit 1
    fi

    # Check if client already exists
    if grep -q "# Client: ${CLIENT_NAME}" ${WG_CONFIG}; then
        print_error "Client '${CLIENT_NAME}' already exists"
        exit 1
    fi

    get_server_info
    get_next_ip

    print_message "Creating client '${CLIENT_NAME}'..."
    print_message "Assigning IP: ${NEXT_IP}"

    # Generate client keys
    CLIENT_PRIV_KEY=$(wg genkey)
    CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
    CLIENT_PRESHARED_KEY=$(wg genpsk)

    # Add client to server config
    cat >> ${WG_CONFIG} <<EOF

# Client: ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${NEXT_IP}/32
EOF

    # Create client config file
    local CLIENT_CONFIG="${CLIENT_DIR}/${CLIENT_NAME}.conf"

    cat > ${CLIENT_CONFIG} <<EOF
# WireGuard Client Configuration
# Client: ${CLIENT_NAME}
# Generated: $(date)

[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${NEXT_IP}/24
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    chmod 600 ${CLIENT_CONFIG}

    # Reload WireGuard
    wg syncconf wg0 <(wg-quick strip wg0)

    print_message "========================================"
    print_message "Client '${CLIENT_NAME}' created successfully!"
    print_message "========================================"
    echo ""
    print_message "Client IP: ${NEXT_IP}"
    print_message "Config file: ${CLIENT_CONFIG}"
    echo ""
    print_message "To download the config:"
    print_message "  scp root@${SERVER_IP}:${CLIENT_CONFIG} ."
    echo ""
    print_message "Or scan QR code (on this server run):"
    print_message "  $0 qr ${CLIENT_NAME}"
    echo ""
}

# Remove a client
remove_client() {
    local CLIENT_NAME=$1

    if [[ -z "$CLIENT_NAME" ]]; then
        print_error "Client name cannot be empty"
        echo "Usage: $0 remove <client-name>"
        exit 1
    fi

    # Check if client exists
    if ! grep -q "# Client: ${CLIENT_NAME}" ${WG_CONFIG}; then
        print_error "Client '${CLIENT_NAME}' does not exist"
        exit 1
    fi

    print_warning "Removing client '${CLIENT_NAME}'..."

    # Remove client from config
    sed -i "/# Client: ${CLIENT_NAME}/,/^$/d" ${WG_CONFIG}

    # Remove client config file
    rm -f "${CLIENT_DIR}/${CLIENT_NAME}.conf"

    # Reload WireGuard
    wg syncconf wg0 <(wg-quick strip wg0)

    print_message "========================================"
    print_message "Client '${CLIENT_NAME}' removed successfully!"
    print_message "========================================"
}

# List all clients
list_clients() {
    print_message "WireGuard Clients:"
    print_message "========================================"

    if ! grep -q "# Client:" ${WG_CONFIG}; then
        print_warning "No clients found"
        return
    fi

    local COUNT=0
    while IFS= read -r line; do
        if [[ $line =~ ^#\ Client:\ (.+)$ ]]; then
            COUNT=$((COUNT + 1))
            CLIENT_NAME="${BASH_REMATCH[1]}"

            # Get client IP
            read -r peer_line
            if [[ $peer_line =~ AllowedIPs\ =\ ([0-9.]+) ]]; then
                CLIENT_IP="${BASH_REMATCH[1]}"
            fi

            echo -e "${BLUE}${COUNT}.${NC} ${CLIENT_NAME} (${CLIENT_IP})"
        fi
    done < <(grep -A 2 "# Client:" ${WG_CONFIG})

    if [[ $COUNT -eq 0 ]]; then
        print_warning "No clients found"
    else
        print_message "========================================"
        print_message "Total clients: ${COUNT}"
    fi
}

# Show QR code for client
show_qr() {
    local CLIENT_NAME=$1

    if [[ -z "$CLIENT_NAME" ]]; then
        print_error "Client name cannot be empty"
        echo "Usage: $0 qr <client-name>"
        exit 1
    fi

    local CLIENT_CONFIG="${CLIENT_DIR}/${CLIENT_NAME}.conf"

    if [[ ! -f ${CLIENT_CONFIG} ]]; then
        print_error "Client '${CLIENT_NAME}' does not exist"
        exit 1
    fi

    print_message "QR Code for client '${CLIENT_NAME}':"
    echo ""
    qrencode -t ansiutf8 < ${CLIENT_CONFIG}
    echo ""
    print_message "Scan this QR code with WireGuard app on your mobile device"
}

# Show connected clients
show_connected() {
    print_message "Currently connected clients:"
    print_message "========================================"

    wg show wg0 | grep -E "peer:|endpoint:|latest handshake:|transfer:" | \
    awk '
    /peer:/ {peer=$2}
    /endpoint:/ {endpoint=$2}
    /latest handshake:/ {handshake=$3" "$4" "$5" "$6}
    /transfer:/ {
        print "Peer: " peer
        print "  Endpoint: " endpoint
        print "  Handshake: " handshake
        print "  Transfer: " $2 " received, " $4 " sent"
        print ""
    }
    '
}

# Show help
show_help() {
    cat <<EOF
WireGuard Client Management Script

Usage:
    $0 add <client-name>       - Add a new client
    $0 remove <client-name>    - Remove a client
    $0 list                    - List all clients
    $0 qr <client-name>        - Show QR code for client
    $0 connected               - Show connected clients
    $0 help                    - Show this help message

Examples:
    $0 add laptop
    $0 add phone-iphone
    $0 qr laptop
    $0 remove old-device
    $0 list
    $0 connected

Client configurations are saved to: ${CLIENT_DIR}

For mobile devices:
    1. Install WireGuard app from App Store or Play Store
    2. Run: $0 qr <client-name>
    3. Scan the QR code with the app

For desktop:
    1. Download config: scp root@SERVER_IP:${CLIENT_DIR}/<client-name>.conf .
    2. Import into WireGuard app
EOF
}

# Main script logic
case "${1:-}" in
    add)
        add_client "$2"
        ;;
    remove|delete)
        remove_client "$2"
        ;;
    list|ls)
        list_clients
        ;;
    qr|qrcode)
        show_qr "$2"
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

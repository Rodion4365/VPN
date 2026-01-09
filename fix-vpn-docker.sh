#!/bin/bash

#############################################
# OpenVPN Docker Compatibility Fix
# Fixes VPN when Docker is blocking traffic
#############################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}OpenVPN Docker Compatibility Fix${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR]${NC} This script must be run as root"
   exit 1
fi

# Detect network interface
NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
echo -e "${GREEN}[INFO]${NC} Network interface: $NIC"
echo ""

# Step 1: Enable IP forwarding
echo -e "${YELLOW}[1] Enabling IP forwarding...${NC}"
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn.conf
sysctl -p /etc/sysctl.d/99-openvpn.conf
echo -e "${GREEN}✓${NC} IP forwarding enabled"
echo ""

# Step 2: Fix Docker iptables rules
echo -e "${YELLOW}[2] Fixing Docker iptables rules...${NC}"

# Clear DOCKER-USER chain
iptables -F DOCKER-USER 2>/dev/null || true

# Add VPN rules at the beginning of DOCKER-USER
iptables -I DOCKER-USER 1 -i tun0 -j ACCEPT
iptables -I DOCKER-USER 1 -o tun0 -j ACCEPT
iptables -A DOCKER-USER -j RETURN

echo -e "${GREEN}✓${NC} Docker rules fixed"
echo ""

# Step 3: Clear and recreate FORWARD rules
echo -e "${YELLOW}[3] Configuring FORWARD chain...${NC}"

# Remove old VPN rules from FORWARD
iptables -D FORWARD -s 10.8.0.0/24 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -d 10.8.0.0/24 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# Add VPN rules at the very beginning (before Docker rules)
iptables -I FORWARD 1 -i tun0 -j ACCEPT
iptables -I FORWARD 2 -o tun0 -j ACCEPT
iptables -I FORWARD 3 -i tun0 -o $NIC -j ACCEPT

echo -e "${GREEN}✓${NC} FORWARD rules configured"
echo ""

# Step 4: Fix INPUT/OUTPUT chains
echo -e "${YELLOW}[4] Configuring INPUT/OUTPUT chains...${NC}"

# Allow OpenVPN port
iptables -D INPUT -p udp --dport 1194 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p udp --dport 1194 -j ACCEPT

# Allow traffic on tun0
iptables -D INPUT -i tun0 -j ACCEPT 2>/dev/null || true
iptables -D OUTPUT -o tun0 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -i tun0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

echo -e "${GREEN}✓${NC} INPUT/OUTPUT rules configured"
echo ""

# Step 5: Configure NAT (MASQUERADE)
echo -e "${YELLOW}[5] Configuring NAT...${NC}"

# Remove old NAT rules
iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE 2>/dev/null || true

# Add NAT rule
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE

echo -e "${GREEN}✓${NC} NAT configured"
echo ""

# Step 6: Save iptables rules
echo -e "${YELLOW}[6] Saving iptables rules...${NC}"

# Install iptables-persistent if not installed
if ! dpkg -l | grep -q iptables-persistent; then
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    apt-get install -y iptables-persistent
fi

netfilter-persistent save
echo -e "${GREEN}✓${NC} Rules saved"
echo ""

# Step 7: Display current rules
echo -e "${YELLOW}[7] Current iptables configuration:${NC}"
echo ""
echo -e "${BLUE}DOCKER-USER chain:${NC}"
iptables -L DOCKER-USER -n -v --line-numbers
echo ""
echo -e "${BLUE}FORWARD chain (first 10 rules):${NC}"
iptables -L FORWARD -n -v --line-numbers | head -15
echo ""
echo -e "${BLUE}NAT POSTROUTING:${NC}"
iptables -t nat -L POSTROUTING -n -v | grep -E "Chain|10.8.0"
echo ""

# Step 8: Restart OpenVPN
echo -e "${YELLOW}[8] Restarting OpenVPN service...${NC}"
systemctl restart openvpn@server

# Wait for service to start
sleep 2

if systemctl is-active --quiet openvpn@server; then
    echo -e "${GREEN}✓${NC} OpenVPN restarted successfully"
else
    echo -e "${RED}✗${NC} OpenVPN failed to start"
    echo "Check logs: journalctl -xe -u openvpn@server"
    exit 1
fi
echo ""

# Step 9: Verify configuration
echo -e "${YELLOW}[9] Verifying configuration...${NC}"

# Check IP forwarding
IPFORWARD=$(sysctl net.ipv4.ip_forward | awk '{print $3}')
if [[ "$IPFORWARD" == "1" ]]; then
    echo -e "${GREEN}✓${NC} IP forwarding: enabled"
else
    echo -e "${RED}✗${NC} IP forwarding: disabled"
fi

# Check tun0 interface
if ip addr show tun0 &>/dev/null; then
    echo -e "${GREEN}✓${NC} tun0 interface: up"
else
    echo -e "${RED}✗${NC} tun0 interface: down"
fi

# Check NAT rule
NAT_COUNT=$(iptables -t nat -L POSTROUTING -n | grep -c "10.8.0.0/24" || echo "0")
if [[ "$NAT_COUNT" -gt 0 ]]; then
    echo -e "${GREEN}✓${NC} NAT rule: configured"
else
    echo -e "${RED}✗${NC} NAT rule: missing"
fi

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Fix Complete!${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo "Next steps:"
echo "1. On your Mac: disconnect and reconnect to VPN"
echo "2. Test ping: ping -c 3 10.8.0.1"
echo "3. Test internet: ping -c 3 8.8.8.8"
echo "4. Check browser access"
echo ""
echo "If still not working, check logs:"
echo "  tail -f /var/log/openvpn/openvpn.log"
echo ""

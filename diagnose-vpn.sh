#!/bin/bash

#############################################
# OpenVPN Diagnostics Script
# Check and fix common connectivity issues
#############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}OpenVPN Diagnostics & Fix${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR]${NC} This script must be run as root"
   exit 1
fi

# 1. Check IP forwarding
echo -e "${YELLOW}[1] Checking IP forwarding...${NC}"
IPFORWARD=$(sysctl net.ipv4.ip_forward | awk '{print $3}')
if [[ "$IPFORWARD" == "1" ]]; then
    echo -e "${GREEN}✓${NC} IP forwarding is enabled"
else
    echo -e "${RED}✗${NC} IP forwarding is disabled - FIXING..."
    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn.conf
    echo -e "${GREEN}✓${NC} IP forwarding enabled"
fi
echo ""

# 2. Check network interface
echo -e "${YELLOW}[2] Detecting network interface...${NC}"
NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if [[ -z "$NIC" ]]; then
    echo -e "${RED}✗${NC} Could not detect network interface"
    exit 1
else
    echo -e "${GREEN}✓${NC} Network interface: $NIC"
fi
echo ""

# 3. Check iptables NAT rules
echo -e "${YELLOW}[3] Checking iptables NAT rules...${NC}"
NAT_RULE=$(iptables -t nat -L POSTROUTING -n | grep "10.8.0.0/24" | grep MASQUERADE)
if [[ -z "$NAT_RULE" ]]; then
    echo -e "${RED}✗${NC} NAT rule missing - ADDING..."
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
    echo -e "${GREEN}✓${NC} NAT rule added"
else
    echo -e "${GREEN}✓${NC} NAT rule exists"
fi
echo ""

# 4. Check FORWARD chain
echo -e "${YELLOW}[4] Checking FORWARD chain...${NC}"
FORWARD_POLICY=$(iptables -L FORWARD -n | grep "policy" | awk '{print $4}')
echo "Current FORWARD policy: $FORWARD_POLICY"

# Add FORWARD rules if missing
if ! iptables -L FORWARD -n | grep -q "10.8.0.0/24"; then
    echo -e "${RED}✗${NC} FORWARD rules missing - ADDING..."
    iptables -A FORWARD -s 10.8.0.0/24 -j ACCEPT
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo -e "${GREEN}✓${NC} FORWARD rules added"
else
    echo -e "${GREEN}✓${NC} FORWARD rules exist"
fi
echo ""

# 5. Check INPUT rule for OpenVPN port
echo -e "${YELLOW}[5] Checking INPUT rules for port 1194...${NC}"
if ! iptables -L INPUT -n | grep -q "1194"; then
    echo -e "${RED}✗${NC} INPUT rule missing - ADDING..."
    iptables -A INPUT -p udp --dport 1194 -j ACCEPT
    echo -e "${GREEN}✓${NC} INPUT rule added"
else
    echo -e "${GREEN}✓${NC} INPUT rule exists"
fi
echo ""

# 6. Save iptables rules
echo -e "${YELLOW}[6] Saving iptables rules...${NC}"
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
    echo -e "${GREEN}✓${NC} Rules saved with netfilter-persistent"
elif command -v iptables-save &> /dev/null; then
    if [[ -f /etc/debian_version ]]; then
        iptables-save > /etc/iptables/rules.v4
    elif [[ -f /etc/redhat-release ]]; then
        service iptables save
    fi
    echo -e "${GREEN}✓${NC} Rules saved with iptables-save"
fi
echo ""

# 7. Display current iptables rules
echo -e "${YELLOW}[7] Current NAT rules:${NC}"
iptables -t nat -L POSTROUTING -n -v | grep -E "Chain|10.8.0"
echo ""

echo -e "${YELLOW}[8] Current FORWARD rules:${NC}"
iptables -L FORWARD -n -v | grep -E "Chain|10.8.0|RELATED"
echo ""

# 8. Check OpenVPN service status
echo -e "${YELLOW}[9] Checking OpenVPN service...${NC}"
if systemctl is-active --quiet openvpn@server; then
    echo -e "${GREEN}✓${NC} OpenVPN is running"

    # Get connected clients
    if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
        CLIENTS=$(grep -c "^CLIENT_LIST" /var/log/openvpn/openvpn-status.log 2>/dev/null || echo "0")
        echo -e "${BLUE}Connected clients: $CLIENTS${NC}"
    fi
else
    echo -e "${RED}✗${NC} OpenVPN is not running"
fi
echo ""

# 9. Test DNS resolution from server
echo -e "${YELLOW}[10] Testing DNS resolution from server...${NC}"
if ping -c 1 8.8.8.8 &> /dev/null; then
    echo -e "${GREEN}✓${NC} Can reach 8.8.8.8"
else
    echo -e "${RED}✗${NC} Cannot reach 8.8.8.8"
fi

if ping -c 1 google.com &> /dev/null; then
    echo -e "${GREEN}✓${NC} DNS resolution works (google.com)"
else
    echo -e "${RED}✗${NC} DNS resolution failed"
fi
echo ""

# 10. Summary
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Diagnostics Complete${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo "If you fixed issues, try reconnecting your VPN client."
echo "If problems persist, check server logs:"
echo "  sudo tail -f /var/log/openvpn/openvpn.log"
echo ""

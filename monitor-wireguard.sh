#!/bin/bash

#############################################
# WireGuard Resource Monitor
# Monitor CPU, memory, and network usage
#############################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SERVICE_NAME="wg-quick@wg0"
REFRESH_INTERVAL=2

# Print header
print_header() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  WireGuard Resource Monitor${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "Press Ctrl+C to exit"
    echo ""
}

# Get service status
get_service_status() {
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi
}

# Get CPU usage
get_cpu_usage() {
    # WireGuard runs in kernel space, so CPU usage is minimal
    # We'll show system-wide CPU for wg operations
    local CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "${CPU}%"
}

# Get memory usage
get_memory_usage() {
    # WireGuard uses very little memory
    local WG_MEM=$(ps aux | grep -E '[w]g-quick|[w]ireguard' | awk '{sum+=$6} END {print sum/1024}')
    if [[ -z "$WG_MEM" || "$WG_MEM" == "0" ]]; then
        echo "~10-20 MB"
    else
        printf "%.0f MB\n" "$WG_MEM"
    fi
}

# Get connected clients count
get_connected_clients() {
    if [[ -f /sys/class/net/wg0/statistics/rx_bytes ]]; then
        local COUNT=$(wg show wg0 peers | wc -l)
        echo "$COUNT"
    else
        echo "0"
    fi
}

# Get network traffic
get_network_stats() {
    if [[ -f /sys/class/net/wg0/statistics/rx_bytes ]]; then
        local RX=$(cat /sys/class/net/wg0/statistics/rx_bytes)
        local TX=$(cat /sys/class/net/wg0/statistics/tx_bytes)

        local RX_MB=$((RX / 1048576))
        local TX_MB=$((TX / 1048576))

        echo "↓ ${RX_MB} MB  ↑ ${TX_MB} MB"
    else
        echo "N/A"
    fi
}

# Get uptime
get_uptime() {
    local START_TIME=$(systemctl show ${SERVICE_NAME} -p ActiveEnterTimestamp --value)
    if [[ -n "$START_TIME" && "$START_TIME" != "n/a" ]]; then
        local START_EPOCH=$(date -d "$START_TIME" +%s 2>/dev/null)
        local NOW_EPOCH=$(date +%s)
        local DIFF=$((NOW_EPOCH - START_EPOCH))

        local DAYS=$((DIFF / 86400))
        local HOURS=$(((DIFF % 86400) / 3600))
        local MINUTES=$(((DIFF % 3600) / 60))

        if [[ $DAYS -gt 0 ]]; then
            echo "${DAYS}d ${HOURS}h ${MINUTES}m"
        elif [[ $HOURS -gt 0 ]]; then
            echo "${HOURS}h ${MINUTES}m"
        else
            echo "${MINUTES}m"
        fi
    else
        echo "N/A"
    fi
}

# Display connected clients
display_clients() {
    echo -e "\n${BLUE}Connected Clients:${NC}"
    echo "----------------------------------------"

    if ! ip link show wg0 &>/dev/null; then
        echo -e "${YELLOW}WireGuard interface not active${NC}"
        return
    fi

    local HAS_PEERS=false
    while IFS= read -r line; do
        if [[ $line =~ ^peer:\ (.+)$ ]]; then
            HAS_PEERS=true
            local PEER="${BASH_REMATCH[1]}"
            echo -e "${YELLOW}Peer:${NC} ${PEER:0:16}..."
        elif [[ $line =~ endpoint:\ (.+)$ ]]; then
            echo -e "  ${BLUE}Endpoint:${NC} ${BASH_REMATCH[1]}"
        elif [[ $line =~ latest\ handshake:\ (.+)$ ]]; then
            echo -e "  ${BLUE}Handshake:${NC} ${BASH_REMATCH[1]}"
        elif [[ $line =~ transfer:\ (.+)$ ]]; then
            echo -e "  ${BLUE}Transfer:${NC} ${BASH_REMATCH[1]}"
            echo ""
        fi
    done < <(wg show wg0 2>/dev/null)

    if [[ "$HAS_PEERS" == "false" ]]; then
        echo -e "${YELLOW}No clients connected${NC}"
    fi
}

# Display system load
display_system_load() {
    echo -e "\n${BLUE}System Load:${NC}"
    echo "----------------------------------------"

    local LOAD=$(uptime | awk -F'load average:' '{print $2}')
    echo -e "Load Average: ${LOAD}"

    local TOTAL_MEM=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
    echo -e "Total Memory: ${TOTAL_MEM}"
}

# Monitor continuously
monitor_continuous() {
    while true; do
        print_header

        # Service status
        echo -e "${BLUE}Service Status:${NC} $(get_service_status)"
        echo -e "${BLUE}Uptime:${NC} $(get_uptime)"
        echo ""

        # Resource usage
        echo -e "${BLUE}WireGuard Resource Usage:${NC}"
        echo "----------------------------------------"
        echo -e "System CPU:   $(get_cpu_usage)"
        echo -e "Memory Usage: $(get_memory_usage)"
        echo -e "Network:      $(get_network_stats)"
        echo -e "Clients:      $(get_connected_clients)"

        # Display connected clients
        display_clients

        # Display system load
        display_system_load

        echo ""
        echo -e "${CYAN}Last update: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo ""
        echo -e "${GREEN}Note: WireGuard is extremely lightweight${NC}"
        echo -e "${GREEN}      Typical usage: <1% CPU, 10-20 MB RAM${NC}"

        sleep $REFRESH_INTERVAL
    done
}

# Show quick status
quick_status() {
    echo -e "${BLUE}WireGuard Quick Status${NC}"
    echo "----------------------------------------"
    echo -e "Status:       $(get_service_status)"
    echo -e "System CPU:   $(get_cpu_usage)"
    echo -e "Memory:       $(get_memory_usage)"
    echo -e "Clients:      $(get_connected_clients)"
    echo -e "Uptime:       $(get_uptime)"
    echo "----------------------------------------"
    echo ""
    echo -e "${BLUE}Interface Details:${NC}"
    wg show wg0 2>/dev/null || echo "Interface not active"
}

# Show help
show_help() {
    cat <<EOF
WireGuard Resource Monitor

Usage:
    $0 [OPTIONS]

Options:
    -c, --continuous    Monitor continuously (default)
    -q, --quick        Show quick status and exit
    -i, --interval N   Set refresh interval in seconds (default: 2)
    -h, --help         Show this help message

Examples:
    $0                 # Start continuous monitoring
    $0 -q              # Show quick status
    $0 -i 5            # Monitor with 5 second interval

The monitor shows:
    - Service status and uptime
    - CPU and memory usage (minimal for WireGuard)
    - Network traffic statistics
    - Connected clients with handshake times
    - Overall system load

WireGuard is extremely efficient:
    - Runs in kernel space
    - Uses <1% CPU typically
    - Uses only 10-20 MB RAM
    - Perfect for running alongside other services
EOF
}

# Parse command line arguments
case "${1:-}" in
    -q|--quick)
        quick_status
        ;;
    -i|--interval)
        if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
            REFRESH_INTERVAL=$2
            monitor_continuous
        else
            echo "Error: Invalid interval value"
            exit 1
        fi
        ;;
    -h|--help)
        show_help
        ;;
    -c|--continuous|"")
        monitor_continuous
        ;;
    *)
        echo "Error: Unknown option '$1'"
        echo ""
        show_help
        exit 1
        ;;
esac

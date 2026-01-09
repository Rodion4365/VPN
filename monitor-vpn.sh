#!/bin/bash

#############################################
# OpenVPN Resource Monitor
# Monitor CPU, memory, and network usage
#############################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SERVICE_NAME="openvpn@server"
REFRESH_INTERVAL=2

# Function to print header
print_header() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  OpenVPN Resource Monitor${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "Press Ctrl+C to exit"
    echo ""
}

# Function to get service status
get_service_status() {
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "${GREEN}● Running${NC}"
    else
        echo -e "${RED}● Stopped${NC}"
    fi
}

# Function to get CPU usage
get_cpu_usage() {
    local PID=$(systemctl show ${SERVICE_NAME} -p MainPID --value)
    if [[ -n "$PID" && "$PID" != "0" ]]; then
        local CPU=$(ps -p $PID -o %cpu --no-headers 2>/dev/null || echo "0.0")
        echo "${CPU}%"
    else
        echo "N/A"
    fi
}

# Function to get memory usage
get_memory_usage() {
    local PID=$(systemctl show ${SERVICE_NAME} -p MainPID --value)
    if [[ -n "$PID" && "$PID" != "0" ]]; then
        local MEM=$(ps -p $PID -o rss --no-headers 2>/dev/null || echo "0")
        local MEM_MB=$((MEM / 1024))
        echo "${MEM_MB} MB"
    else
        echo "N/A"
    fi
}

# Function to get connected clients count
get_connected_clients() {
    if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
        local COUNT=$(grep -c "^CLIENT_LIST" /var/log/openvpn/openvpn-status.log 2>/dev/null || echo "0")
        echo "$COUNT"
    else
        echo "0"
    fi
}

# Function to get network traffic
get_network_stats() {
    if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
        # Get total bytes from status log
        local STATS=$(awk '/^CLIENT_LIST/ {rx+=$6; tx+=$7} END {print rx, tx}' /var/log/openvpn/openvpn-status.log 2>/dev/null)

        if [[ -n "$STATS" ]]; then
            local RX=$(echo $STATS | awk '{print $1}')
            local TX=$(echo $STATS | awk '{print $2}')

            # Convert to human readable format
            local RX_MB=$((RX / 1048576))
            local TX_MB=$((TX / 1048576))

            echo "↓ ${RX_MB} MB  ↑ ${TX_MB} MB"
        else
            echo "N/A"
        fi
    else
        echo "N/A"
    fi
}

# Function to get uptime
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

# Function to display connected clients
display_clients() {
    if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
        echo -e "\n${BLUE}Connected Clients:${NC}"
        echo "----------------------------------------"

        local CLIENT_DATA=$(awk '/^CLIENT_LIST/ {
            printf "%-20s %-15s %10s %10s\n", $2, $3, $6, $7
        }' /var/log/openvpn/openvpn-status.log 2>/dev/null)

        if [[ -n "$CLIENT_DATA" ]]; then
            echo -e "${YELLOW}$(printf "%-20s %-15s %10s %10s" "Client" "IP Address" "RX Bytes" "TX Bytes")${NC}"
            echo "$CLIENT_DATA"
        else
            echo -e "${YELLOW}No clients connected${NC}"
        fi
    fi
}

# Function to display system load
display_system_load() {
    echo -e "\n${BLUE}System Load:${NC}"
    echo "----------------------------------------"

    local LOAD=$(uptime | awk -F'load average:' '{print $2}')
    echo -e "Load Average: ${LOAD}"

    # Get total system CPU and memory
    local TOTAL_CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local TOTAL_MEM=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')

    echo -e "Total CPU Usage: ${TOTAL_CPU}%"
    echo -e "Total Memory: ${TOTAL_MEM}"
}

# Function to monitor continuously
monitor_continuous() {
    while true; do
        print_header

        # Service status
        echo -e "${BLUE}Service Status:${NC} $(get_service_status)"
        echo -e "${BLUE}Uptime:${NC} $(get_uptime)"
        echo ""

        # Resource usage
        echo -e "${BLUE}OpenVPN Resource Usage:${NC}"
        echo "----------------------------------------"
        echo -e "CPU Usage:    $(get_cpu_usage)"
        echo -e "Memory Usage: $(get_memory_usage)"
        echo -e "Network:      $(get_network_stats)"
        echo -e "Clients:      $(get_connected_clients)"

        # Display connected clients
        display_clients

        # Display system load
        display_system_load

        echo ""
        echo -e "${CYAN}Last update: $(date '+%Y-%m-%d %H:%M:%S')${NC}"

        sleep $REFRESH_INTERVAL
    done
}

# Function to show quick status
quick_status() {
    echo -e "${BLUE}OpenVPN Quick Status${NC}"
    echo "----------------------------------------"
    echo -e "Status:       $(get_service_status)"
    echo -e "CPU:          $(get_cpu_usage)"
    echo -e "Memory:       $(get_memory_usage)"
    echo -e "Clients:      $(get_connected_clients)"
    echo -e "Uptime:       $(get_uptime)"
    echo "----------------------------------------"
}

# Function to show help
show_help() {
    cat <<EOF
OpenVPN Resource Monitor

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
    - CPU and memory usage
    - Network traffic statistics
    - Connected clients
    - Overall system load
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

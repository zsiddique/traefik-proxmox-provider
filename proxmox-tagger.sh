#!/bin/bash

# proxmox-tagger.sh - Proxmox VE Container and VM Tagger
#
# This script automatically tags Proxmox VMs and LXC containers with their IP addresses,
# hostnames, and service ports. It also supports automatic Traefik label generation for
# service discovery and routing configuration.
#
# Author: NX211
# Version: 1.0.0
# Repository: https://github.com/NX211/traefik-proxmox-provider

set -o errexit   # abort on nonzero exitstatus
set -o nounset   # abort on unbound variable
set -o pipefail  # don't hide errors within pipes
set -o errtrace  # ensure the error trap handler is inherited

# =============================================
# Configuration
# =============================================

# System paths
readonly CONFIG_DIR="/etc/proxmox-tagger"
readonly CONFIG_FILE="${CONFIG_DIR}/config"
readonly SCRIPT_DIR="/usr/local/bin"
readonly SCRIPT_FILE="${SCRIPT_DIR}/proxmox-tagger"
readonly SERVICE_FILE="/etc/systemd/system/proxmox-tagger.service"

# Network configuration
readonly DEFAULT_CIDRS=(
    "192.168.0.0/16"
    "172.16.0.0/12"
    "10.0.0.0/8"
    "100.64.0.0/10"
)

# Service detection
readonly COMMON_PORTS=(
    80 443 8080 8443 3000 5000 8000 9000
)

# Timing configuration
readonly DEFAULT_INTERVAL=60
readonly DEFAULT_FORCE_UPDATE_INTERVAL=1800

# Traefik configuration
readonly TRAEFIK_ENABLE_BY_DEFAULT=true
readonly TRAEFIK_DEFAULT_ENTRYPOINT="web"
readonly TRAEFIK_SECURE_ENTRYPOINT="websecure"
readonly TRAEFIK_DEFAULT_MIDDLEWARES="compression"

# =============================================
# Helper Functions
# =============================================

# Log a message with timestamp
function log {
    local level=$1
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
}

# Check if an IP address is within any of the configured CIDR ranges
function ip_in_cidrs {
    local ip=$1
    for cidr in "${CIDR_LIST[@]}"; do
        if ipcalc -n "${ip}/${cidr#*/}" | grep -q "^NETWORK=${cidr%/*}"; then
            return 0
        fi
    done
    return 1
}

# Determine if a container is an LXC or VM
function get_container_type {
    local vmid=$1
    if pct list | grep -q "^${vmid}"; then
        echo "lxc"
    elif qm list | grep -q "^${vmid}"; then
        echo "vm"
    else
        echo "unknown"
    fi
}

# Get IP addresses for a container/VM
function get_container_ips {
    local vmid=$1
    local type=$2
    
    if [ "$type" = "lxc" ]; then
        lxc-info -n "${vmid}" -i | awk '{print $2}'
    elif [ "$type" = "vm" ]; then
        # Try guest agent first
        if qm guest exec "${vmid}" -- ip -4 addr show 2>/dev/null; then
            qm guest exec "${vmid}" -- ip -4 addr show | grep -oP 'inet \K[\d.]+'
        else
            # Fallback to network interface config
            qm config "${vmid}" | grep -oP 'net\d+:\s*\S+\s*\S+\s*\K[\d.]+'
        fi
    fi
}

# Get hostname for a container/VM
function get_container_hostname {
    local vmid=$1
    local type=$2
    
    if [ "$type" = "lxc" ]; then
        pct config "${vmid}" | grep -oP 'hostname:\s*\K[^\s]+' || lxc-attach -n "${vmid}" -- hostname
    elif [ "$type" = "vm" ]; then
        # Try guest agent first
        if qm guest exec "${vmid}" -- hostname 2>/dev/null; then
            qm guest exec "${vmid}" -- hostname
        else
            # Fallback to config
            qm config "${vmid}" | grep -oP 'name:\s*\K[^\s]+'
        fi
    fi
}

# Scan for open ports on a given IP address
function scan_ports {
    local ip=$1
    local ports=()
    
    # Check common ports first
    for port in "${COMMON_PORTS[@]}"; do
        if nc -z -w1 "${ip}" "${port}" 2>/dev/null; then
            ports+=("${port}")
        fi
    done
    
    # If no common ports found, do a quick scan
    if [ ${#ports[@]} -eq 0 ]; then
        if command -v nmap >/dev/null 2>&1; then
            ports=($(nmap -p- --min-rate=1000 -T4 "${ip}" | grep '^[0-9]' | cut -d'/' -f1))
        else
            # Fallback to netcat if nmap not available
            for port in $(seq 1024 65535); do
                if nc -z -w1 "${ip}" "${port}" 2>/dev/null; then
                    ports+=("${port}")
                fi
            done
        fi
    fi
    
    # Select the most appropriate port
    if [ ${#ports[@]} -gt 0 ]; then
        # Priority ports (web/application)
        for port in 80 443 8080 8443; do
            if [[ " ${ports[*]} " =~ " ${port} " ]]; then
                echo "${port}"
                return
            fi
        done
        
        # Lowest non-system port
        for port in "${ports[@]}"; do
            if [ "${port}" -gt 1024 ]; then
                echo "${port}"
                return
            fi
        done
        
        # Lowest port overall
        echo "${ports[0]}"
    fi
}

# =============================================
# Traefik Functions
# =============================================

# Check if a port is considered secure (HTTPS)
function is_secure_port {
    local port=$1
    [[ "$port" = "443" || "$port" = "8443" ]]
}

# Sanitize a service name for use in labels
function sanitize_service_name {
    local name=$1
    echo "${name//[^a-zA-Z0-9]/-}"
}

# Add basic Traefik enable label
function add_traefik_basic_labels {
    local -n labels=$1
    labels+=("traefik.enable=true")
}

# Add entrypoint configuration labels
function add_traefik_entrypoint_labels {
    local service_name=$1
    local port=$2
    local -n labels=$3
    
    if is_secure_port "$port"; then
        labels+=("traefik.http.routers.${service_name}.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}")
        labels+=("traefik.http.routers.${service_name}.tls=true")
    else
        labels+=("traefik.http.routers.${service_name}.entrypoints=${TRAEFIK_DEFAULT_ENTRYPOINT}")
    fi
}

# Add service configuration labels
function add_traefik_service_labels {
    local service_name=$1
    local port=$2
    local -n labels=$3
    
    # Add service port label
    labels+=("traefik.http.services.${service_name}.loadbalancer.server.port=${port}")
    
    # Add health check labels
    labels+=("traefik.http.services.${service_name}.loadbalancer.healthcheck.path=/")
    labels+=("traefik.http.services.${service_name}.loadbalancer.healthcheck.interval=10s")
    labels+=("traefik.http.services.${service_name}.loadbalancer.healthcheck.timeout=5s")
}

# Add middleware configuration labels
function add_traefik_middleware_labels {
    local service_name=$1
    local -n labels=$2
    
    if [ -n "${TRAEFIK_DEFAULT_MIDDLEWARES}" ]; then
        labels+=("traefik.http.routers.${service_name}.middlewares=${TRAEFIK_DEFAULT_MIDDLEWARES}")
    fi
}

# Add router configuration labels
function add_traefik_router_labels {
    local service_name=$1
    local hostname=$2
    local -n labels=$3
    
    labels+=("traefik.http.routers.${service_name}.rule=Host(\`${hostname}\`)")
}

# Add all Traefik labels for a service
function add_traefik_labels {
    local hostname=$1
    local port=$2
    local -n labels=$3
    
    # Sanitize hostname for service name
    local service_name=$(sanitize_service_name "$hostname")
    
    # Add basic labels
    add_traefik_basic_labels labels
    
    # Add router configuration
    add_traefik_router_labels "$service_name" "$hostname" labels
    
    # Add entrypoint configuration
    add_traefik_entrypoint_labels "$service_name" "$port" labels
    
    # Add service configuration
    add_traefik_service_labels "$service_name" "$port" labels
    
    # Add middleware configuration
    add_traefik_middleware_labels "$service_name" labels
}

# =============================================
# Main Functions
# =============================================

# Update tags for all containers and VMs
function update_container_tags {
    log "INFO" "Starting container tag update"
    
    # Get both LXC and VM IDs
    local lxc_list=$(pct list 2>/dev/null | grep -v VMID | awk '{print $1}')
    local vm_list=$(qm list 2>/dev/null | grep -v VMID | awk '{print $1}')
    
    for vmid in ${lxc_list} ${vm_list}; do
        local type=$(get_container_type "${vmid}")
        if [ "$type" = "unknown" ]; then
            log "WARN" "Unknown container type for ID ${vmid}"
            continue
        fi
        
        local current_tags=()
        local next_tags=()
        
        # Get current tags based on type
        if [ "$type" = "lxc" ]; then
            mapfile -t current_tags < <(pct config "${vmid}" | grep tags | awk '{print $2}' | sed 's/;/\n/g')
        else
            mapfile -t current_tags < <(qm config "${vmid}" | grep tags | awk '{print $2}' | sed 's/;/\n/g')
        fi
        
        # Get container IPs
        local container_ips=$(get_container_ips "${vmid}" "${type}")
        
        for ip in ${container_ips}; do
            if ip_in_cidrs "${ip}"; then
                next_tags+=("${ip}")
                
                local hostname=$(get_container_hostname "${vmid}" "${type}")
                if [ -n "$hostname" ]; then
                    next_tags+=("hostname:${hostname}")
                fi
                
                local port=$(scan_ports "${ip}")
                if [ -n "$port" ]; then
                    next_tags+=("port:${port}")
                    
                    # Add Traefik labels if enabled
                    if [ "${TRAEFIK_ENABLE_BY_DEFAULT}" = "true" ] && [ -n "$hostname" ]; then
                        add_traefik_labels "$hostname" "$port" next_tags
                    fi
                fi
            fi
        done
        
        # Update tags based on type
        if [ "${#next_tags[@]}" -gt 0 ]; then
            log "INFO" "Updating tags for ${type} ${vmid}"
            if [ "$type" = "lxc" ]; then
                pct set "${vmid}" -tags "$(IFS=';'; echo "${next_tags[*]}")"
            else
                qm set "${vmid}" -tags "$(IFS=';'; echo "${next_tags[*]}")"
            fi
        fi
    done
    
    log "INFO" "Container tag update complete"
}

# Main loop
function main {
    log "INFO" "Starting Proxmox Tagger"
    
    while true; do
        update_container_tags
        sleep "${LOOP_INTERVAL}"
    done
}

# =============================================
# Installation Functions
# =============================================

# Setup required directories
function setup_directories {
    log "INFO" "Setting up directories..."
    mkdir -p "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"
}

# Install required dependencies
function install_dependencies {
    log "INFO" "Installing dependencies..."
    apt-get update
    apt-get install -y nmap netcat-openbsd ipcalc
}

# Create configuration file
function create_config {
    log "INFO" "Creating configuration file..."
    cat > "${CONFIG_FILE}" << EOF
# CIDR ranges to check for IP addresses
CIDR_LIST=(
    ${DEFAULT_CIDRS[*]}
)

# Check intervals (in seconds)
LOOP_INTERVAL=${DEFAULT_INTERVAL}
FORCE_UPDATE_INTERVAL=${DEFAULT_FORCE_UPDATE_INTERVAL}

# Common ports to check first
COMMON_PORTS=(
    ${COMMON_PORTS[*]}
)

# Traefik configuration
TRAEFIK_ENABLE_BY_DEFAULT=${TRAEFIK_ENABLE_BY_DEFAULT}
TRAEFIK_DEFAULT_ENTRYPOINT="${TRAEFIK_DEFAULT_ENTRYPOINT}"
TRAEFIK_SECURE_ENTRYPOINT="${TRAEFIK_SECURE_ENTRYPOINT}"
TRAEFIK_DEFAULT_MIDDLEWARES="${TRAEFIK_DEFAULT_MIDDLEWARES}"
EOF
    chmod 644 "${CONFIG_FILE}"
}

# Create the tagger script
function create_tagger_script {
    log "INFO" "Creating tagger script..."
    cat > "${SCRIPT_FILE}" << 'TAGGER_SCRIPT'
#!/bin/bash

# proxmox-tagger.sh - Proxmox VE Container and VM Tagger
#
# This script automatically tags Proxmox VMs and LXC containers with their IP addresses,
# hostnames, and service ports. It also supports automatic Traefik label generation for
# service discovery and routing configuration.
#
# Author: NX211
# License: MIT
# Version: 1.0.0
# Repository: https://github.com/NX211/traefik-proxmox-provider

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# Load configuration
source /etc/proxmox-tagger/config

# =============================================
# Helper Functions
# =============================================

# Log a message with timestamp
function log {
    local level=$1
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
}

# Check if an IP address is within any of the configured CIDR ranges
function ip_in_cidrs {
    local ip=$1
    for cidr in "${CIDR_LIST[@]}"; do
        if ipcalc -n "${ip}/${cidr#*/}" | grep -q "^NETWORK=${cidr%/*}"; then
            return 0
        fi
    done
    return 1
}

# Determine if a container is an LXC or VM
function get_container_type {
    local vmid=$1
    if pct list | grep -q "^${vmid}"; then
        echo "lxc"
    elif qm list | grep -q "^${vmid}"; then
        echo "vm"
    else
        echo "unknown"
    fi
}

# Get IP addresses for a container/VM
function get_container_ips {
    local vmid=$1
    local type=$2
    
    if [ "$type" = "lxc" ]; then
        lxc-info -n "${vmid}" -i | awk '{print $2}'
    elif [ "$type" = "vm" ]; then
        # Try guest agent first
        if qm guest exec "${vmid}" -- ip -4 addr show 2>/dev/null; then
            qm guest exec "${vmid}" -- ip -4 addr show | grep -oP 'inet \K[\d.]+'
        else
            # Fallback to network interface config
            qm config "${vmid}" | grep -oP 'net\d+:\s*\S+\s*\S+\s*\K[\d.]+'
        fi
    fi
}

# Get hostname for a container/VM
function get_container_hostname {
    local vmid=$1
    local type=$2
    
    if [ "$type" = "lxc" ]; then
        pct config "${vmid}" | grep -oP 'hostname:\s*\K[^\s]+' || lxc-attach -n "${vmid}" -- hostname
    elif [ "$type" = "vm" ]; then
        # Try guest agent first
        if qm guest exec "${vmid}" -- hostname 2>/dev/null; then
            qm guest exec "${vmid}" -- hostname
        else
            # Fallback to config
            qm config "${vmid}" | grep -oP 'name:\s*\K[^\s]+'
        fi
    fi
}

# Scan for open ports on a given IP address
function scan_ports {
    local ip=$1
    local ports=()
    
    # Check common ports first
    for port in "${COMMON_PORTS[@]}"; do
        if nc -z -w1 "${ip}" "${port}" 2>/dev/null; then
            ports+=("${port}")
        fi
    done
    
    # If no common ports found, do a quick scan
    if [ ${#ports[@]} -eq 0 ]; then
        if command -v nmap >/dev/null 2>&1; then
            ports=($(nmap -p- --min-rate=1000 -T4 "${ip}" | grep '^[0-9]' | cut -d'/' -f1))
        else
            # Fallback to netcat if nmap not available
            for port in $(seq 1024 65535); do
                if nc -z -w1 "${ip}" "${port}" 2>/dev/null; then
                    ports+=("${port}")
                fi
            done
        fi
    fi
    
    # Select the most appropriate port
    if [ ${#ports[@]} -gt 0 ]; then
        # Priority ports (web/application)
        for port in 80 443 8080 8443; do
            if [[ " ${ports[*]} " =~ " ${port} " ]]; then
                echo "${port}"
                return
            fi
        done
        
        # Lowest non-system port
        for port in "${ports[@]}"; do
            if [ "${port}" -gt 1024 ]; then
                echo "${port}"
                return
            fi
        done
        
        # Lowest port overall
        echo "${ports[0]}"
    fi
}

# =============================================
# Traefik Functions
# =============================================

# Check if a port is considered secure (HTTPS)
function is_secure_port {
    local port=$1
    [[ "$port" = "443" || "$port" = "8443" ]]
}

# Sanitize a service name for use in labels
function sanitize_service_name {
    local name=$1
    echo "${name//[^a-zA-Z0-9]/-}"
}

# Add basic Traefik enable label
function add_traefik_basic_labels {
    local -n labels=$1
    labels+=("traefik.enable=true")
}

# Add entrypoint configuration labels
function add_traefik_entrypoint_labels {
    local service_name=$1
    local port=$2
    local -n labels=$3
    
    if is_secure_port "$port"; then
        labels+=("traefik.http.routers.${service_name}.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}")
        labels+=("traefik.http.routers.${service_name}.tls=true")
    else
        labels+=("traefik.http.routers.${service_name}.entrypoints=${TRAEFIK_DEFAULT_ENTRYPOINT}")
    fi
}

# Add service configuration labels
function add_traefik_service_labels {
    local service_name=$1
    local port=$2
    local -n labels=$3
    
    # Add service port label
    labels+=("traefik.http.services.${service_name}.loadbalancer.server.port=${port}")
    
    # Add health check labels
    labels+=("traefik.http.services.${service_name}.loadbalancer.healthcheck.path=/")
    labels+=("traefik.http.services.${service_name}.loadbalancer.healthcheck.interval=10s")
    labels+=("traefik.http.services.${service_name}.loadbalancer.healthcheck.timeout=5s")
}

# Add middleware configuration labels
function add_traefik_middleware_labels {
    local service_name=$1
    local -n labels=$2
    
    if [ -n "${TRAEFIK_DEFAULT_MIDDLEWARES}" ]; then
        labels+=("traefik.http.routers.${service_name}.middlewares=${TRAEFIK_DEFAULT_MIDDLEWARES}")
    fi
}

# Add router configuration labels
function add_traefik_router_labels {
    local service_name=$1
    local hostname=$2
    local -n labels=$3
    
    labels+=("traefik.http.routers.${service_name}.rule=Host(\`${hostname}\`)")
}

# Add all Traefik labels for a service
function add_traefik_labels {
    local hostname=$1
    local port=$2
    local -n labels=$3
    
    # Sanitize hostname for service name
    local service_name=$(sanitize_service_name "$hostname")
    
    # Add basic labels
    add_traefik_basic_labels labels
    
    # Add router configuration
    add_traefik_router_labels "$service_name" "$hostname" labels
    
    # Add entrypoint configuration
    add_traefik_entrypoint_labels "$service_name" "$port" labels
    
    # Add service configuration
    add_traefik_service_labels "$service_name" "$port" labels
    
    # Add middleware configuration
    add_traefik_middleware_labels "$service_name" labels
}

# =============================================
# Main Functions
# =============================================

# Update tags for all containers and VMs
function update_container_tags {
    log "INFO" "Starting container tag update"
    
    # Get both LXC and VM IDs
    local lxc_list=$(pct list 2>/dev/null | grep -v VMID | awk '{print $1}')
    local vm_list=$(qm list 2>/dev/null | grep -v VMID | awk '{print $1}')
    
    for vmid in ${lxc_list} ${vm_list}; do
        local type=$(get_container_type "${vmid}")
        if [ "$type" = "unknown" ]; then
            log "WARN" "Unknown container type for ID ${vmid}"
            continue
        fi
        
        local current_tags=()
        local next_tags=()
        
        # Get current tags based on type
        if [ "$type" = "lxc" ]; then
            mapfile -t current_tags < <(pct config "${vmid}" | grep tags | awk '{print $2}' | sed 's/;/\n/g')
        else
            mapfile -t current_tags < <(qm config "${vmid}" | grep tags | awk '{print $2}' | sed 's/;/\n/g')
        fi
        
        # Get container IPs
        local container_ips=$(get_container_ips "${vmid}" "${type}")
        
        for ip in ${container_ips}; do
            if ip_in_cidrs "${ip}"; then
                next_tags+=("${ip}")
                
                local hostname=$(get_container_hostname "${vmid}" "${type}")
                if [ -n "$hostname" ]; then
                    next_tags+=("hostname:${hostname}")
                fi
                
                local port=$(scan_ports "${ip}")
                if [ -n "$port" ]; then
                    next_tags+=("port:${port}")
                    
                    # Add Traefik labels if enabled
                    if [ "${TRAEFIK_ENABLE_BY_DEFAULT}" = "true" ] && [ -n "$hostname" ]; then
                        add_traefik_labels "$hostname" "$port" next_tags
                    fi
                fi
            fi
        done
        
        # Update tags based on type
        if [ "${#next_tags[@]}" -gt 0 ]; then
            log "INFO" "Updating tags for ${type} ${vmid}"
            if [ "$type" = "lxc" ]; then
                pct set "${vmid}" -tags "$(IFS=';'; echo "${next_tags[*]}")"
            else
                qm set "${vmid}" -tags "$(IFS=';'; echo "${next_tags[*]}")"
            fi
        fi
    done
    
    log "INFO" "Container tag update complete"
}

# Main loop
function main {
    log "INFO" "Starting Proxmox Tagger"
    
    while true; do
        update_container_tags
        sleep "${LOOP_INTERVAL}"
    done
}

main
TAGGER_SCRIPT
    chmod 755 "${SCRIPT_FILE}"
}

# Create systemd service file
function create_service {
    log "INFO" "Creating systemd service..."
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Proxmox VM and LXC Container Tagger
After=network.target

[Service]
Type=simple
ExecStart=${SCRIPT_FILE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${SERVICE_FILE}"
}

# Install and start the service
function install_service {
    log "INFO" "Installing and starting service..."
    systemctl daemon-reload
    systemctl enable proxmox-tagger
    systemctl start proxmox-tagger
}

# Main installation function
function install {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "Please run as root"
        exit 1
    fi
    
    setup_directories
    install_dependencies
    create_config
    create_tagger_script
    create_service
    install_service
    
    log "INFO" "Installation complete. The tagger service is now running."
    log "INFO" "Check status with: systemctl status proxmox-tagger"
}

# Run installation if script is executed directly
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    install
fi 
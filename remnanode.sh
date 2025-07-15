#!/usr/bin/env bash
# Version: 3.1.3
set -e
SCRIPT_VERSION="3.1.3"

# Handle @ prefix for consistency with other scripts
if [ $# -gt 0 ] && [ "$1" = "@" ]; then
    shift  
fi

# Parse command line arguments
COMMAND=""
if [ $# -gt 0 ]; then
    COMMAND="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    key="$1"
    
    case $key in
        --name)
            if [[ "$COMMAND" == "install" || "$COMMAND" == "install-script" ]]; then
                APP_NAME="$2"
                shift # past argument
            else
                echo "Error: --name parameter is only allowed with 'install' or 'install-script' commands."
                exit 1
            fi
            shift # past value
        ;;
        --dev)
            if [[ "$COMMAND" == "install" ]]; then
                USE_DEV_BRANCH="true"
            else
                echo "Error: --dev parameter is only allowed with 'install' command."
                exit 1
            fi
            shift # past argument
        ;;
        --help|-h)
            show_command_help "$COMMAND"
            exit 0
        ;;
        *)
            echo "Unknown argument: $key"
            exit 1
        ;;
    esac
done

# Fetch IP address from ipinfo.io API
NODE_IP=$(curl -s -4 ifconfig.io)

# If the IPv4 retrieval is empty, attempt to retrieve the IPv6 address
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(curl -s -6 ifconfig.io)
fi

if [[ "$COMMAND" == "install" || "$COMMAND" == "install-script" ]] && [ -z "$APP_NAME" ]; then
    APP_NAME="remnanode"
fi
# Set script name if APP_NAME is not set
if [ -z "$APP_NAME" ]; then
    SCRIPT_NAME=$(basename "$0")
    APP_NAME="${SCRIPT_NAME%.*}"
fi

INSTALL_DIR="/opt"
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
XRAY_FILE="$DATA_DIR/xray"
SCRIPT_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"  # Убедитесь, что URL актуален

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

colorized_echo() {
    local color=$1
    local text=$2
    local style=${3:-0}  # Default style is normal

    case $color in
        "red") printf "\e[${style};91m${text}\e[0m\n" ;;
        "green") printf "\e[${style};92m${text}\e[0m\n" ;;
        "yellow") printf "\e[${style};93m${text}\e[0m\n" ;;
        "blue") printf "\e[${style};94m${text}\e[0m\n" ;;
        "magenta") printf "\e[${style};95m${text}\e[0m\n" ;;
        "cyan") printf "\e[${style};96m${text}\e[0m\n" ;;
        *) echo "${text}" ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}


check_system_requirements() {
    local errors=0
    
    # Проверяем свободное место (минимум 1GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 1048576 ]; then  # 1GB в KB
        colorized_echo red "Error: Insufficient disk space. At least 1GB required."
        errors=$((errors + 1))
    fi
    
    # Проверяем RAM (минимум 512MB)
    local available_ram=$(free -m | awk 'NR==2{print $7}')
    if [ "$available_ram" -lt 256 ]; then
        colorized_echo yellow "Warning: Low available RAM (${available_ram}MB). Performance may be affected."
    fi
    
    # Проверяем архитектуру
    if ! identify_the_operating_system_and_architecture 2>/dev/null; then
        colorized_echo red "Error: Unsupported system architecture."
        errors=$((errors + 1))
    fi
    
    return $errors
}

detect_os() {
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
        if [[ "$OS" == "Amazon Linux" ]]; then
            OS="Amazon"
        fi
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update -qq >/dev/null 2>&1
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]] || [[ "$OS" == "Amazon"* ]]; then
        PKG_MANAGER="yum"
        $PKG_MANAGER update -y -q >/dev/null 2>&1
        if [[ "$OS" != "Amazon" ]]; then
            $PKG_MANAGER install -y -q epel-release >/dev/null 2>&1
        fi
    elif [[ "$OS" == "Fedora"* ]]; then
        PKG_MANAGER="dnf"
        $PKG_MANAGER update -q -y >/dev/null 2>&1
    elif [[ "$OS" == "Arch"* ]]; then
        PKG_MANAGER="pacman"
        $PKG_MANAGER -Sy --noconfirm --quiet >/dev/null 2>&1
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER refresh --quiet >/dev/null 2>&1
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

detect_compose() {
    if docker compose >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        if [[ "$OS" == "Amazon"* ]]; then
            colorized_echo blue "Docker Compose plugin not found. Attempting manual installation..."
            mkdir -p /usr/libexec/docker/cli-plugins
            curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/libexec/docker/cli-plugins/docker-compose >/dev/null 2>&1
            chmod +x /usr/libexec/docker/cli-plugins/docker-compose
            if docker compose >/dev/null 2>&1; then
                COMPOSE='docker compose'
                colorized_echo green "Docker Compose plugin installed successfully"
            else
                colorized_echo red "Failed to install Docker Compose plugin. Please check your setup."
                exit 1
            fi
        else
            colorized_echo red "docker compose not found"
            exit 1
        fi
    fi
}

install_package() {
    if [ -z "$PKG_MANAGER" ]; then
        detect_and_update_package_manager
    fi

    PACKAGE=$1
    colorized_echo blue "Installing $PACKAGE"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER -y -qq install "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]] || [[ "$OS" == "Amazon"* ]]; then
        $PKG_MANAGER install -y -q "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "Fedora"* ]]; then
        $PKG_MANAGER install -y -q "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "Arch"* ]]; then
        $PKG_MANAGER -S --noconfirm --quiet "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "openSUSE"* ]]; then
        $PKG_MANAGER --quiet install -y "$PACKAGE" >/dev/null 2>&1
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_docker() {
    colorized_echo blue "Installing Docker"
    if [[ "$OS" == "Amazon"* ]]; then
        amazon-linux-extras enable docker >/dev/null 2>&1
        yum install -y docker >/dev/null 2>&1
        systemctl start docker
        systemctl enable docker
        colorized_echo green "Docker installed successfully on Amazon Linux"
    else
        curl -fsSL https://get.docker.com | sh
        colorized_echo green "Docker installed successfully"
    fi
}

install_remnanode_script() {
    colorized_echo blue "Installing remnanode script"
    TARGET_PATH="/usr/local/bin/$APP_NAME"
    curl -sSL $SCRIPT_URL -o $TARGET_PATH
    chmod 755 $TARGET_PATH
    colorized_echo green "Remnanode script installed successfully at $TARGET_PATH"
}

# Улучшенная функция проверки доступности портов
validate_port() {
    local port="$1"
    
    # Проверяем диапазон портов
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    
    # Проверяем, что порт не зарезервирован системой
    if [ "$port" -lt 1024 ] && [ "$(id -u)" != "0" ]; then
        colorized_echo yellow "Warning: Port $port requires root privileges"
    fi
    
    return 0
}

# Улучшенная функция получения занятых портов с fallback
get_occupied_ports() {
    local ports=""
    
    if command -v ss &>/dev/null; then
        ports=$(ss -tuln 2>/dev/null | awk 'NR>1 {print $5}' | grep -Eo '[0-9]+$' | sort -n | uniq)
    elif command -v netstat &>/dev/null; then
        ports=$(netstat -tuln 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eo '[0-9]+$' | sort -n | uniq)
    else
        colorized_echo yellow "Neither ss nor netstat found. Installing net-tools..."
        detect_os
        if install_package net-tools; then
            if command -v netstat &>/dev/null; then
                ports=$(netstat -tuln 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eo '[0-9]+$' | sort -n | uniq)
            fi
        else
            colorized_echo yellow "Could not install net-tools. Skipping port conflict check."
            return 1
        fi
    fi
    
    OCCUPIED_PORTS="$ports"
    return 0
}
is_port_occupied() {
    if echo "$OCCUPIED_PORTS" | grep -q -w "$1"; then
        return 0
    else
        return 1
    fi
}

install_latest_xray_core() {
    identify_the_operating_system_and_architecture
    mkdir -p "$DATA_DIR"
    cd "$DATA_DIR"
    
    latest_release=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep -oP '"tag_name": "\K(.*?)(?=")')
    if [ -z "$latest_release" ]; then
        colorized_echo red "Failed to fetch latest Xray-core version."
        exit 1
    fi
    
    if ! dpkg -s unzip >/dev/null 2>&1; then
        colorized_echo blue "Installing unzip..."
        detect_os
        install_package unzip
    fi
    
    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_release}/${xray_filename}"
    
    colorized_echo blue "Downloading Xray-core version ${latest_release}..."
    wget "${xray_download_url}" -q
    if [ $? -ne 0 ]; then
        colorized_echo red "Error: Failed to download Xray-core."
        exit 1
    fi
    
    colorized_echo blue "Extracting Xray-core..."
    unzip -o "${xray_filename}" -d "$DATA_DIR" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        colorized_echo red "Error: Failed to extract Xray-core."
        exit 1
    fi
    
    rm "${xray_filename}"
    chmod +x "$XRAY_FILE"
    colorized_echo green "Latest Xray-core (${latest_release}) installed at $XRAY_FILE"
}

setup_log_rotation() {
    check_running_as_root
    
    # Check if the directory exists
    if [ ! -d "$DATA_DIR" ]; then
        colorized_echo blue "Creating directory $DATA_DIR"
        mkdir -p "$DATA_DIR"
    else
        colorized_echo green "Directory $DATA_DIR already exists"
    fi
    
    # Check if logrotate is installed
    if ! command -v logrotate &> /dev/null; then
        colorized_echo blue "Installing logrotate"
        detect_os
        install_package logrotate
    else
        colorized_echo green "Logrotate is already installed"
    fi
    
    # Check if logrotate config already exists
    LOGROTATE_CONFIG="/etc/logrotate.d/remnanode"
    if [ -f "$LOGROTATE_CONFIG" ]; then
        colorized_echo yellow "Logrotate configuration already exists at $LOGROTATE_CONFIG"
        read -p "Do you want to overwrite it? (y/n): " -r overwrite
        if [[ ! $overwrite =~ ^[Yy]$ ]]; then
            colorized_echo yellow "Keeping existing logrotate configuration"
            return
        fi
    fi
    
    # Create logrotate configuration
    colorized_echo blue "Creating logrotate configuration at $LOGROTATE_CONFIG"
    cat > "$LOGROTATE_CONFIG" <<EOL
$DATA_DIR/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOL

    chmod 644 "$LOGROTATE_CONFIG"
    
    # Test logrotate configuration
    colorized_echo blue "Testing logrotate configuration"
    if logrotate -d "$LOGROTATE_CONFIG" &> /dev/null; then
        colorized_echo green "Logrotate configuration test successful"
        
        # Ask if user wants to run logrotate now
        read -p "Do you want to run logrotate now? (y/n): " -r run_now
        if [[ $run_now =~ ^[Yy]$ ]]; then
            colorized_echo blue "Running logrotate"
            if logrotate -vf "$LOGROTATE_CONFIG"; then
                colorized_echo green "Logrotate executed successfully"
            else
                colorized_echo red "Error running logrotate"
            fi
        fi
    else
        colorized_echo red "Logrotate configuration test failed"
        logrotate -d "$LOGROTATE_CONFIG"
    fi
    
    # Update docker-compose.yml to mount logs directory
    if [ -f "$COMPOSE_FILE" ]; then
        colorized_echo blue "Updating docker-compose.yml to mount logs directory"
        

        colorized_echo blue "Creating backup of docker-compose.yml..."
        backup_file=$(create_backup "$COMPOSE_FILE")
        if [ $? -eq 0 ]; then
            colorized_echo green "Backup created: $backup_file"
        else
            colorized_echo red "Failed to create backup"
            return
        fi
        

        local service_indent=$(get_service_property_indentation "$COMPOSE_FILE")
        local indent_type=""
        if [[ "$service_indent" =~ $'\t' ]]; then
            indent_type=$'\t'
        else
            indent_type="  "
        fi
        local volume_item_indent="${service_indent}${indent_type}"
        

        local escaped_service_indent=$(escape_for_sed "$service_indent")
        local escaped_volume_item_indent=$(escape_for_sed "$volume_item_indent")
        

        if grep -q "^${escaped_service_indent}volumes:" "$COMPOSE_FILE"; then
            if ! grep -q "$DATA_DIR:$DATA_DIR" "$COMPOSE_FILE"; then
                sed -i "/^${escaped_service_indent}volumes:/a\\${volume_item_indent}- $DATA_DIR:$DATA_DIR" "$COMPOSE_FILE"
                colorized_echo green "Added logs volume to existing volumes section"
            else
                colorized_echo yellow "Logs volume already exists in volumes section"
            fi
        elif grep -q "^${escaped_service_indent}# volumes:" "$COMPOSE_FILE"; then
            sed -i "s|^${escaped_service_indent}# volumes:|${service_indent}volumes:|g" "$COMPOSE_FILE"
            
            if grep -q "^${escaped_volume_item_indent}#.*$DATA_DIR:$DATA_DIR" "$COMPOSE_FILE"; then
                sed -i "s|^${escaped_volume_item_indent}#.*$DATA_DIR:$DATA_DIR|${volume_item_indent}- $DATA_DIR:$DATA_DIR|g" "$COMPOSE_FILE"
                colorized_echo green "Uncommented volumes section and logs volume line"
            else
                sed -i "/^${escaped_service_indent}volumes:/a\\${volume_item_indent}- $DATA_DIR:$DATA_DIR" "$COMPOSE_FILE"
                colorized_echo green "Uncommented volumes section and added logs volume line"
            fi
        else
            sed -i "/^${escaped_service_indent}restart: always/a\\${service_indent}volumes:\\n${volume_item_indent}- $DATA_DIR:$DATA_DIR" "$COMPOSE_FILE"
            colorized_echo green "Added new volumes section with logs volume"
        fi
        

        colorized_echo blue "Validating docker-compose.yml..."
        if validate_compose_file "$COMPOSE_FILE"; then
            colorized_echo green "Docker-compose.yml validation successful"
            cleanup_old_backups "$COMPOSE_FILE"

            if is_remnanode_up; then
                read -p "Do you want to restart RemnaNode to apply changes? (y/n): " -r restart_now
                if [[ $restart_now =~ ^[Yy]$ ]]; then
                    colorized_echo blue "Restarting RemnaNode"
                    if $APP_NAME restart -n; then
                        colorized_echo green "RemnaNode restarted successfully"
                    else
                        colorized_echo red "Failed to restart RemnaNode"
                    fi
                else
                    colorized_echo yellow "Remember to restart RemnaNode to apply changes"
                fi
            fi
        else
            colorized_echo red "Docker-compose.yml validation failed! Restoring backup..."
            if restore_backup "$backup_file" "$COMPOSE_FILE"; then
                colorized_echo green "Backup restored successfully"
            else
                colorized_echo red "Failed to restore backup!"
            fi
            return
        fi
    else
        colorized_echo yellow "Docker Compose file not found. Log directory will be mounted on next installation."
    fi
    
    colorized_echo green "Log rotation setup completed successfully"
}

install_remnanode() {

    if ! check_system_requirements; then
        colorized_echo red "System requirements check failed. Installation aborted."
        exit 1
    fi

    colorized_echo blue "Creating directory $APP_DIR"
    mkdir -p "$APP_DIR"

    colorized_echo blue "Creating directory $DATA_DIR"
    mkdir -p "$DATA_DIR"

    # Prompt the user to input the SSL certificate
    colorized_echo blue "Please paste the content of the SSL Public Key from Remnawave-Panel, press ENTER on a new line when finished: "
    SSL_CERT=""
    while IFS= read -r line; do
        if [[ -z $line ]]; then
            break
        fi
        SSL_CERT="$SSL_CERT$line"
    done

    get_occupied_ports
    while true; do
        read -p "Enter the APP_PORT (default 3000): " -r APP_PORT
        APP_PORT=${APP_PORT:-3000}
        
        if validate_port "$APP_PORT"; then
            if is_port_occupied "$APP_PORT"; then
                colorized_echo red "Port $APP_PORT is already in use. Please enter another port."
                colorized_echo blue "Occupied ports: $(echo $OCCUPIED_PORTS | tr '\n' ' ')"
            else
                break
            fi
        else
            colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
        fi
    done

    # Ask about installing Xray-core
    read -p "Do you want to install the latest version of Xray-core? (y/n): " -r install_xray
    INSTALL_XRAY=false
    if [[ "$install_xray" =~ ^[Yy]$ ]]; then
        INSTALL_XRAY=true
        install_latest_xray_core
    fi

    colorized_echo blue "Generating .env file"
    cat > "$ENV_FILE" <<EOL
### APP ###
APP_PORT=$APP_PORT

### XRAY ###
$SSL_CERT
EOL
    colorized_echo green "Environment file saved in $ENV_FILE"

    # Determine image based on --dev flag
    IMAGE_TAG="latest"
    if [ "$USE_DEV_BRANCH" == "true" ]; then
        IMAGE_TAG="dev"
    fi

    colorized_echo blue "Generating docker-compose.yml file"
    
    # Create docker-compose.yml with commented volumes section
    cat > "$COMPOSE_FILE" <<EOL
services:
  remnanode:
    container_name: $APP_NAME
    hostname: $APP_NAME
    image: remnawave/node:${IMAGE_TAG}
    env_file:
      - .env
    network_mode: host
    restart: always
EOL

    # Add volumes section (commented by default)
    if [ "$INSTALL_XRAY" == "true" ]; then
        # If Xray is installed, add uncommented volumes section
        cat >> "$COMPOSE_FILE" <<EOL
    volumes:
      - $XRAY_FILE:/usr/local/bin/xray
      # - $DATA_DIR:$DATA_DIR
EOL
    else
        # If Xray is not installed, add commented volumes section
        cat >> "$COMPOSE_FILE" <<EOL
    # volumes:
    #   - $XRAY_FILE:/usr/local/bin/xray
    #   - $DATA_DIR:$DATA_DIR
EOL
    fi

    colorized_echo green "Docker Compose file saved in $COMPOSE_FILE"
}

uninstall_remnanode_script() {
    if [ -f "/usr/local/bin/$APP_NAME" ]; then
        colorized_echo yellow "Removing remnanode script"
        rm "/usr/local/bin/$APP_NAME"
    fi
}

uninstall_remnanode() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_remnanode_docker_images() {
    images=$(docker images | grep remnawave/node | awk '{print $3}')
    if [ -n "$images" ]; then
        colorized_echo yellow "Removing Docker images of remnanode"
        for image in $images; do
            if docker rmi "$image" >/dev/null 2>&1; then
                colorized_echo yellow "Image $image removed"
            fi
        done
    fi
}

uninstall_remnanode_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

up_remnanode() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" up -d --remove-orphans
}

down_remnanode() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" down
}

show_remnanode_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs
}

follow_remnanode_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

update_remnanode_script() {
    colorized_echo blue "Updating remnanode script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/$APP_NAME
    colorized_echo green "Remnanode script updated successfully"
}

update_remnanode() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull
}

is_remnanode_installed() {
    if [ -d "$APP_DIR" ]; then
        return 0
    else
        return 1
    fi
}

is_remnanode_up() {
    if ! is_remnanode_installed; then
        return 1
    fi
    
    detect_compose
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

install_command() {
    check_running_as_root
    if is_remnanode_installed; then
        colorized_echo red "Remnanode is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi
    detect_os
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi

    detect_compose
    install_remnanode_script
    install_remnanode
    up_remnanode
    follow_remnanode_logs

    # final message
    clear
    echo
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 70))\033[0m"
    echo -e "\033[1;37m🎉 RemnaNode Successfully Installed!\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 70))\033[0m"
    echo
    
    echo -e "\033[1;37m🌐 Connection Information:\033[0m"
    printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "IP Address:" "$NODE_IP"
    printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Port:" "$APP_PORT"
    printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s:%s\033[0m\n" "Full URL:" "$NODE_IP" "$APP_PORT"
    echo
    
    echo -e "\033[1;37m📋 Next Steps:\033[0m"
    echo -e "   \033[38;5;250m1.\033[0m Use the IP and port above to set up your Remnawave Panel"
    echo -e "   \033[38;5;250m2.\033[0m Configure log rotation: \033[38;5;15msudo $APP_NAME setup-logs\033[0m"
    
    if [ "$INSTALL_XRAY" == "true" ]; then
        echo -e "   \033[38;5;250m3.\033[0m \033[1;37mXray-core is already installed and ready! ✅\033[0m"
    else
        echo -e "   \033[38;5;250m3.\033[0m Install Xray-core: \033[38;5;15msudo $APP_NAME core-update\033[0m"
    fi
    
    echo -e "   \033[38;5;250m4.\033[0m Secure with UFW: \033[38;5;15msudo ufw allow from \033[38;5;244mPANEL_IP\033[38;5;15m to any port $APP_PORT\033[0m"
    echo -e "      \033[38;5;8m(Enable UFW: \033[38;5;15msudo ufw enable\033[38;5;8m)\033[0m"
    echo
    
    echo -e "\033[1;37m🛠️  Quick Commands:\033[0m"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "status" "📊 Check service status"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "logs" "📋 View container logs"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "restart" "🔄 Restart the service"
    if [ "$INSTALL_XRAY" == "true" ]; then
        printf "   \033[38;5;15m%-15s\033[0m %s\n" "xray_log_out" "📤 View Xray logs"
    fi
    echo
    
    echo -e "\033[1;37m📁 File Locations:\033[0m"
    printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Configuration:" "$APP_DIR"
    printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Data:" "$DATA_DIR"
    if [ "$INSTALL_XRAY" == "true" ]; then
        printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Xray Binary:" "$XRAY_FILE"
    fi
    echo
    
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 70))\033[0m"
    echo -e "\033[38;5;8m💡 For all commands: \033[38;5;15msudo $APP_NAME\033[0m"
    echo -e "\033[38;5;8m📚 Project: \033[38;5;250mhttps://gig.ovh\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 70))\033[0m"
}

uninstall_command() {
    check_running_as_root
    if ! is_remnanode_installed; then
        colorized_echo red "Remnanode not installed!"
        exit 1
    fi
    
    read -p "Do you really want to uninstall Remnanode? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi
    
    detect_compose
    if is_remnanode_up; then
        down_remnanode
    fi
    uninstall_remnanode_script
    uninstall_remnanode
    uninstall_remnanode_docker_images
    
    read -p "Do you want to remove Remnanode data files too ($DATA_DIR)? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo green "Remnanode uninstalled successfully"
    else
        uninstall_remnanode_data_files
        colorized_echo green "Remnanode uninstalled successfully"
    fi
}

install_script_command() {
    check_running_as_root
    colorized_echo blue "Installing RemnaNode script globally"
    install_remnanode_script
    colorized_echo green "✅ Script installed successfully!"
    colorized_echo white "You can now run '$APP_NAME' from anywhere"
}

uninstall_script_command() {
    check_running_as_root
    if [ ! -f "/usr/local/bin/$APP_NAME" ]; then
        colorized_echo red "❌ Script not found at /usr/local/bin/$APP_NAME"
        exit 1
    fi
    
    read -p "Are you sure you want to remove the script? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo yellow "Operation cancelled"
        exit 0
    fi
    
    colorized_echo blue "Removing RemnaNode script"
    uninstall_remnanode_script
    colorized_echo green "✅ Script removed successfully!"
}

up_command() {
    help() {
        colorized_echo red "Usage: remnanode up [options]"
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs) no_logs=true ;;
            -h|--help) help; exit 0 ;;
            *) echo "Error: Invalid option: $1" >&2; help; exit 0 ;;
        esac
        shift
    done
    
    if ! is_remnanode_installed; then
        colorized_echo red "Remnanode not installed!"
        exit 1
    fi
    
    detect_compose
    
    if is_remnanode_up; then
        colorized_echo red "Remnanode already up"
        exit 1
    fi
    
    up_remnanode
    if [ "$no_logs" = false ]; then
        follow_remnanode_logs
    fi
}

down_command() {
    if ! is_remnanode_installed; then
        colorized_echo red "Remnanode not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_remnanode_up; then
        colorized_echo red "Remnanode already down"
        exit 1
    fi
    
    down_remnanode
}

restart_command() {
    help() {
        colorized_echo red "Usage: remnanode restart [options]"
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs) no_logs=true ;;
            -h|--help) help; exit 0 ;;
            *) echo "Error: Invalid option: $1" >&2; help; exit 0 ;;
        esac
        shift
    done
    
    if ! is_remnanode_installed; then
        colorized_echo red "Remnanode not installed!"
        exit 1
    fi
    
    detect_compose
    
    down_remnanode
    up_remnanode
    
    # Добавляем поддержку флага --no-logs
    if [ "$no_logs" = false ]; then
        follow_remnanode_logs
    fi
}

status_command() {
    echo -e "\033[1;37m📊 RemnaNode Status Check:\033[0m"
    echo
    
    if ! is_remnanode_installed; then
        printf "   \033[38;5;15m%-12s\033[0m \033[1;31m❌ Not Installed\033[0m\n" "Status:"
        echo -e "\033[38;5;8m   Run '\033[38;5;15msudo $APP_NAME install\033[38;5;8m' to install\033[0m"
        exit 1
    fi
    
    detect_compose
    
    if ! is_remnanode_up; then
        printf "   \033[38;5;15m%-12s\033[0m \033[1;33m⏹️  Down\033[0m\n" "Status:"
        echo -e "\033[38;5;8m   Run '\033[38;5;15msudo $APP_NAME up\033[38;5;8m' to start\033[0m"
        exit 1
    fi
    
    printf "   \033[38;5;15m%-12s\033[0m \033[1;32m✅ Running\033[0m\n" "Status:"
    
    # Дополнительная информация
    if [ -f "$ENV_FILE" ]; then
        local app_port=$(grep "APP_PORT=" "$ENV_FILE" | cut -d'=' -f2 2>/dev/null)
        if [ -n "$app_port" ]; then
            printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Port:" "$app_port"
        fi
    fi
    
    # Проверяем Xray
    local xray_version=$(get_current_xray_core_version)
    printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Xray Core:" "$xray_version"
    
    echo
}

logs_command() {
    help() {
        colorized_echo red "Usage: remnanode logs [options]"
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-follow   do not show follow logs"
    }
    
    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-follow) no_follow=true ;;
            -h|--help) help; exit 0 ;;
            *) echo "Error: Invalid option: $1" >&2; help; exit 0 ;;
        esac
        shift
    done
    
    if ! is_remnanode_installed; then
        colorized_echo red "Remnanode not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_remnanode_up; then
        colorized_echo red "Remnanode is not up."
        exit 1
    fi
    
    if [ "$no_follow" = true ]; then
        show_remnanode_logs
    else
        follow_remnanode_logs
    fi
}

# update_command() {
#     check_running_as_root
#     if ! is_remnanode_installed; then
#         echo -e "\033[1;31m❌ RemnaNode not installed!\033[0m"
#         echo -e "\033[38;5;8m   Run '\033[38;5;15msudo $APP_NAME install\033[38;5;8m' first\033[0m"
#         exit 1
#     fi
    
#     detect_compose
    
#     echo -e "\033[1;37m🔄 Starting RemnaNode Update...\033[0m"
#     echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    
#     echo -e "\033[38;5;250m📝 Step 1:\033[0m Updating script..."
#     update_remnanode_script
#     echo -e "\033[1;32m✅ Script updated\033[0m"
    
#     echo -e "\033[38;5;250m📝 Step 2:\033[0m Pulling latest version..."
#     update_remnanode
#     echo -e "\033[1;32m✅ Image updated\033[0m"
    
#     echo -e "\033[38;5;250m📝 Step 3:\033[0m Restarting services..."
#     down_remnanode
#     up_remnanode
#     echo -e "\033[1;32m✅ Services restarted\033[0m"
    
#     echo
#     echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
#     echo -e "\033[1;37m🎉 RemnaNode updated successfully!\033[0m"
#     echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
# }



update_command() {
    check_running_as_root
    if ! is_remnanode_installed; then
        echo -e "\033[1;31m❌ RemnaNode not installed!\033[0m"
        echo -e "\033[38;5;8m   Run '\033[38;5;15msudo $APP_NAME install\033[38;5;8m' first\033[0m"
        exit 1
    fi
    
    detect_compose
    
    echo -e "\033[1;37m🔄 Starting RemnaNode Update Check...\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    
    # Определяем используемый тег из docker-compose.yml
    local current_tag="latest"
    if [ -f "$COMPOSE_FILE" ]; then
        current_tag=$(grep -E "image:.*remnawave/node:" "$COMPOSE_FILE" | sed 's/.*remnawave\/node://' | tr -d '"' | tr -d "'" | xargs)
        if [ -z "$current_tag" ]; then
            current_tag="latest"
        fi
    fi
    
    echo -e "\033[38;5;250m🏷️  Current tag:\033[0m \033[38;5;15m$current_tag\033[0m"
    
    # Получаем локальную версию образа
    echo -e "\033[38;5;250m📝 Step 1:\033[0m Checking local image version..."
    local local_image_id=""
    local local_created=""
    
    if docker images remnawave/node:$current_tag --format "table {{.ID}}\t{{.CreatedAt}}" | grep -v "IMAGE ID" > /dev/null 2>&1; then
        local_image_id=$(docker images remnawave/node:$current_tag --format "{{.ID}}" | head -1)
        local_created=$(docker images remnawave/node:$current_tag --format "{{.CreatedAt}}" | head -1 | cut -d' ' -f1,2)
        
        echo -e "\033[1;32m✅ Local image found\033[0m"
        echo -e "\033[38;5;8m   Image ID: $local_image_id\033[0m"
        echo -e "\033[38;5;8m   Created: $local_created\033[0m"
    else
        echo -e "\033[1;33m⚠️  Local image not found\033[0m"
        local_image_id="none"
    fi
    
    # Проверяем обновления через docker pull
    echo -e "\033[38;5;250m📝 Step 2:\033[0m Checking for updates with docker pull..."
    
    # Сохраняем текущий образ ID для сравнения
    local old_image_id="$local_image_id"
    
    # Запускаем docker pull
    if $COMPOSE -f $COMPOSE_FILE pull --quiet 2>/dev/null; then
        # Проверяем, изменился ли ID образа после pull
        local new_image_id=$(docker images remnawave/node:$current_tag --format "{{.ID}}" | head -1)
        
        local needs_update=false
        local update_reason=""
        
        if [ "$old_image_id" = "none" ]; then
            needs_update=true
            update_reason="Local image not found, downloaded new version"
            echo -e "\033[1;33m🔄 New image downloaded\033[0m"
        elif [ "$old_image_id" != "$new_image_id" ]; then
            needs_update=true
            update_reason="New version downloaded via docker pull"
            echo -e "\033[1;33m🔄 New version detected and downloaded\033[0m"
        else
            needs_update=false
            update_reason="Already up to date (verified via docker pull)"
            echo -e "\033[1;32m✅ Already up to date\033[0m"
        fi
    else
        echo -e "\033[1;33m⚠️  Docker pull failed, assuming update needed\033[0m"
        local needs_update=true
        local update_reason="Unable to verify current version"
        local new_image_id="$old_image_id"
    fi
    
    echo
    echo -e "\033[1;37m📊 Update Analysis:\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
    
    if [ "$needs_update" = true ]; then
        echo -e "\033[1;33m🔄 Update Available\033[0m"
        echo -e "\033[38;5;250m   Reason: \033[38;5;15m$update_reason\033[0m"
        echo
        
        # Если новая версия уже загружена, автоматически продолжаем
        if [[ "$update_reason" == *"downloaded"* ]]; then
            echo -e "\033[1;37m🚀 New version already downloaded, proceeding with update...\033[0m"
        else
            read -p "Do you want to proceed with the update? (y/n): " -r confirm_update
            if [[ ! $confirm_update =~ ^[Yy]$ ]]; then
                echo -e "\033[1;31m❌ Update cancelled by user\033[0m"
                exit 0
            fi
        fi
        
        echo
        echo -e "\033[1;37m🚀 Performing Update...\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
        
        # Обновляем скрипт
        echo -e "\033[38;5;250m📝 Step 3:\033[0m Updating script..."
        if update_remnanode_script; then
            echo -e "\033[1;32m✅ Script updated\033[0m"
        else
            echo -e "\033[1;33m⚠️  Script update failed, continuing...\033[0m"
        fi
        
        # Проверяем, запущен ли контейнер
        local was_running=false
        if is_remnanode_up; then
            was_running=true
            echo -e "\033[38;5;250m📝 Step 4:\033[0m Stopping running container..."
            if down_remnanode; then
                echo -e "\033[1;32m✅ Container stopped\033[0m"
            else
                echo -e "\033[1;31m❌ Failed to stop container\033[0m"
                exit 1
            fi
        else
            echo -e "\033[38;5;250m📝 Step 4:\033[0m Container not running, skipping stop..."
        fi
        
        # Загружаем образ только если еще не загружен
        if [[ "$update_reason" != *"downloaded"* ]]; then
            echo -e "\033[38;5;250m📝 Step 5:\033[0m Pulling latest image..."
            if update_remnanode; then
                echo -e "\033[1;32m✅ Image updated\033[0m"
                # Обновляем ID образа
                new_image_id=$(docker images remnawave/node:$current_tag --format "{{.ID}}" | head -1)
            else
                echo -e "\033[1;31m❌ Failed to pull image\033[0m"
                
                # Если контейнер был запущен, пытаемся его восстановить
                if [ "$was_running" = true ]; then
                    echo -e "\033[38;5;250m🔄 Attempting to restore service...\033[0m"
                    up_remnanode
                fi
                exit 1
            fi
        else
            echo -e "\033[38;5;250m📝 Step 5:\033[0m Image already updated during check\033[0m"
        fi
        
        # Запускаем контейнер только если он был запущен ранее
        if [ "$was_running" = true ]; then
            echo -e "\033[38;5;250m📝 Step 6:\033[0m Starting updated container..."
            if up_remnanode; then
                echo -e "\033[1;32m✅ Container started\033[0m"
            else
                echo -e "\033[1;31m❌ Failed to start container\033[0m"
                exit 1
            fi
        else
            echo -e "\033[38;5;250m📝 Step 6:\033[0m Container was not running, leaving it stopped..."
        fi
        
        # Показываем финальную информацию
        echo
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        echo -e "\033[1;37m🎉 RemnaNode updated successfully!\033[0m"
        
        # Получаем новую информацию об образе
        local final_created=$(docker images remnawave/node:$current_tag --format "{{.CreatedAt}}" | head -1 | cut -d' ' -f1,2)
        
        echo -e "\033[1;37m📋 Update Summary:\033[0m"
        echo -e "\033[38;5;250m   Previous: \033[38;5;8m$old_image_id\033[0m"
        echo -e "\033[38;5;250m   Current:  \033[38;5;15m$new_image_id\033[0m"
        echo -e "\033[38;5;250m   Created:  \033[38;5;15m$final_created\033[0m"
        
        if [ "$was_running" = true ]; then
            echo -e "\033[38;5;250m   Status:   \033[1;32mRunning\033[0m"
        else
            echo -e "\033[38;5;250m   Status:   \033[1;33mStopped\033[0m"
            echo -e "\033[38;5;8m   Use '\033[38;5;15msudo $APP_NAME up\033[38;5;8m' to start\033[0m"
        fi
        
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        
    else
        echo -e "\033[1;32m✅ Already Up to Date\033[0m"
        echo -e "\033[38;5;250m   Reason: \033[38;5;15m$update_reason\033[0m"
        echo
        
        # Проверяем все равно скрипт
        echo -e "\033[38;5;250m📝 Checking script updates...\033[0m"
        
        # Получаем текущую версию скрипта
        local current_script_version="$SCRIPT_VERSION"
        
        # Получаем последнюю версию скрипта с GitHub
        local remote_script_version=$(curl -s "$SCRIPT_URL" 2>/dev/null | grep "^SCRIPT_VERSION=" | cut -d'"' -f2)
        
        if [ -n "$remote_script_version" ] && [ "$remote_script_version" != "$current_script_version" ]; then
            echo -e "\033[1;33m🔄 Script update available: \033[38;5;15mv$current_script_version\033[0m → \033[1;37mv$remote_script_version\033[0m"
            read -p "Do you want to update the script? (y/n): " -r update_script
            if [[ $update_script =~ ^[Yy]$ ]]; then
                if update_remnanode_script; then
                    echo -e "\033[1;32m✅ Script updated to v$remote_script_version\033[0m"
                    echo -e "\033[38;5;8m   Please run the command again to use the new version\033[0m"
                else
                    echo -e "\033[1;33m⚠️  Script update failed\033[0m"
                fi
            else
                echo -e "\033[38;5;8m   Script update skipped\033[0m"
            fi
        else
            echo -e "\033[1;32m✅ Script is up to date\033[0m"
        fi
        
        echo
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
        echo -e "\033[1;37m📊 Current Status:\033[0m"
        
        if is_remnanode_up; then
            echo -e "\033[38;5;250m   Container: \033[1;32mRunning ✅\033[0m"
        else
            echo -e "\033[38;5;250m   Container: \033[1;33mStopped ⏹️\033[0m"
            echo -e "\033[38;5;8m   Use '\033[38;5;15msudo $APP_NAME up\033[38;5;8m' to start\033[0m"
        fi
        
        echo -e "\033[38;5;250m   Image Tag: \033[38;5;15m$current_tag\033[0m"
        echo -e "\033[38;5;250m   Image ID:  \033[38;5;15m$local_image_id\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686') ARCH='32' ;;
            'amd64' | 'x86_64') ARCH='64' ;;
            'armv5tel') ARCH='arm32-v5' ;;
            'armv6l') ARCH='arm32-v6'; grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5' ;;
            'armv7' | 'armv7l') ARCH='arm32-v7a'; grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5' ;;
            'armv8' | 'aarch64') ARCH='arm64-v8a' ;;
            'mips') ARCH='mips32' ;;
            'mipsle') ARCH='mips32le' ;;
            'mips64') ARCH='mips64'; lscpu | grep -q "Little Endian" && ARCH='mips64le' ;;
            'mips64le') ARCH='mips64le' ;;
            'ppc64') ARCH='ppc64' ;;
            'ppc64le') ARCH='ppc64le' ;;
            'riscv64') ARCH='riscv64' ;;
            's390x') ARCH='s390x' ;;
            *) echo "error: The architecture is not supported."; exit 1 ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

get_current_xray_core_version() {
    if [ -f "$XRAY_FILE" ]; then
        version_output=$("$XRAY_FILE" -version 2>/dev/null)
        if [ $? -eq 0 ]; then
            version=$(echo "$version_output" | head -n1 | awk '{print $2}')
            echo "$version"
            return
        fi
    fi
    echo "Not installed"
}

get_xray_core() {
    identify_the_operating_system_and_architecture
    clear
    
    validate_version() {
        local version="$1"
        local response=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version")
        if echo "$response" | grep -q '"message": "Not Found"'; then
            echo "invalid"
        else
            echo "valid"
        fi
    }
    
    print_menu() {
        clear
        
        # Заголовок в монохромном стиле
        echo -e "\033[1;37m⚡ Xray-core Installer\033[0m \033[38;5;8mVersion Manager\033[0m \033[38;5;244mv$SCRIPT_VERSION\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 70))\033[0m"
        echo
        
        # Текущая версия
        current_version=$(get_current_xray_core_version)
        echo -e "\033[1;37m🌐 Current Status:\033[0m"
        printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Xray Version:" "$current_version"
        printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Architecture:" "$ARCH"
        printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Install Path:" "$XRAY_FILE"
        echo
        
        # Показываем режим выбора релизов
        echo -e "\033[1;37m🎯 Release Mode:\033[0m"
        if [ "$show_prereleases" = true ]; then
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m \033[38;5;244m(Including Pre-releases)\033[0m\n" "Current:" "All Releases"
        else
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m \033[1;37m(Stable Only)\033[0m\n" "Current:" "Stable Releases"
        fi
        echo
        
        # Доступные версии с метками
        echo -e "\033[1;37m🚀 Available Versions:\033[0m"
        for ((i=0; i<${#versions[@]}; i++)); do
            local version_num=$((i + 1))
            local version_name="${versions[i]}"
            local is_prerelease="${prereleases[i]}"
            
            # Определяем тип релиза и используем echo вместо printf
            if [ "$is_prerelease" = "true" ]; then
                echo -e "   \033[38;5;15m${version_num}:\033[0m \033[38;5;250m${version_name}\033[0m \033[38;5;244m(Pre-release)\033[0m"
            elif [ $i -eq 0 ] && [ "$is_prerelease" = "false" ]; then
                echo -e "   \033[38;5;15m${version_num}:\033[0m \033[38;5;250m${version_name}\033[0m \033[1;37m(Latest Stable)\033[0m"
            else
                echo -e "   \033[38;5;15m${version_num}:\033[0m \033[38;5;250m${version_name}\033[0m \033[38;5;8m(Stable)\033[0m"
            fi
        done
        echo
        
        # Опции
        echo -e "\033[1;37m🔧 Options:\033[0m"
        printf "   \033[38;5;15m%-3s\033[0m %s\n" "M:" "📝 Enter version manually"
        if [ "$show_prereleases" = true ]; then
            printf "   \033[38;5;15m%-3s\033[0m %s\n" "S:" "🔒 Show stable releases only"
        else
            printf "   \033[38;5;15m%-3s\033[0m %s\n" "A:" "🧪 Show all releases (including pre-releases)"
        fi
        printf "   \033[38;5;15m%-3s\033[0m %s\n" "R:" "🔄 Refresh version list"
        printf "   \033[38;5;15m%-3s\033[0m %s\n" "Q:" "❌ Quit installer"
        echo
        
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 70))\033[0m"
        echo -e "\033[1;37m📖 Usage:\033[0m"
        echo -e "   Choose a number \033[38;5;15m(1-${#versions[@]})\033[0m, \033[38;5;15mM\033[0m for manual, \033[38;5;15mA/S\033[0m to toggle releases, or \033[38;5;15mQ\033[0m to quit"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 70))\033[0m"
    }
    
    fetch_versions() {
        local include_prereleases="$1"
        echo -e "\033[1;37m🔍 Fetching Xray-core versions...\033[0m"
        
        if [ "$include_prereleases" = true ]; then
            echo -e "\033[38;5;8m   Including pre-releases...\033[0m"
            latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=8")
        else
            echo -e "\033[38;5;8m   Stable releases only...\033[0m"
            latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=15")
        fi
        
        if [ -z "$latest_releases" ] || echo "$latest_releases" | grep -q '"message":'; then
            echo -e "\033[1;31m❌ Failed to fetch versions. Please check your internet connection.\033[0m"
            return 1
        fi
        
        # Парсим JSON и извлекаем нужную информацию
        versions=()
        prereleases=()
        
        # Извлекаем данные с помощью более надежного парсинга
        local temp_file=$(mktemp)
        echo "$latest_releases" | grep -E '"(tag_name|prerelease)"' > "$temp_file"
        
        local current_version=""
        local count=0
        local max_count=6
        
        while IFS= read -r line; do
            if [[ "$line" =~ \"tag_name\":[[:space:]]*\"([^\"]+)\" ]]; then
                current_version="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ \"prerelease\":[[:space:]]*(true|false) ]]; then
                local is_prerelease="${BASH_REMATCH[1]}"
                
                # Если не показываем pre-releases, пропускаем их
                if [ "$include_prereleases" = false ] && [ "$is_prerelease" = "true" ]; then
                    current_version=""
                    continue
                fi
                
                # Добавляем версию в массивы
                if [ -n "$current_version" ] && [ $count -lt $max_count ]; then
                    versions+=("$current_version")
                    prereleases+=("$is_prerelease")
                    ((count++))
                fi
                current_version=""
            fi
        done < "$temp_file"
        
        rm "$temp_file"
        
        if [ ${#versions[@]} -eq 0 ]; then
            echo -e "\033[1;31m❌ No versions found.\033[0m"
            return 1
        fi
        
        echo -e "\033[1;32m✅ Found ${#versions[@]} versions\033[0m"
        return 0
    }
    
    # Инициализация
    local show_prereleases=false
    
    # Первоначальная загрузка версий
    if ! fetch_versions "$show_prereleases"; then
        exit 1
    fi
    
    while true; do
        print_menu
        echo -n -e "\033[1;37m> \033[0m"
        read choice
        
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#versions[@]}" ]; then
            choice=$((choice - 1))
            selected_version=${versions[choice]}
            local selected_prerelease=${prereleases[choice]}
            
            echo
            if [ "$selected_prerelease" = "true" ]; then
                echo -e "\033[1;33m⚠️  Selected pre-release version: \033[1;37m$selected_version\033[0m"
                echo -e "\033[38;5;8m   Pre-releases may contain bugs and are not recommended for production.\033[0m"
                read -p "Are you sure you want to continue? (y/n): " -r confirm_prerelease
                if [[ ! $confirm_prerelease =~ ^[Yy]$ ]]; then
                    echo -e "\033[1;31m❌ Installation cancelled.\033[0m"
                    continue
                fi
            else
                echo -e "\033[1;32m✅ Selected stable version: \033[1;37m$selected_version\033[0m"
            fi
            break
            
        elif [ "$choice" == "M" ] || [ "$choice" == "m" ]; then
            echo
            echo -e "\033[1;37m📝 Manual Version Entry:\033[0m"
            while true; do
                echo -n -e "\033[38;5;8mEnter version (e.g., v1.8.4): \033[0m"
                read custom_version
                
                if [ -z "$custom_version" ]; then
                    echo -e "\033[1;31m❌ Version cannot be empty. Please try again.\033[0m"
                    continue
                fi
                
                echo -e "\033[1;37m🔍 Validating version $custom_version...\033[0m"
                if [ "$(validate_version "$custom_version")" == "valid" ]; then
                    selected_version="$custom_version"
                    echo -e "\033[1;32m✅ Version $custom_version is valid!\033[0m"
                    break 2
                else
                    echo -e "\033[1;31m❌ Version $custom_version not found. Please try again.\033[0m"
                    echo -e "\033[38;5;8m   Hint: Check https://github.com/XTLS/Xray-core/releases\033[0m"
                    echo
                fi
            done
            
        elif [ "$choice" == "A" ] || [ "$choice" == "a" ]; then
            if [ "$show_prereleases" = false ]; then
                show_prereleases=true
                if ! fetch_versions "$show_prereleases"; then
                    show_prereleases=false
                    continue
                fi
            fi
            
        elif [ "$choice" == "S" ] || [ "$choice" == "s" ]; then
            if [ "$show_prereleases" = true ]; then
                show_prereleases=false
                if ! fetch_versions "$show_prereleases"; then
                    show_prereleases=true
                    continue
                fi
            fi
            
        elif [ "$choice" == "R" ] || [ "$choice" == "r" ]; then
            if ! fetch_versions "$show_prereleases"; then
                continue
            fi
            
        elif [ "$choice" == "Q" ] || [ "$choice" == "q" ]; then
            echo
            echo -e "\033[1;31m❌ Installation cancelled by user.\033[0m"
            exit 0
            
        else
            echo
            echo -e "\033[1;31m❌ Invalid choice: '$choice'\033[0m"
            echo -e "\033[38;5;8m   Please enter a number between 1-${#versions[@]}, M for manual, A/S to toggle releases, R to refresh, or Q to quit.\033[0m"
            echo
            echo -n -e "\033[38;5;8mPress Enter to continue...\033[0m"
            read
        fi
    done
    
    echo
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
    echo -e "\033[1;37m🚀 Starting Installation\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
    
    # Проверка и установка unzip
    if ! dpkg -s unzip >/dev/null 2>&1; then
        echo -e "\033[1;37m📦 Installing required packages...\033[0m"
        detect_os
        install_package unzip
        echo -e "\033[1;32m✅ Packages installed successfully\033[0m"
    fi
    
    mkdir -p "$DATA_DIR"
    cd "$DATA_DIR"
    
    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"
    
    # Скачивание с прогрессом
    echo -e "\033[1;37m📥 Downloading Xray-core $selected_version...\033[0m"
    echo -e "\033[38;5;8m   URL: $xray_download_url\033[0m"
    
    if wget "${xray_download_url}" -q --show-progress; then
        echo -e "\033[1;32m✅ Download completed successfully\033[0m"
    else
        echo -e "\033[1;31m❌ Download failed!\033[0m"
        echo -e "\033[38;5;8m   Please check your internet connection or try a different version.\033[0m"
        exit 1
    fi
    
    # Извлечение
    echo -e "\033[1;37m📦 Extracting Xray-core...\033[0m"
    if unzip -o "${xray_filename}" -d "$DATA_DIR" >/dev/null 2>&1; then
        echo -e "\033[1;32m✅ Extraction completed successfully\033[0m"
    else
        echo -e "\033[1;31m❌ Extraction failed!\033[0m"
        echo -e "\033[38;5;8m   The downloaded file may be corrupted.\033[0m"
        exit 1
    fi
    
    # Очистка и настройка прав
    rm "${xray_filename}"
    chmod +x "$XRAY_FILE"
    
    # Финальное сообщение
    echo
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
    echo -e "\033[1;37m🎉 Installation Complete!\033[0m"
    
    # Информация об установке
    echo -e "\033[1;37m📋 Installation Details:\033[0m"
    printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Version:" "$selected_version"
    printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Architecture:" "$ARCH"
    printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Install Path:" "$XRAY_FILE"
    printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "File Size:" "$(du -h "$XRAY_FILE" | cut -f1)"
    echo
    
    # Проверка версии
    echo -e "\033[1;37m🔍 Verifying installation...\033[0m"
    if installed_version=$("$XRAY_FILE" -version 2>/dev/null | head -n1 | awk '{print $2}'); then
        echo -e "\033[1;32m✅ Xray-core is working correctly\033[0m"
        printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Running Version:" "$installed_version"
    else
        echo -e "\033[1;31m⚠️  Installation completed but verification failed\033[0m"
        echo -e "\033[38;5;8m   The binary may not be compatible with your system\033[0m"
    fi
}



# Функция для создания резервной копии файла
create_backup() {
    local file="$1"
    local backup_file="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [ -f "$file" ]; then
        cp "$file" "$backup_file"
        echo "$backup_file"
        return 0
    else
        return 1
    fi
}

# Функция для восстановления из резервной копии
restore_backup() {
    local backup_file="$1"
    local original_file="$2"
    
    if [ -f "$backup_file" ]; then
        cp "$backup_file" "$original_file"
        return 0
    else
        return 1
    fi
}

# Функция для проверки валидности docker-compose файла
validate_compose_file() {
    local compose_file="$1"
    
    if [ ! -f "$compose_file" ]; then
        return 1
    fi
    

    local current_dir=$(pwd)
    

    cd "$(dirname "$compose_file")"
    

    if command -v docker >/dev/null 2>&1; then

        detect_compose
        
        # Проверяем синтаксис файла
        if $COMPOSE config >/dev/null 2>&1; then
            cd "$current_dir"
            return 0
        else

            colorized_echo red "Docker Compose validation errors:"
            $COMPOSE config 2>&1 | head -10
            cd "$current_dir"
            return 1
        fi
    else

        if grep -q "services:" "$compose_file" && grep -q "remnanode:" "$compose_file"; then
            cd "$current_dir"
            return 0
        else
            cd "$current_dir"
            return 1
        fi
    fi
}

# Функция для удаления старых резервных копий (оставляем только последние 5)
cleanup_old_backups() {
    local file_pattern="$1"
    local keep_count=5
    
    # Найти все файлы резервных копий и удалить старые
    ls -t ${file_pattern}.backup.* 2>/dev/null | tail -n +$((keep_count + 1)) | xargs rm -f 2>/dev/null || true
}

# Обновленная функция для определения отступов из docker-compose.yml
get_indentation_from_compose() {
    local compose_file="$1"
    local indentation=""
    
    if [ -f "$compose_file" ]; then
        # Сначала ищем строку с "remnanode:" (точное совпадение)
        local service_line=$(grep -n "remnanode:" "$compose_file" | head -1)
        if [ -n "$service_line" ]; then
            local line_content=$(echo "$service_line" | cut -d':' -f2-)
            indentation=$(echo "$line_content" | sed 's/remnanode:.*//' | grep -o '^[[:space:]]*')
        fi
        
        # Если не нашли точное совпадение, ищем любой сервис с "remna"
        if [ -z "$indentation" ]; then
            local remna_service_line=$(grep -E "^[[:space:]]*[a-zA-Z0-9_-]*remna[a-zA-Z0-9_-]*:" "$compose_file" | head -1)
            if [ -n "$remna_service_line" ]; then
                indentation=$(echo "$remna_service_line" | sed 's/[a-zA-Z0-9_-]*remna[a-zA-Z0-9_-]*:.*//' | grep -o '^[[:space:]]*')
            fi
        fi
        
        # Если не нашли сервис с "remna", пробуем найти любой сервис
        if [ -z "$indentation" ]; then
            local any_service_line=$(grep -E "^[[:space:]]*[a-zA-Z0-9_-]+:" "$compose_file" | head -1)
            if [ -n "$any_service_line" ]; then
                indentation=$(echo "$any_service_line" | sed 's/[a-zA-Z0-9_-]*:.*//' | grep -o '^[[:space:]]*')
            fi
        fi
    fi
    
    # Если ничего не нашли, используем 2 пробела по умолчанию
    if [ -z "$indentation" ]; then
        indentation="  "
    fi
    
    echo "$indentation"
}

# Обновленная функция для получения отступа для свойств сервиса
get_service_property_indentation() {
    local compose_file="$1"
    local base_indent=$(get_indentation_from_compose "$compose_file")
    local indent_type=""
    if [[ "$base_indent" =~ $'\t' ]]; then
        indent_type=$'\t'
    else
        indent_type="  "
    fi
    local property_indent=""
    if [ -f "$compose_file" ]; then
        local in_remna_service=false
        local current_service=""
        
        while IFS= read -r line; do

            if [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
                current_service=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/:[[:space:]]*$//')
                

                if [[ "$current_service" =~ remna ]]; then
                    in_remna_service=true
                else
                    in_remna_service=false
                fi
                continue
            fi
            

            if [ "$in_remna_service" = true ]; then
                local line_indent=$(echo "$line" | grep -o '^[[:space:]]*')
                

                if [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*$ ]] && [ ${#line_indent} -le ${#base_indent} ]; then
                    break
                fi
                

                if [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]] ]] && [[ ! "$line" =~ ^[[:space:]]*- ]]; then
                    property_indent=$(echo "$line" | sed 's/[a-zA-Z0-9_-]*:.*//' | grep -o '^[[:space:]]*')
                    break
                fi
            fi
        done < "$compose_file"
    fi
    
    # Если не нашли свойство, добавляем один уровень отступа к базовому
    if [ -z "$property_indent" ]; then
        property_indent="${base_indent}${indent_type}"
    fi
    
    echo "$property_indent"
}


escape_for_sed() {
    local text="$1"
    echo "$text" | sed 's/[[\.*^$()+?{|]/\\&/g' | sed 's/\t/\\t/g'
}


update_core_command() {
    check_running_as_root
    get_xray_core
    colorized_echo blue "Updating docker-compose.yml with Xray-core volume..."
    

    if [ ! -f "$COMPOSE_FILE" ]; then
        colorized_echo red "Docker Compose file not found at $COMPOSE_FILE"
        exit 1
    fi
    

    colorized_echo blue "Creating backup of docker-compose.yml..."
    backup_file=$(create_backup "$COMPOSE_FILE")
    if [ $? -eq 0 ]; then
        colorized_echo green "Backup created: $backup_file"
    else
        colorized_echo red "Failed to create backup"
        exit 1
    fi
    

    local service_indent=$(get_service_property_indentation "$COMPOSE_FILE")
    

    local indent_type=""
    if [[ "$service_indent" =~ $'\t' ]]; then
        indent_type=$'\t'
    else
        indent_type="  "
    fi
    local volume_item_indent="${service_indent}${indent_type}"
    

    local escaped_service_indent=$(escape_for_sed "$service_indent")
    local escaped_volume_item_indent=$(escape_for_sed "$volume_item_indent")
    

    if grep -q "^${escaped_service_indent}volumes:" "$COMPOSE_FILE"; then
        if ! grep -q "$XRAY_FILE:/usr/local/bin/xray" "$COMPOSE_FILE"; then
            sed -i "/^${escaped_service_indent}volumes:/a\\${volume_item_indent}- $XRAY_FILE:/usr/local/bin/xray" "$COMPOSE_FILE"
            colorized_echo green "Added Xray volume to existing volumes section"
        else
            colorized_echo yellow "Xray volume already exists in volumes section"
        fi
    elif grep -q "^${escaped_service_indent}# volumes:" "$COMPOSE_FILE"; then
        sed -i "s|^${escaped_service_indent}# volumes:|${service_indent}volumes:|g" "$COMPOSE_FILE"
        
        if grep -q "^${escaped_volume_item_indent}#.*$XRAY_FILE:/usr/local/bin/xray" "$COMPOSE_FILE"; then
            sed -i "s|^${escaped_volume_item_indent}#.*$XRAY_FILE:/usr/local/bin/xray|${volume_item_indent}- $XRAY_FILE:/usr/local/bin/xray|g" "$COMPOSE_FILE"
            colorized_echo green "Uncommented volumes section and Xray volume line"
        else
            sed -i "/^${escaped_service_indent}volumes:/a\\${volume_item_indent}- $XRAY_FILE:/usr/local/bin/xray" "$COMPOSE_FILE"
            colorized_echo green "Uncommented volumes section and added Xray volume line"
        fi
    else
        sed -i "/^${escaped_service_indent}restart: always/a\\${service_indent}volumes:\\n${volume_item_indent}- $XRAY_FILE:/usr/local/bin/xray" "$COMPOSE_FILE"
        colorized_echo green "Added new volumes section with Xray volume"
    fi
    

    colorized_echo blue "Validating docker-compose.yml..."
    if validate_compose_file "$COMPOSE_FILE"; then
        colorized_echo green "Docker-compose.yml validation successful"
        
        colorized_echo blue "Restarting RemnaNode..."

        restart_command -n
        
        colorized_echo green "Installation of XRAY-CORE version $selected_version completed."
        

        read -p "Operation completed successfully. Do you want to keep the backup file? (y/n): " -r keep_backup
        if [[ ! $keep_backup =~ ^[Yy]$ ]]; then
            rm "$backup_file"
            colorized_echo blue "Backup file removed"
        else
            colorized_echo blue "Backup file kept at: $backup_file"
        fi

        cleanup_old_backups "$COMPOSE_FILE"
        
    else
        colorized_echo red "Docker-compose.yml validation failed! Restoring backup..."
        if restore_backup "$backup_file" "$COMPOSE_FILE"; then
            colorized_echo green "Backup restored successfully"
            colorized_echo red "Please check the docker-compose.yml file manually"
        else
            colorized_echo red "Failed to restore backup! Original file may be corrupted"
            colorized_echo red "Backup location: $backup_file"
        fi
        exit 1
    fi
}


check_editor() {
    if [ -z "$EDITOR" ]; then
        if command -v nano >/dev/null 2>&1; then
            EDITOR="nano"
        elif command -v vi >/dev/null 2>&1; then
            EDITOR="vi"
        else
            detect_os
            install_package nano
            EDITOR="nano"
        fi
    fi
}

xray_log_out() {
    if ! is_remnanode_installed; then
        colorized_echo red "RemnaNode not installed!"
        exit 1
    fi
    detect_compose

    if ! is_remnanode_up; then
        colorized_echo red "RemnaNode is not running. Start it first with 'remnanode up'"
        exit 1
    fi

    # Запрашиваем ключевое слово для фильтрации
    read -p "Enter keyword to filter logs (leave empty for no filter): " keyword

    # Определяем команду для получения логов
    local log_command="docker exec -it $APP_NAME tail -n +1 -f /var/log/supervisor/xray.out.log"

    # Форматирование логов с помощью awk
    local awk_script='
    BEGIN {
        print "\033[1;37mTimestamp                Source IP:Port            Protocol  Destination                  Region         Email\033[0m"
        print "\033[38;5;8m" sprintf("%-80s", "────────────────────────────────────────────────────────────────────────────────") "\033[0m"
    }
    {
        # Парсим строку лога
        if ($0 ~ /from.*accepted.*email:/) {
            timestamp = $1 " " $2
            split($3, source, ":")
            source_ip = source[1] == "from" ? $4 : source[2]
            source_port = source_ip == $4 ? $5 : source[3]
            source_port = source_port ~ /^[0-9]+$/ ? source_port : substr(source_port, 1, index(source_port, "]")-1)
            protocol = $6
            destination = $7
            region = $8 " " $9 " " $10
            email = $NF

            # Удаляем лишние символы
            gsub(/[\[\]]/, "", region)
            gsub(/:/, "", source_port)
            gsub(/email:/, "", email)

            # Форматируем вывод с цветами
            printf "\033[38;5;250m%-23s\033[0m \033[38;5;117m%-25s\033[0m \033[38;5;178m%-9s\033[0m \033[38;5;244m%-27s\033[0m \033[38;5;68m%-15s\033[0m \033[38;5;15m%s\033[0m\n",
                   timestamp, source_ip ":" source_port, protocol, destination, region, email
        }
    }'

    if [ -z "$keyword" ]; then
        # Без фильтрации: выводим отформатированные логи
        eval "$log_command" | awk -v RS='\n' "$awk_script"
    else
        # С фильтрацией: сначала фильтруем, затем форматируем
        eval "$log_command" | grep --line-buffered "$keyword" | awk -v RS='\n' "$awk_script"
    fi
}

xray_log_err() {
        if ! is_remnanode_installed; then
            colorized_echo red "RemnaNode not installed!"
            exit 1
        fi
    
     detect_compose
 
        if ! is_remnanode_up; then
            colorized_echo red "RemnaNode is not running. Start it first with 'remnanode up'"
            exit 1
        fi

    docker exec -it $APP_NAME tail -n +1 -f /var/log/supervisor/xray.err.log
}

edit_command() {
    detect_os
    check_editor
    if [ -f "$COMPOSE_FILE" ]; then
        $EDITOR "$COMPOSE_FILE"
    else
        colorized_echo red "Compose file not found at $COMPOSE_FILE"
        exit 1
    fi
}


usage() {
    clear

    echo -e "\033[1;37m⚡ $APP_NAME\033[0m \033[38;5;8mCommand Line Interface\033[0m \033[38;5;244mv$SCRIPT_VERSION\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
    echo
    echo -e "\033[1;37m📖 Usage:\033[0m"
    echo -e "   \033[38;5;15m$APP_NAME\033[0m \033[38;5;8m<command>\033[0m \033[38;5;244m[options]\033[0m"
    echo

    echo -e "\033[1;37m🚀 Core Commands:\033[0m"
    printf "   \033[38;5;15m%-18s\033[0m %s\n" "install" "🛠️  Install RemnaNode"
    printf "   \033[38;5;15m%-18s\033[0m %s\n" "update" "⬆️  Update to latest version"
    printf "   \033[38;5;15m%-18s\033[0m %s\n" "uninstall" "🗑️  Remove RemnaNode completely"
    echo

    echo -e "\033[1;37m⚙️  Service Control:\033[0m"
    printf "   \033[38;5;250m%-18s\033[0m %s\n" "up" "▶️  Start services"
    printf "   \033[38;5;250m%-18s\033[0m %s\n" "down" "⏹️  Stop services"
    printf "   \033[38;5;250m%-18s\033[0m %s\n" "restart" "🔄 Restart services"
    printf "   \033[38;5;250m%-18s\033[0m %s\n" "status" "📊 Show service status"
    echo

    echo -e "\033[1;37m📊 Monitoring & Logs:\033[0m"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "logs" "📋 View container logs"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "xray-log-out" "📤 View Xray output logs"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "xray-log-err" "📥 View Xray error logs"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "setup-logs" "🗂️  Setup log rotation"
    echo

    echo -e "\033[1;37m⚙️  Updates & Configuration:\033[0m"
    printf "   \033[38;5;178m%-18s\033[0m %s\n" "update" "🔄 Update RemnaNode"
    printf "   \033[38;5;178m%-18s\033[0m %s\n" "core-update" "⬆️  Update Xray-core"
    printf "   \033[38;5;178m%-18s\033[0m %s\n" "edit" "📝 Edit configuration"
    echo

    echo -e "\033[1;37m📋 Information:\033[0m"
    printf "   \033[38;5;117m%-18s\033[0m %s\n" "help" "📖 Show this help"
    printf "   \033[38;5;117m%-18s\033[0m %s\n" "version" "📋 Show version info"
    printf "   \033[38;5;117m%-18s\033[0m %s\n" "menu" "🎛️  Interactive menu"
    echo

    if is_remnanode_installed && [ -f "$ENV_FILE" ]; then
        local node_port=$(grep "APP_PORT=" "$ENV_FILE" | cut -d'=' -f2 2>/dev/null || echo "")
        if [ -n "$node_port" ]; then
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 55))\033[0m"
            echo -e "\033[1;37m🌐 Node Access:\033[0m \033[38;5;117m$NODE_IP:$node_port\033[0m"
        fi
    fi

    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 55))\033[0m"
    echo -e "\033[1;37m📖 Examples:\033[0m"
    echo -e "\033[38;5;244m   sudo $APP_NAME install\033[0m"
    echo -e "\033[38;5;244m   sudo $APP_NAME core-update\033[0m"
    echo -e "\033[38;5;244m   $APP_NAME logs\033[0m"
    echo -e "\033[38;5;244m   $APP_NAME menu           # Interactive menu\033[0m"
    echo -e "\033[38;5;244m   $APP_NAME                # Same as menu\033[0m"
    echo
    echo -e "\033[38;5;8mUse '\033[38;5;15m$APP_NAME <command> --help\033[38;5;8m' for detailed command help\033[0m"
    echo
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 55))\033[0m"
    echo -e "\033[38;5;8m📚 Project: \033[38;5;250mhttps://gig.ovh\033[0m"
    echo -e "\033[38;5;8m🐛 Issues: \033[38;5;250mhttps://github.com/DigneZzZ/remnawave-scripts\033[0m"
    echo -e "\033[38;5;8m💬 Support: \033[38;5;250mhttps://t.me/remnawave\033[0m"
    echo -e "\033[38;5;8m👨‍💻 Author: \033[38;5;250mDigneZzZ\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 55))\033[0m"
}

# Функция для версии
show_version() {
    echo -e "\033[1;37m🚀 RemnaNode Management CLI\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
    echo -e "\033[38;5;250mVersion: \033[38;5;15m$SCRIPT_VERSION\033[0m"
    echo -e "\033[38;5;250mAuthor:  \033[38;5;15mDigneZzZ\033[0m"
    echo -e "\033[38;5;250mGitHub:  \033[38;5;15mhttps://github.com/DigneZzZ/remnawave-scripts\033[0m"
    echo -e "\033[38;5;250mProject: \033[38;5;15mhttps://gig.ovh\033[0m"
    echo -e "\033[38;5;250mSupport: \033[38;5;15mhttps://t.me/remnawave\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
}

main_menu() {
    while true; do
        clear
        echo -e "\033[1;37m🚀 $APP_NAME Node Management\033[0m \033[38;5;244mv$SCRIPT_VERSION\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 55))\033[0m"
        echo
        
        # Проверка статуса узла
        local menu_status="Not installed"
        local status_color="\033[38;5;244m"
        local node_port=""
        local xray_version=""
        
        if is_remnanode_installed; then
            if [ -f "$ENV_FILE" ]; then
                node_port=$(grep "APP_PORT=" "$ENV_FILE" | cut -d'=' -f2 2>/dev/null || echo "")
            fi
            
            if is_remnanode_up; then
                menu_status="Running"
                status_color="\033[1;32m"
                echo -e "${status_color}✅ Node Status: RUNNING\033[0m"
                
                # Показываем информацию о подключении
                if [ -n "$node_port" ]; then
                    echo
                    echo -e "\033[1;37m🌐 Connection Information:\033[0m"
                    printf "   \033[38;5;15m%-12s\033[0m \033[38;5;117m%s\033[0m\n" "IP Address:" "$NODE_IP"
                    printf "   \033[38;5;15m%-12s\033[0m \033[38;5;117m%s\033[0m\n" "Port:" "$node_port"
                    printf "   \033[38;5;15m%-12s\033[0m \033[38;5;117m%s:%s\033[0m\n" "Full URL:" "$NODE_IP" "$node_port"
                fi
                
                # Проверяем Xray-core
                xray_version=$(get_current_xray_core_version 2>/dev/null || echo "Not installed")
                echo
                echo -e "\033[1;37m⚙️  Components Status:\033[0m"
                printf "   \033[38;5;15m%-12s\033[0m " "Xray Core:"
                if [ "$xray_version" != "Not installed" ]; then
                    echo -e "\033[1;32m✅ $xray_version\033[0m"
                else
                    echo -e "\033[1;33m⚠️  Not installed\033[0m"
                fi
                
                # Показываем использование ресурсов
                echo
                echo -e "\033[1;37m💾 Resource Usage:\033[0m"
                
                local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "N/A")
                local mem_info=$(free -h | grep "Mem:" 2>/dev/null)
                local mem_used=$(echo "$mem_info" | awk '{print $3}' 2>/dev/null || echo "N/A")
                local mem_total=$(echo "$mem_info" | awk '{print $2}' 2>/dev/null || echo "N/A")
                
                printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s%%\033[0m\n" "CPU Usage:" "$cpu_usage"
                printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s / %s\033[0m\n" "Memory:" "$mem_used" "$mem_total"
                
                local disk_usage=$(df -h "$APP_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' 2>/dev/null || echo "N/A")
                local disk_available=$(df -h "$APP_DIR" 2>/dev/null | tail -1 | awk '{print $4}' 2>/dev/null || echo "N/A")
                
                printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s%% used, %s available\033[0m\n" "Disk Usage:" "$disk_usage" "$disk_available"
                
                # Проверяем логи
                if [ -d "$DATA_DIR" ]; then
                    local log_files=$(find "$DATA_DIR" -name "*.log" 2>/dev/null | wc -l)
                    if [ "$log_files" -gt 0 ]; then
                        local total_log_size=$(du -sh "$DATA_DIR"/*.log 2>/dev/null | awk '{total+=$1} END {print total"K"}' | sed 's/KK/K/')
                        printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s files (%s)\033[0m\n" "Log Files:" "$log_files" "$total_log_size"
                    fi
                fi
                
            else
                menu_status="Stopped"
                status_color="\033[1;31m"
                echo -e "${status_color}❌ Node Status: STOPPED\033[0m"
                echo -e "\033[38;5;244m   Services are installed but not running\033[0m"
                echo -e "\033[38;5;244m   Use option 2 to start the node\033[0m"
            fi
        else
            echo -e "${status_color}📦 Node Status: NOT INSTALLED\033[0m"
            echo -e "\033[38;5;244m   Use option 1 to install RemnaNode\033[0m"
        fi
        
        echo
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 55))\033[0m"
        echo
        echo -e "\033[1;37m🚀 Installation & Management:\033[0m"
        echo -e "   \033[38;5;15m1)\033[0m 🛠️  Install RemnaNode"
        echo -e "   \033[38;5;15m2)\033[0m ▶️  Start node services"
        echo -e "   \033[38;5;15m3)\033[0m ⏹️  Stop node services"
        echo -e "   \033[38;5;15m4)\033[0m 🔄 Restart node services"
        echo -e "   \033[38;5;15m5)\033[0m 🗑️  Uninstall RemnaNode"
        echo
        echo -e "\033[1;37m📊 Monitoring & Logs:\033[0m"
        echo -e "   \033[38;5;15m6)\033[0m 📊 Show node status"
        echo -e "   \033[38;5;15m7)\033[0m 📋 View container logs"
        echo -e "   \033[38;5;15m8)\033[0m 📤 View Xray output logs"
        echo -e "   \033[38;5;15m9)\033[0m 📥 View Xray error logs"
        echo
        echo -e "\033[1;37m⚙️  Updates & Configuration:\033[0m"
        echo -e "   \033[38;5;15m10)\033[0m 🔄 Update RemnaNode"
        echo -e "   \033[38;5;15m11)\033[0m ⬆️  Update Xray-core"
        echo -e "   \033[38;5;15m12)\033[0m 📝 Edit configuration"
        echo -e "   \033[38;5;15m13)\033[0m 🗂️  Setup log rotation"
        echo
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 55))\033[0m"
        echo -e "\033[38;5;15m   0)\033[0m 🚪 Exit to terminal"
        echo
        
        # Показываем подсказки в зависимости от состояния
        case "$menu_status" in
            "Not installed")
                echo -e "\033[1;34m💡 Tip: Start with option 1 to install RemnaNode\033[0m"
                ;;
            "Stopped")
                echo -e "\033[1;34m💡 Tip: Use option 2 to start the node\033[0m"
                ;;
            "Running")
                if [ "$xray_version" = "Not installed" ]; then
                    echo -e "\033[1;34m💡 Tip: Install Xray-core with option 11 for better performance\033[0m"
                else
                    echo -e "\033[1;34m💡 Tip: Check logs (7-9) or configure log rotation (13)\033[0m"
                fi
                ;;
        esac
        
        echo -e "\033[38;5;8mRemnaNode CLI v$SCRIPT_VERSION by DigneZzZ • gig.ovh\033[0m"
        echo
        read -p "$(echo -e "\033[1;37mSelect option [0-13]:\033[0m ")" choice

        case "$choice" in
            1) install_command; read -p "Press Enter to continue..." ;;
            2) up_command; read -p "Press Enter to continue..." ;;
            3) down_command; read -p "Press Enter to continue..." ;;
            4) restart_command; read -p "Press Enter to continue..." ;;
            5) uninstall_command; read -p "Press Enter to continue..." ;;
            6) status_command; read -p "Press Enter to continue..." ;;
            7) logs_command; read -p "Press Enter to continue..." ;;
            8) xray_log_out; read -p "Press Enter to continue..." ;;
            9) xray_log_err; read -p "Press Enter to continue..." ;;
            10) update_command; read -p "Press Enter to continue..." ;;
            11) update_core_command; read -p "Press Enter to continue..." ;;
            12) edit_command; read -p "Press Enter to continue..." ;;
            13) setup_log_rotation; read -p "Press Enter to continue..." ;;
            0) clear; exit 0 ;;
            *) 
                echo -e "\033[1;31m❌ Invalid option!\033[0m"
                sleep 1
                ;;
        esac
    done
}

# Главная обработка команд
case "${COMMAND:-menu}" in
    install) install_command ;;
    install-script) install_script_command ;;
    uninstall) uninstall_command ;;
    uninstall-script) uninstall_script_command ;;
    up) up_command ;;
    down) down_command ;;
    restart) restart_command ;;
    status) status_command ;;
    logs) logs_command ;;
    xray-log-out) xray_log_out ;;
    xray-log-err) xray_log_err ;;
    update) update_command ;;
    core-update) update_core_command ;;
    edit) edit_command ;;
    setup-logs) setup_log_rotation ;;
    help|--help|-h) usage ;;
    version|--version|-v) show_version ;;
    menu) main_menu ;;
    "") main_menu ;;
    *) 
        echo -e "\033[1;31m❌ Unknown command: $COMMAND\033[0m"
        echo -e "\033[38;5;244mUse '\033[38;5;15m$APP_NAME help\033[38;5;244m' for available commands\033[0m"
        exit 1
        ;;
esac

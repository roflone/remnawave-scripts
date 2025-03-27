#!/usr/bin/env bash
set -e

while [[ $# -gt 0 ]]; do
    key="$1"
    
    case $key in
        install|update|uninstall|up|down|restart|status|logs|core-update|install-script|uninstall-script|edit)
            COMMAND="$1"
            shift # past argument
        ;;
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
        *)
            shift # past unknown argument
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

get_occupied_ports() {
    if command -v ss &>/dev/null; then
        OCCUPIED_PORTS=$(ss -tuln | awk '{print $5}' | grep -Eo '[0-9]+$' | sort | uniq)
    elif command -v netstat &>/dev/null; then
        OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort | uniq)
    else
        colorized_echo yellow "Neither ss nor netstat found. Attempting to install net-tools."
        detect_os
        if [[ "$OS" == "Amazon"* ]]; then
            yum install -y net-tools >/dev/null 2>&1
        else
            install_package net-tools
        fi
        if command -v netstat &>/dev/null; then
            OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort | uniq)
        else
            colorized_echo red "Failed to install net-tools. Please install it manually."
            exit 1
        fi
    fi
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

install_remnanode() {
    mkdir -p "$APP_DIR"
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

    # Prompt the user to enter the port
    while true; do
        read -p "Enter the APP_PORT (default 3000): " -r APP_PORT
        if [[ -z "$APP_PORT" ]]; then
            APP_PORT=3000
        fi
        if [[ "$APP_PORT" -ge 1 && "$APP_PORT" -le 65535 ]]; then
            if is_port_occupied "$APP_PORT"; then
                colorized_echo red "Port $APP_PORT is already in use. Please enter another port."
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
    cat > "$COMPOSE_FILE" <<EOL
services:
  remnanode:
    container_name: $APP_NAME
    hostname: $APP_NAME
    image: remnawave/node:${IMAGE_TAG}
    env_file:
      - .env
    network_mode: host
EOL

    # Add volumes only if Xray-core was installed
    if [ "$INSTALL_XRAY" == "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOL
    volumes:
      - $XRAY_FILE:/usr/local/bin/xray
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
    echo "Use your IP: $NODE_IP and port: $APP_PORT to setup your Remnawave Panel"
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
}

status_command() {
    if ! is_remnanode_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi
    
    detect_compose
    
    if ! is_remnanode_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi
    
    echo -n "Status: "
    colorized_echo green "Up"
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

update_command() {
    check_running_as_root
    if ! is_remnanode_installed; then
        colorized_echo red "Remnanode not installed!"
        exit 1
    fi
    
    detect_compose
    
    update_remnanode_script
    colorized_echo blue "Pulling latest version"
    update_remnanode
    
    colorized_echo blue "Restarting Remnanode services"
    down_remnanode
    up_remnanode
    
    colorized_echo blue "Remnanode updated successfully"
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
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;32m      Xray-core Installer     \033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        current_version=$(get_current_xray_core_version)
        echo -e "\033[1;33m>>>> Current Xray-core version: \033[1;1m$current_version\033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;33mAvailable Xray-core versions:\033[0m"
        for ((i=0; i<${#versions[@]}; i++)); do
            echo -e "\033[1;34m$((i + 1)):\033[0m ${versions[i]}"
        done
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;35mM:\033[0m Enter a version manually"
        echo -e "\033[1;31mQ:\033[0m Quit"
        echo -e "\033[1;32m==============================\033[0m"
    }
    
    latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=5")
    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))
    
    while true; do
        print_menu
        read -p "Choose a version to install (1-${#versions[@]}), or press M to enter manually, Q to quit: " choice
        
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#versions[@]}" ]; then
            choice=$((choice - 1))
            selected_version=${versions[choice]}
            break
        elif [ "$choice" == "M" ] || [ "$choice" == "m" ]; then
            while true; do
                read -p "Enter the version manually (e.g., v1.2.3): " custom_version
                if [ "$(validate_version "$custom_version")" == "valid" ]; then
                    selected_version="$custom_version"
                    break 2
                else
                    echo -e "\033[1;31mInvalid version or version does not exist. Please try again.\033[0m"
                fi
            done
        elif [ "$choice" == "Q" ] || [ "$choice" == "q" ]; then
            echo -e "\033[1;31mExiting.\033[0m"
            exit 0
        else
            echo -e "\033[1;31mInvalid choice. Please try again.\033[0m"
            sleep 2
        fi
    done
    
    echo -e "\033[1;32mSelected version $selected_version for installation.\033[0m"
    
    if ! dpkg -s unzip >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package unzip
    fi
    
    mkdir -p "$DATA_DIR"
    cd "$DATA_DIR"
    
    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"
    
    echo -e "\033[1;33mDownloading Xray-core version ${selected_version}...\033[0m"
    wget "${xray_download_url}" -q
    if [ $? -ne 0 ]; then
        echo -e "\033[1;31mError: Failed to download Xray-core. Please check your internet connection or the version.\033[0m"
        exit 1
    fi
    
    echo -e "\033[1;33mExtracting Xray-core...\033[0m"
    unzip -o "${xray_filename}" -d "$DATA_DIR" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "\033[1;31mError: Failed to extract Xray-core. Please check the downloaded file.\033[0m"
        exit 1
    fi
    
    rm "${xray_filename}"
    chmod +x "$XRAY_FILE"
}

update_core_command() {
    check_running_as_root
    get_xray_core
    colorized_echo blue "Updating docker-compose.yml with Xray-core volume..."
    if ! grep -q "$XRAY_FILE:/usr/local/bin/xray" "$COMPOSE_FILE"; then
        echo "    volumes:" >> "$COMPOSE_FILE"
        echo "      - $XRAY_FILE:/usr/local/bin/xray" >> "$COMPOSE_FILE"
    fi
    colorized_echo red "Restarting Remnanode..."
    $APP_NAME restart -n
    colorized_echo blue "Installation of XRAY-CORE version $selected_version completed."
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
    colorized_echo blue "================================"
    colorized_echo magenta "       $APP_NAME Node CLI Help"
    colorized_echo blue "================================"
    colorized_echo cyan "Usage:"
    echo "  $APP_NAME [command]"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              $(tput sgr0)– Start services"
    colorized_echo yellow "  down            $(tput sgr0)– Stop services"
    colorized_echo yellow "  restart         $(tput sgr0)– Restart services"
    colorized_echo yellow "  status          $(tput sgr0)– Show status"
    colorized_echo yellow "  logs            $(tput sgr0)– Show logs"
    colorized_echo yellow "  install         $(tput sgr0)– Install/reinstall Remnanode"
    colorized_echo yellow "  update          $(tput sgr0)– Update to latest version"
    colorized_echo yellow "  uninstall       $(tput sgr0)– Uninstall Remnanode"
    colorized_echo yellow "  install-script  $(tput sgr0)– Install Remnanode script"
    colorized_echo yellow "  uninstall-script  $(tput sgr0)– Uninstall Remnanode script"
    colorized_echo yellow "  edit            $(tput sgr0)– Edit docker-compose.yml (via nano or vi)"
    colorized_echo yellow "  core-update     $(tput sgr0)– Update/Change Xray core"
    
    echo
    colorized_echo cyan "Options for install:"
    colorized_echo yellow "  --dev           $(tput sgr0)– Use remnawave/node:dev instead of latest"
    
    echo
    colorized_echo cyan "Node Information:"
    colorized_echo magenta "  Node IP: $NODE_IP"
    echo
    current_version=$(get_current_xray_core_version)
    colorized_echo cyan "Current Xray-core version: " 1
    colorized_echo magenta "$current_version" 1
    echo
    DEFAULT_APP_PORT="3000"
    if [ -f "$ENV_FILE" ]; then
        APP_PORT=$(grep "APP_PORT=" "$ENV_FILE" | cut -d'=' -f2)
    fi
    APP_PORT=${APP_PORT:-$DEFAULT_APP_PORT}
    colorized_echo cyan "Port:"
    colorized_echo magenta "  App port: $APP_PORT"
    colorized_echo blue "================================="
    echo
}

case "$COMMAND" in
    install) install_command ;;
    update) update_command ;;
    uninstall) uninstall_command ;;
    up) up_command ;;
    down) down_command ;;
    restart) restart_command ;;
    status) status_command ;;
    logs) logs_command ;;
    core-update) update_core_command ;;
    install-script) install_remnanode_script ;;
    uninstall-script) uninstall_remnanode_script ;;
    edit) edit_command ;;
    *) usage ;;
esac

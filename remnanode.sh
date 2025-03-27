#!/usr/bin/env bash
set -e

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        install|update|uninstall|up|down|restart|status|logs|core-update|install-script|uninstall-script|edit)
            COMMAND="$1"
            shift
        ;;
        --name)
            if [[ "$COMMAND" == "install" || "$COMMAND" == "install-script" ]]; then
                APP_NAME="$2"
                shift
            else
                echo "Error: --name parameter is only allowed with 'install' or 'install-script' commands."
                exit 1
            fi
            shift
        ;;
        --dev)
            if [[ "$COMMAND" == "install" ]]; then
                USE_DEV_BRANCH="true"
            else
                echo "Error: --dev parameter is only allowed with 'install' command."
                exit 1
            fi
            shift
        ;;
        *)
            shift
        ;;
    esac
done

NODE_IP=$(curl -s -4 ifconfig.io || curl -s -6 ifconfig.io)

if [[ "$COMMAND" == "install" || "$COMMAND" == "install-script" ]] && [ -z "$APP_NAME" ]; then
    APP_NAME="remnanode"
fi
[ -z "$APP_NAME" ] && APP_NAME="${0##*/}" && APP_NAME="${APP_NAME%.*}"

INSTALL_DIR="/opt"
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
XRAY_FILE="$DATA_DIR/xray"
SCRIPT_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"

colorized_echo() {
    local color=$1 text=$2 style=${3:-0}
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
    [ "$(id -u)" != "0" ] && { colorized_echo red "This command must be run as root."; exit 1; }
}

detect_os() {
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
        [[ "$OS" == "Amazon Linux" ]] && OS="Amazon"
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
    case "$OS" in
        "Ubuntu"*|"Debian"*) PKG_MANAGER="apt-get"; $PKG_MANAGER update -qq >/dev/null 2>&1 ;;
        "CentOS"*|"AlmaLinux"*|"Amazon"*) 
            PKG_MANAGER="yum"; $PKG_MANAGER update -y -q >/dev/null 2>&1
            [[ "$OS" != "Amazon" ]] && $PKG_MANAGER install -y -q epel-release >/dev/null 2>&1 ;;
        "Fedora"*) PKG_MANAGER="dnf"; $PKG_MANAGER update -q -y >/dev/null 2>&1 ;;
        "Arch"*) PKG_MANAGER="pacman"; $PKG_MANAGER -Sy --noconfirm --quiet >/dev/null 2>&1 ;;
        "openSUSE"*) PKG_MANAGER="zypper"; $PKG_MANAGER refresh --quiet >/dev/null 2>&1 ;;
        *) colorized_echo red "Unsupported operating system"; exit 1 ;;
    esac
}

detect_compose() {
    if docker compose >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        if [[ "$OS" == "Amazon"* ]]; then
            colorized_echo blue "Installing Docker Compose plugin..."
            mkdir -p /usr/libexec/docker/cli-plugins
            curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/libexec/docker/cli-plugins/docker-compose >/dev/null 2>&1
            chmod +x /usr/libexec/docker/cli-plugins/docker-compose
            docker compose >/dev/null 2>&1 && COMPOSE='docker compose' || { colorized_echo red "Failed to install Docker Compose plugin."; exit 1; }
        else
            colorized_echo red "docker compose not found"
            exit 1
        fi
    fi
}

install_package() {
    [ -z "$PKG_MANAGER" ] && detect_and_update_package_manager
    local PACKAGE=$1
    colorized_echo blue "Installing $PACKAGE"
    case "$OS" in
        "Ubuntu"*|"Debian"*) $PKG_MANAGER -y -qq install "$PACKAGE" >/dev/null 2>&1 ;;
        "CentOS"*|"AlmaLinux"*|"Amazon"*) $PKG_MANAGER install -y -q "$PACKAGE" >/dev/null 2>&1 ;;
        "Fedora"*) $PKG_MANAGER install -y -q "$PACKAGE" >/dev/null 2>&1 ;;
        "Arch"*) $PKG_MANAGER -S --noconfirm --quiet "$PACKAGE" >/dev/null 2>&1 ;;
        "openSUSE"*) $PKG_MANAGER --quiet install -y "$PACKAGE" >/dev/null 2>&1 ;;
        *) colorized_echo red "Unsupported operating system"; exit 1 ;;
    esac
}

install_docker() {
    colorized_echo blue "Installing Docker"
    if [[ "$OS" == "Amazon"* ]]; then
        amazon-linux-extras enable docker >/dev/null 2>&1
        yum install -y docker >/dev/null 2>&1
        systemctl start docker && systemctl enable docker
    else
        curl -fsSL https://get.docker.com | sh
    fi
    colorized_echo green "Docker installed successfully"
}

install_remnanode_script() {
    colorized_echo blue "Installing remnanode script"
    curl -sSL "$SCRIPT_URL" -o "/usr/local/bin/$APP_NAME" || { colorized_echo red "Failed to download script."; exit 1; }
    chmod 755 "/usr/local/bin/$APP_NAME"
    colorized_echo green "Remnanode script installed successfully at /usr/local/bin/$APP_NAME"
}

get_occupied_ports() {
    if command -v ss >/dev/null 2>&1; then
        OCCUPIED_PORTS=$(ss -tuln | awk '{print $5}' | grep -Eo '[0-9]+$' | sort -u)
    elif command -v netstat >/dev/null 2>&1; then
        OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort -u)
    else
        colorized_echo yellow "Installing net-tools..."
        detect_os
        [[ "$OS" == "Amazon"* ]] && yum install -y net-tools >/dev/null 2>&1 || install_package net-tools
        OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort -u) || { colorized_echo red "Failed to install net-tools."; exit 1; }
    fi
}

is_port_occupied() {
    echo "$OCCUPIED_PORTS" | grep -q -w "$1"
}

install_latest_xray_core() {
    identify_the_operating_system_and_architecture
    mkdir -p "$DATA_DIR" || { colorized_echo red "Failed to create $DATA_DIR."; exit 1; }
    cd "$DATA_DIR"
    
    latest_release=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep -oP '"tag_name": "\K(.*?)(?=")') || { colorized_echo red "Failed to fetch latest Xray-core version."; exit 1; }
    
    command -v unzip >/dev/null 2>&1 || { colorized_echo blue "Installing unzip..."; detect_os; install_package unzip; }
    
    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_release}/${xray_filename}"
    
    colorized_echo blue "Downloading Xray-core version ${latest_release}..."
    wget -q "$xray_download_url" || { colorized_echo red "Failed to download Xray-core."; exit 1; }
    
    colorized_echo blue "Extracting Xray-core..."
    unzip -o "$xray_filename" -d "$DATA_DIR" >/dev/null 2>&1 || { colorized_echo red "Failed to extract Xray-core."; exit 1; }
    
    rm "$xray_filename"
    chmod +x "$XRAY_FILE"
    colorized_echo green "Latest Xray-core (${latest_release}) installed at $XRAY_FILE"
}

install_remnanode() {
    mkdir -p "$APP_DIR" "$DATA_DIR" || { colorized_echo red "Failed to create directories."; exit 1; }

    colorized_echo blue "Please paste the content of the SSL Public Key from Remnawave-Panel, press ENTER on a new line when finished: "
    SSL_CERT=""
    while IFS= read -r line; do
        [ -z "$line" ] && break
        SSL_CERT="$SSL_CERT$line"
    done

    get_occupied_ports
    while true; do
        read -p "Enter the APP_PORT (default 3000): " -r APP_PORT
        APP_PORT=${APP_PORT:-3000}
        if [[ "$APP_PORT" =~ ^[0-9]+$ && "$APP_PORT" -ge 1 && "$APP_PORT" -le 65535 ]]; then
            is_port_occupied "$APP_PORT" && { colorized_echo red "Port $APP_PORT is already in use."; continue; }
            break
        else
            colorized_echo red "Invalid port. Use a number between 1 and 65535."
        fi
    done

    read -p "Do you want to install the latest version of Xray-core? (y/n): " -r install_xray
    INSTALL_XRAY=false
    [[ "$install_xray" =~ ^[Yy]$ ]] && { INSTALL_XRAY=true; install_latest_xray_core; }

    colorized_echo blue "Generating .env file"
    printf "### APP ###\nAPP_PORT=%s\n\n### XRAY ###\nSSL_CERT=\"%s\"\n" "$APP_PORT" "$SSL_CERT" > "$ENV_FILE" || { colorized_echo red "Failed to write $ENV_FILE."; exit 1; }
    colorized_echo green "Environment file saved in $ENV_FILE"

    IMAGE_TAG="latest"
    [ "$USE_DEV_BRANCH" == "true" ] && IMAGE_TAG="dev"

    colorized_echo blue "Generating docker-compose.yml file"
    cat > "$COMPOSE_FILE" <<EOL || { colorized_echo red "Failed to write $COMPOSE_FILE."; exit 1; }
services:
  remnanode:
    container_name: $APP_NAME
    hostname: $APP_NAME
    image: remnawave/node:${IMAGE_TAG}
    env_file:
      - .env
    network_mode: host
EOL
    $INSTALL_XRAY && printf "    volumes:\n      - %s:/usr/local/bin/xray\n" "$XRAY_FILE" >> "$COMPOSE_FILE"
    colorized_echo green "Docker Compose file saved in $COMPOSE_FILE"
}

uninstall_remnanode_script() {
    [ -f "/usr/local/bin/$APP_NAME" ] && { colorized_echo yellow "Removing remnanode script"; rm "/usr/local/bin/$APP_NAME"; }
}

uninstall_remnanode() {
    [ -d "$APP_DIR" ] && { colorized_echo yellow "Removing directory: $APP_DIR"; rm -r "$APP_DIR"; }
}

uninstall_remnanode_docker_images() {
    images=$(docker images -q remnawave/node | sort -u)
    [ -n "$images" ] && { colorized_echo yellow "Removing Docker images of remnanode"; docker rmi $images >/dev/null 2>&1; }
}

uninstall_remnanode_data_files() {
    [ -d "$DATA_DIR" ] && { colorized_echo yellow "Removing directory: $DATA_DIR"; rm -r "$DATA_DIR"; }
}

up_remnanode() { $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d --remove-orphans; }
down_remnanode() { $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down; }
show_remnanode_logs() { $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" logs; }
follow_remnanode_logs() { $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" logs -f; }

update_remnanode_script() {
    colorized_echo blue "Updating remnanode script"
    curl -sSL "$SCRIPT_URL" -o "/usr/local/bin/$APP_NAME" || { colorized_echo red "Failed to update script."; exit 1; }
    chmod 755 "/usr/local/bin/$APP_NAME"
    colorized_echo green "Remnanode script updated successfully"
}

update_remnanode() { $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" pull; }

is_remnanode_installed() { [ -d "$APP_DIR" ]; }
is_remnanode_up() { [ -n "$($COMPOSE -f "$COMPOSE_FILE" ps -q -a)" ]; }

install_command() {
    check_running_as_root
    if is_remnanode_installed; then
        colorized_echo red "Remnanode is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n) "
        [[ ! $REPLY =~ ^[Yy]$ ]] && { colorized_echo red "Aborted installation"; exit 1; }
    fi
    detect_os
    command -v curl >/dev/null 2>&1 || install_package curl
    command -v docker >/dev/null 2>&1 || install_docker
    detect_compose
    install_remnanode_script
    install_remnanode
    up_remnanode
    follow_remnanode_logs
    echo "Use your IP: $NODE_IP and port: $APP_PORT to setup your Remnawave Panel"
}

uninstall_command() {
    check_running_as_root
    is_remnanode_installed || { colorized_echo red "Remnanode not installed!"; exit 1; }
    read -p "Do you really want to uninstall Remnanode? (y/n) "
    [[ ! $REPLY =~ ^[Yy]$ ]] && { colorized_echo red "Aborted"; exit 1; }
    detect_compose
    is_remnanode_up && down_remnanode
    uninstall_remnanode_script
    uninstall_remnanode
    uninstall_remnanode_docker_images
    read -p "Do you want to remove Remnanode data files too ($DATA_DIR)? (y/n) "
    [[ $REPLY =~ ^[Yy]$ ]] && uninstall_remnanode_data_files
    colorized_echo green "Remnanode uninstalled successfully"
}

up_command() {
    help() { colorized_echo red "Usage: remnanode up [options]\nOPTIONS:\n  -h, --help        display this help message\n  -n, --no-logs     do not follow logs after starting"; }
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs) no_logs=true ;;
            -h|--help) help; exit 0 ;;
            *) echo "Error: Invalid option: $1" >&2; help; exit 0 ;;
        esac
        shift
    done
    is_remnanode_installed || { colorized_echo red "Remnanode not installed!"; exit 1; }
    detect_compose
    is_remnanode_up && { colorized_echo red "Remnanode already up"; exit 1; }
    up_remnanode
    $no_logs || follow_remnanode_logs
}

down_command() {
    is_remnanode_installed || { colorized_echo red "Remnanode not installed!"; exit 1; }
    detect_compose
    is_remnanode_up || { colorized_echo red "Remnanode already down"; exit 1; }
    down_remnanode
}

restart_command() {
    help() { colorized_echo red "Usage: remnanode restart [options]\nOPTIONS:\n  -h, --help        display this help message\n  -n, --no-logs     do not follow logs after starting"; }
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs) no_logs=true ;;
            -h|--help) help; exit 0 ;;
            *) echo "Error: Invalid option: $1" >&2; help; exit 0 ;;
        esac
        shift
    done
    is_remnanode_installed || { colorized_echo red "Remnanode not installed!"; exit 1; }
    detect_compose
    down_remnanode
    up_remnanode
}

status_command() {
    is_remnanode_installed || { echo -n "Status: "; colorized_echo red "Not Installed"; exit 1; }
    detect_compose
    is_remnanode_up && { echo -n "Status: "; colorized_echo green "Up"; } || { echo -n "Status: "; colorized_echo blue "Down"; exit 1; }
}

logs_command() {
    help() { colorized_echo red "Usage: remnanode logs [options]\nOPTIONS:\n  -h, --help        display this help message\n  -n, --no-follow   do not show follow logs"; }
    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-follow) no_follow=true ;;
            -h|--help) help; exit 0 ;;
            *) echo "Error: Invalid option: $1" >&2; help; exit 0 ;;
        esac
        shift
    done
    is_remnanode_installed || { colorized_echo red "Remnanode not installed!"; exit 1; }
    detect_compose
    is_remnanode_up || { colorized_echo red "Remnanode is not up."; exit 1; }
    $no_follow && show_remnanode_logs || follow_remnanode_logs
}

update_command() {
    check_running_as_root
    is_remnanode_installed || { colorized_echo red "Remnanode not installed!"; exit 1; }
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
    [[ "$(uname)" != 'Linux' ]] && { echo "error: This operating system is not supported."; exit 1; }
    case "$(uname -m)" in
        'i386'|'i686') ARCH='32' ;;
        'amd64'|'x86_64') ARCH='64' ;;
        'armv5tel') ARCH='arm32-v5' ;;
        'armv6l') ARCH='arm32-v6'; grep -qw 'vfp' /proc/cpuinfo || ARCH='arm32-v5' ;;
        'armv7'|'armv7l') ARCH='arm32-v7a'; grep -qw 'vfp' /proc/cpuinfo || ARCH='arm32-v5' ;;
        'armv8'|'aarch64') ARCH='arm64-v8a' ;;
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
}

get_current_xray_core_version() {
    [ -f "$XRAY_FILE" ] && { version_output=$("$XRAY_FILE" -version 2>/dev/null) && echo "$version_output" | head -n1 | awk '{print $2}' && return; }
    echo "Not installed"
}

get_xray_core() {
    identify_the_operating_system_and_architecture
    clear
    validate_version() {
        curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$1" | grep -q '"message": "Not Found"' && echo "invalid" || echo "valid"
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
        for ((i=0; i<${#versions[@]}; i++)); do echo -e "\033[1;34m$((i + 1)):\033[0m ${versions[i]}"; done
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
        if [[ "$choice" =~ ^[1-9][0-9]*$ && "$choice" -le "${#versions[@]}" ]]; then
            selected_version=${versions[$((choice - 1))]}
            break
        elif [[ "$choice" =~ ^[Mm]$ ]]; then
            while true; do
                read -p "Enter the version manually (e.g., v1.2.3): " custom_version
                [ "$(validate_version "$custom_version")" == "valid" ] && { selected_version="$custom_version"; break 2; }
                echo -e "\033[1;31mInvalid version or version does not exist. Please try again.\033[0m"
            done
        elif [[ "$choice" =~ ^[Qq]$ ]]; then
            echo -e "\033[1;31mExiting.\033[0m"
            exit 0
        else
            echo -e "\033[1;31mInvalid choice. Please try again.\033[0m"
            sleep 2
        fi
    done
    
    echo -e "\033[1;32mSelected version $selected_version for installation.\033[0m"
    command -v unzip >/dev/null 2>&1 || { echo -e "\033[1;33mInstalling unzip...\033[0m"; detect_os; install_package unzip; }
    mkdir -p "$DATA_DIR"
    cd "$DATA_DIR"
    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"
    
    echo -e "\033[1;33mDownloading Xray-core version ${selected_version}...\033[0m"
    wget -q "$xray_download_url" || { echo -e "\033[1;31mError: Failed to download Xray-core.\033[0m"; exit 1; }
    echo -e "\033[1;33mExtracting Xray-core...\033[0m"
    unzip -o "$xray_filename" -d "$DATA_DIR" >/dev/null 2>&1 || { echo -e "\033[1;31mError: Failed to extract Xray-core.\033[0m"; exit 1; }
    rm "$xray_filename"
    chmod +x "$XRAY_FILE"
}

update_core_command() {
    check_running_as_root
    get_xray_core
    colorized_echo blue "Updating docker-compose.yml with Xray-core volume..."
    grep -q "$XRAY_FILE:/usr/local/bin/xray" "$COMPOSE_FILE" || { echo "    volumes:" >> "$COMPOSE_FILE"; echo "      - $XRAY_FILE:/usr/local/bin/xray" >> "$COMPOSE_FILE"; }
    colorized_echo red "Restarting Remnanode..."
    $APP_NAME restart -n
    colorized_echo blue "Installation of XRAY-CORE version $selected_version completed."
}

check_editor() {
    [ -z "$EDITOR" ] && { command -v nano >/dev/null 2>&1 && EDITOR="nano" || { command -v vi >/dev/null 2>&1 && EDITOR="vi" || { detect_os; install_package nano; EDITOR="nano"; }; }; }
}

edit_command() {
    detect_os
    check_editor
    [ -f "$COMPOSE_FILE" ] && $EDITOR "$COMPOSE_FILE" || { colorized_echo red "Compose file not found at $COMPOSE_FILE"; exit 1; }
}

usage() {
    colorized_echo blue "================================"
    colorized_echo magenta "       $APP_NAME CLI Help"
    colorized_echo blue "================================"
    colorized_echo cyan "Usage:"
    echo "  $APP_NAME [command]"
    echo
    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up                  $(tput sgr0)– Start services"
    colorized_echo yellow "  down                $(tput sgr0)– Stop services"
    colorized_echo yellow "  restart             $(tput sgr0)– Restart services"
    colorized_echo yellow "  status              $(tput sgr0)– Show status"
    colorized_echo yellow "  logs                $(tput sgr0)– Show logs"
    colorized_echo yellow "  install             $(tput sgr0)– Install/reinstall Remnanode"
    colorized_echo yellow "  update              $(tput sgr0)– Update to latest version"
    colorized_echo yellow "  uninstall           $(tput sgr0)– Uninstall Remnanode"
    colorized_echo yellow "  install-script      $(tput sgr0)– Install Remnanode script"
    colorized_echo yellow "  uninstall-script    $(tput sgr0)– Uninstall Remnanode script"
    colorized_echo yellow "  edit                $(tput sgr0)– Edit docker-compose.yml (via nano or vi)"
    colorized_echo yellow "  core-update         $(tput sgr0)– Update/Change Xray core"
    echo
    colorized_echo cyan "Options for install:"
    colorized_echo yellow "  --dev               $(tput sgr0)– Use remnawave/node:dev instead of latest"
    echo
    colorized_echo cyan "Node Information:"
    colorized_echo magenta "  Node IP: $NODE_IP"
    echo
    current_version=$(get_current_xray_core_version)
    colorized_echo cyan "Current Xray-core version: " 1
    colorized_echo magenta "$current_version" 1
    echo
    DEFAULT_APP_PORT="3000"
    [ -f "$ENV_FILE" ] && APP_PORT=$(grep "APP_PORT=" "$ENV_FILE" | cut -d'=' -f2)
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

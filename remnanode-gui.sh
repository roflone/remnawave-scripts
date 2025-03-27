#!/usr/bin/env bash
set -e

# Глобальные переменные
INSTALL_DIR="/opt"
DATA_DIR="/var/lib"
SCRIPT_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
NODE_IP=$(curl -s -4 ifconfig.io || curl -s -6 ifconfig.io)
APP_NAME="remnanode"
APP_DIR="$INSTALL_DIR/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
XRAY_FILE="$DATA_DIR/$APP_NAME/xray"

# Функция для вывода сообщений через whiptail
show_msg() {
    whiptail --msgbox "$1" 10 60
}

# Функция для запроса подтверждения
confirm_action() {
    whiptail --yesno "$1" 10 60
}

# Функция прогресс-бара
progress_bar() {
    local message="$1"
    local pid=$2
    (
        while kill -0 $pid 2>/dev/null; do
            for i in {1..100}; do
                echo $i
                sleep 0.1
            done
        done
        echo 100
    ) | whiptail --gauge "$message" 8 60 0
}

# Проверка root прав
check_root() {
    if [ "$(id -u)" != "0" ]; then
        show_msg "This command must be run as root."
        exit 1
    fi
}

# Определение ОС
detect_os() {
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
        [ "$OS" = "Amazon Linux" ] && OS="Amazon"
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        show_msg "Unsupported operating system"
        exit 1
    fi
}

# Определение архитектуры
identify_architecture() {
    case "$(uname -m)" in
        'amd64' | 'x86_64') ARCH='64' ;;
        'armv8' | 'aarch64') ARCH='arm64-v8a' ;;
        *) show_msg "Unsupported architecture"; exit 1 ;;
    esac
}

# Установка пакетов
install_package() {
    local pkg=$1
    detect_os
    case $OS in
        Ubuntu*|Debian*) apt-get -y -qq install "$pkg" >/dev/null 2>&1 & ;;
        CentOS*|AlmaLinux*|Amazon*) yum install -y -q "$pkg" >/dev/null 2>&1 & ;;
        Fedora*) dnf install -y -q "$pkg" >/dev/null 2>&1 & ;;
        Arch*) pacman -S --noconfirm --quiet "$pkg" >/dev/null 2>&1 & ;;
        openSUSE*) zypper --quiet install -y "$pkg" >/dev/null 2>&1 & ;;
        *) show_msg "Unsupported OS"; exit 1 ;;
    esac
    progress_bar "Installing $pkg..." $!
}

# Установка Docker
install_docker() {
    if [ "$OS" = "Amazon" ]; then
        amazon-linux-extras enable docker >/dev/null 2>&1
        yum install -y docker >/dev/null 2>&1 &
        pid=$!
        progress_bar "Installing Docker on Amazon Linux..." $pid
        systemctl start docker
        systemctl enable docker
    else
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 &
        progress_bar "Installing Docker..." $!
    fi
}

# Определение Docker Compose
detect_compose() {
    if docker compose >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        show_msg "Docker Compose not found"
        exit 1
    fi
}

# Установка скрипта remnanode
install_remnanode_script() {
    curl -sSL "$SCRIPT_URL" -o "/usr/local/bin/$APP_NAME" >/dev/null 2>&1 &
    progress_bar "Installing $APP_NAME script..." $!
    chmod 755 "/usr/local/bin/$APP_NAME"
}

# Установка Xray-core
install_latest_xray_core() {
    identify_architecture
    mkdir -p "$DATA_DIR/$APP_NAME"
    cd "$DATA_DIR/$APP_NAME"
    latest=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep -oP '"tag_name": "\K(.*?)(?=")')
    [ -z "$latest" ] && { show_msg "Failed to fetch Xray-core version"; exit 1; }
    wget "https://github.com/XTLS/Xray-core/releases/download/$latest/Xray-linux-$ARCH.zip" -q &
    progress_bar "Downloading Xray-core $latest..." $!
    unzip -o "Xray-linux-$ARCH.zip" -d "$DATA_DIR/$APP_NAME" >/dev/null 2>&1 &
    progress_bar "Extracting Xray-core..." $!
    rm "Xray-linux-$ARCH.zip"
    chmod +x "$XRAY_FILE"
}

# Установка remnanode
install_remnanode() {
    mkdir -p "$APP_DIR" "$DATA_DIR/$APP_NAME"

    SSL_CERT=$(whiptail --inputbox "Paste SSL Public Key from Remnawave-Panel:" 10 60 3>&1 1>&2 2>&3)
    APP_PORT=$(whiptail --inputbox "Enter APP_PORT (default 3000):" 10 60 "3000" 3>&1 1>&2 2>&3)

    if confirm_action "Install latest Xray-core?"; then
        command -v unzip >/dev/null || install_package unzip
        install_latest_xray_core
    fi

    cat > "$ENV_FILE" <<EOL
APP_PORT=$APP_PORT
$SSL_CERT
EOL

    IMAGE_TAG=${USE_DEV_BRANCH:+"dev"} && IMAGE_TAG=${IMAGE_TAG:-"latest"}
    cat > "$COMPOSE_FILE" <<EOL
services:
  remnanode:
    container_name: $APP_NAME
    hostname: $APP_NAME
    image: remnawave/node:$IMAGE_TAG
    env_file: .env
    network_mode: host
EOL

    [ -f "$XRAY_FILE" ] && echo "    volumes:\n      - $XRAY_FILE:/usr/local/bin/xray" >> "$COMPOSE_FILE"
    install_remnanode_script
}

# Управление сервисами
up_remnanode() { $COMPOSE -f "$COMPOSE_FILE" up -d --remove-orphans & progress_bar "Starting services..." $!; }
down_remnanode() { $COMPOSE -f "$COMPOSE_FILE" down & progress_bar "Stopping services..." $!; }
restart_remnanode() { down_remnanode; up_remnanode; }
show_logs() { whiptail --textbox <($COMPOSE -f "$COMPOSE_FILE" logs) 20 80; }

# Проверка состояния
is_installed() { [ -d "$APP_DIR" ]; }
is_up() { [ -n "$($COMPOSE -f "$COMPOSE_FILE" ps -q)" ]; }

# Команды
install_command() {
    check_root
    is_installed && confirm_action "Override existing installation?" || { show_msg "Aborted"; exit 1; }
    detect_os
    command -v curl >/dev/null || install_package curl
    command -v docker >/dev/null || install_docker
    detect_compose
    install_remnanode
    up_remnanode
    show_msg "Use IP: $NODE_IP and port: $APP_PORT to setup Remnawave Panel"
}

update_command() {
    check_root
    is_installed || { show_msg "Remnanode not installed!"; exit 1; }
    detect_compose
    install_remnanode_script
    $COMPOSE -f "$COMPOSE_FILE" pull & progress_bar "Pulling latest image..." $!
    restart_remnanode
    show_msg "Remnanode updated successfully"
}

uninstall_command() {
    check_root
    is_installed || { show_msg "Remnanode not installed!"; exit 1; }
    confirm_action "Uninstall $APP_NAME?" || { show_msg "Aborted"; exit 1; }
    detect_compose
    is_up && down_remnanode
    rm -rf "$APP_DIR" "/usr/local/bin/$APP_NAME"
    confirm_action "Remove data files too ($DATA_DIR/$APP_NAME)?" && rm -rf "$DATA_DIR/$APP_NAME"
    show_msg "Remnanode uninstalled successfully"
}

up_command() {
    is_installed || { show_msg "Remnanode not installed!"; exit 1; }
    detect_compose
    is_up && { show_msg "Remnanode already up"; exit 1; }
    up_remnanode
}

down_command() {
    is_installed || { show_msg "Remnanode not installed!"; exit 1; }
    detect_compose
    is_up || { show_msg "Remnanode already down"; exit 1; }
    down_remnanode
}

restart_command() {
    is_installed || { show_msg "Remnanode not installed!"; exit 1; }
    detect_compose
    restart_remnanode
}

status_command() {
    if ! is_installed; then
        show_msg "Status: Not Installed"
    elif is_up; then
        show_msg "Status: Up"
    else
        show_msg "Status: Down"
    fi
}

logs_command() {
    is_installed || { show_msg "Remnanode not installed!"; exit 1; }
    detect_compose
    is_up || { show_msg "Remnanode is not up"; exit 1; }
    show_logs
}

# Главное меню
main_menu() {
    while true; do
        CHOICE=$(whiptail --title "$APP_NAME CLI" --menu "Choose an option:" 15 60 8 \
            "install" "Install/Reinstall" \
            "update" "Update to latest" \
            "uninstall" "Uninstall" \
            "up" "Start services" \
            "down" "Stop services" \
            "restart" "Restart services" \
            "status" "Show status" \
            "logs" "Show logs" 3>&1 1>&2 2>&3)
        
        [ -z "$CHOICE" ] && exit 0
        case $CHOICE in
            install) install_command ;;
            update) update_command ;;
            uninstall) uninstall_command ;;
            up) up_command ;;
            down) down_command ;;
            restart) restart_command ;;
            status) status_command ;;
            logs) logs_command ;;
        esac
    done
}

# Обработка аргументов
while [ $# -gt 0 ]; do
    case $1 in
        --name) APP_NAME="$2"; shift 2 ;;
        --dev) USE_DEV_BRANCH="true"; shift ;;
        install|update|uninstall|up|down|restart|status|logs) COMMAND="$1"; shift ;;
        *) shift ;;
    esac
done

# Запуск
[ -z "$COMMAND" ] && main_menu || "${COMMAND}_command"

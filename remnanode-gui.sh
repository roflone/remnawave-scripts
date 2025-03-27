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

# Функция для вывода сообщений
show_msg() {
    dialog --msgbox "$1" 10 60
}

# Функция для запроса подтверждения
confirm_action() {
    dialog --yesno "$1" 10 60
}

# Динамический прогресс-бар
progress_bar() {
    local message="$1"
    local command="$2"
    local tmpfile="/tmp/progress_$$.log"
    
    # Запускаем команду в фоне и перенаправляем вывод
    bash -c "$command" >"$tmpfile" 2>&1 &
    local pid=$!
    
    # Прогресс-бар обновляется на основе завершения процесса
    (
        echo "0"
        while kill -0 $pid 2>/dev/null; do
            sleep 0.5
            echo "50"  # Пока процесс идет, показываем 50%
        done
        wait $pid
        if [ $? -eq 0 ]; then
            echo "100"
        else
            echo "ERROR" > "$tmpfile"
            exit 1
        fi
    ) | dialog --gauge "$message" 8 60 0
    
    if [ -f "$tmpfile" ] && grep -q "ERROR" "$tmpfile"; then
        show_msg "Error during: $message\n$(cat "$tmpfile")"
        rm -f "$tmpfile"
        exit 1
    fi
    rm -f "$tmpfile"
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
        Ubuntu*|Debian*) progress_bar "Installing $pkg..." "apt-get -y -qq install $pkg" ;;
        CentOS*|AlmaLinux*|Amazon*) progress_bar "Installing $pkg..." "yum install -y -q $pkg" ;;
        Fedora*) progress_bar "Installing $pkg..." "dnf install -y -q $pkg" ;;
        Arch*) progress_bar "Installing $pkg..." "pacman -S --noconfirm --quiet $pkg" ;;
        openSUSE*) progress_bar "Installing $pkg..." "zypper --quiet install -y $pkg" ;;
        *) show_msg "Unsupported OS"; exit 1 ;;
    esac
}

# Установка Docker
install_docker() {
    if [ "$OS" = "Amazon" ]; then
        progress_bar "Installing Docker on Amazon Linux..." "amazon-linux-extras enable docker && yum install -y docker && systemctl start docker && systemctl enable docker"
    else
        progress_bar "Installing Docker..." "curl -fsSL https://get.docker.com | sh"
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

# Установка скрипта
install_remnanode_script() {
    progress_bar "Installing $APP_NAME script..." "curl -sSL $SCRIPT_URL -o /usr/local/bin/$APP_NAME && chmod 755 /usr/local/bin/$APP_NAME"
}

# Установка Xray-core
install_latest_xray_core() {
    identify_architecture
    mkdir -p "$DATA_DIR/$APP_NAME"
    cd "$DATA_DIR/$APP_NAME"
    latest=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep -oP '"tag_name": "\K(.*?)(?=")')
    [ -z "$latest" ] && { show_msg "Failed to fetch Xray-core version"; exit 1; }
    progress_bar "Downloading Xray-core $latest..." "wget -q https://github.com/XTLS/Xray-core/releases/download/$latest/Xray-linux-$ARCH.zip"
    progress_bar "Extracting Xray-core..." "unzip -o Xray-linux-$ARCH.zip && rm Xray-linux-$ARCH.zip && chmod +x $XRAY_FILE"
}

# Установка remnanode
install_remnanode() {
    mkdir -p "$APP_DIR" "$DATA_DIR/$APP_NAME"

    SSL_CERT=$(dialog --inputbox "Paste SSL Public Key from Remnawave-Panel:" 10 60 3>&1 1>&2 2>&3)
    APP_PORT=$(dialog --inputbox "Enter APP_PORT (default 3000):" 10 60 "3000" 3>&1 1>&2 2>&3)

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
up_remnanode() { progress_bar "Starting services..." "$COMPOSE -f $COMPOSE_FILE up -d --remove-orphans"; }
down_remnanode() { progress_bar "Stopping services..." "$COMPOSE -f $COMPOSE_FILE down"; }
restart_remnanode() { down_remnanode; up_remnanode; }
show_logs() {
    $COMPOSE -f "$COMPOSE_FILE" logs > /tmp/remnanode_logs_$$.txt
    dialog --textbox /tmp/remnanode_logs_$$.txt 20 80
    rm -f /tmp/remnanode_logs_$$.txt
}

# Проверка состояния
is_installed() { [ -d "$APP_DIR" ]; }
is_up() { [ -n "$($COMPOSE -f $COMPOSE_FILE ps -q)" ]; }

# Получение версии Xray-core
get_current_xray_core_version() {
    [ -f "$XRAY_FILE" ] && "$XRAY_FILE" -version 2>/dev/null | head -n1 | awk '{print $2}' || echo "Not installed"
}

# Обновление Xray-core
update_core_command() {
    check_root
    command -v unzip >/dev/null || install_package unzip
    install_latest_xray_core
    if ! grep -q "$XRAY_FILE:/usr/local/bin/xray" "$COMPOSE_FILE"; then
        echo "    volumes:" >> "$COMPOSE_FILE"
        echo "      - $XRAY_FILE:/usr/local/bin/xray" >> "$COMPOSE_FILE"
    fi
    restart_remnanode
    show_msg "Xray-core updated successfully"
}

# Редактирование docker-compose.yml
check_editor() {
    if [ -z "$EDITOR" ]; then
        command -v nano >/dev/null && EDITOR="nano" || { command -v vi >/dev/null && EDITOR="vi" || { install_package nano; EDITOR="nano"; }; }
    fi
}

edit_command() {
    check_editor
    [ -f "$COMPOSE_FILE" ] || { show_msg "Compose file not found at $COMPOSE_FILE"; exit 1; }
    $EDITOR "$COMPOSE_FILE"
}

# Команды
install_command() {
    check_root
    is_installed && { confirm_action "Override existing installation?" || { show_msg "Aborted"; exit 1; }; }
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
    progress_bar "Pulling latest image..." "$COMPOSE -f $COMPOSE_FILE pull"
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
        CHOICE=$(dialog --title "$APP_NAME CLI" --menu "Choose an option:" 20 60 12 \
            "install" "Install/Reinstall" \
            "update" "Update to latest" \
            "uninstall" "Uninstall" \
            "up" "Start services" \
            "down" "Stop services" \
            "restart" "Restart services" \
            "status" "Show status" \
            "logs" "Show logs" \
            "core-update" "Update Xray-core" \
            "edit" "Edit docker-compose.yml" 3>&1 1>&2 2>&3)
        
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
            core-update) update_core_command ;;
            edit) edit_command ;;
        esac
    done
}

# Обработка аргументов
while [ $# -gt 0 ]; do
    case $1 in
        --name) APP_NAME="$2"; APP_DIR="$INSTALL_DIR/$APP_NAME"; COMPOSE_FILE="$APP_DIR/docker-compose.yml"; ENV_FILE="$APP_DIR/.env"; XRAY_FILE="$DATA_DIR/$APP_NAME/xray"; shift 2 ;;
        --dev) USE_DEV_BRANCH="true"; shift ;;
        install|update|uninstall|up|down|restart|status|logs|core-update|edit) COMMAND="$1"; shift ;;
        *) shift ;;
    esac
done

# Запуск
[ -z "$COMMAND" ] && main_menu || "${COMMAND}_command"

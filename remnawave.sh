#!/usr/bin/env bash
# Remnawave Panel Installation Script
# This script installs and manages Remnawave Panel
# VERSION=2.71 

set -e
SCRIPT_VERSION="2.71"

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
        *)  
            break
        ;;  
    esac  
done


# Fetch IP address from ipinfo.io API
NODE_IP=$(curl -s -4 ifconfig.io)

# If the IPv4 retrieval is empty, attempt to retrieve the IPv6 address
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(curl -s -6 ifconfig.io)
fi

# Set default app name if not provided
if [[ "$COMMAND" == "install" || "$COMMAND" == "install-script" ]] && [ -z "$APP_NAME" ]; then
    APP_NAME="remnawave"
fi
# Set script name if APP_NAME is not set
if [ -z "$APP_NAME" ]; then
    SCRIPT_NAME=$(basename "$0")
    APP_NAME="${SCRIPT_NAME%.*}"
fi

INSTALL_DIR="/opt"
APP_DIR="$INSTALL_DIR/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
APP_CONFIG_FILE="$APP_DIR/app-config.json"
SCRIPT_URL="https://raw.githubusercontent.com/DigneZzZ/remnawave-scripts/main/remnawave.sh"  # Update with actual URL
SUB_ENV_FILE="$APP_DIR/.env.subscription"
BACKUP_CONFIG_FILE="$APP_DIR/backup-config.json"
BACKUP_SCRIPT_FILE="$APP_DIR/backup-scheduler.sh"
BACKUP_LOG_FILE="$APP_DIR/logs/backup.log"






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

check_system_requirements() {
    local errors=0
    
    # Проверяем свободное место (минимум 2GB для панели)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 2097152 ]; then  # 2GB в KB
        colorized_echo red "Error: Insufficient disk space. At least 2GB required for Remnawave Panel."
        errors=$((errors + 1))
    fi
    
    # Проверяем RAM (минимум 1GB)
    local available_ram=$(free -m | awk 'NR==2{print $7}')
    if [ "$available_ram" -lt 512 ]; then
        colorized_echo yellow "Warning: Low available RAM (${available_ram}MB). Panel performance may be affected."
    fi
    
    # Проверяем архитектуру
    local arch=$(uname -m)
    case "$arch" in
        'amd64'|'x86_64'|'aarch64'|'arm64') ;;
        *) 
            colorized_echo red "Error: Unsupported architecture: $arch"
            errors=$((errors + 1))
            ;;
    esac
    
    return $errors
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

            # Create symlink for compatibility with older scripts
            ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

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

install_remnawave_script() {  
    colorized_echo blue "Installing remnawave script"  
    TARGET_PATH="/usr/local/bin/$APP_NAME"  
      
    if [ ! -d "/usr/local/bin" ]; then  
        mkdir -p /usr/local/bin  
    fi  
      
    curl -sSL $SCRIPT_URL -o $TARGET_PATH  
  
    chmod 755 $TARGET_PATH  
      
    if [ -f "$TARGET_PATH" ]; then  
        colorized_echo green "Remnawave script installed successfully at $TARGET_PATH"  
    else  
        colorized_echo red "Failed to install remnawave script at $TARGET_PATH"  
        exit 1  
    fi  
}




ensure_backup_dirs() {
    # Проверяем, что Remnawave установлен
    if [ ! -d "$APP_DIR" ]; then
        echo -e "\033[1;31m❌ Remnawave is not installed!\033[0m"
        echo -e "\033[38;5;8m   Run '\033[38;5;15msudo $APP_NAME install\033[38;5;8m' first\033[0m"
        return 1
    fi
    
    # Создаем необходимые директории
    mkdir -p "$APP_DIR/logs" 2>/dev/null || true
    mkdir -p "$APP_DIR/backups" 2>/dev/null || true
    mkdir -p "$APP_DIR/temp" 2>/dev/null || true
    
    return 0
}


schedule_command() {
    if [ "$#" -eq 0 ]; then
        schedule_menu
        return
    fi
        if [ "$#" -eq 0 ]; then
        schedule_menu  
        return 0       
    fi
    
    case "$1" in
        setup|config) schedule_setup_menu ;;
        enable) schedule_enable ;;
        disable) schedule_disable ;;
        status) schedule_status ;;
        test) schedule_test_backup ;;
        test-telegram) schedule_test_telegram ;;
        run) schedule_run_backup ;;
        logs) schedule_show_logs ;;
        cleanup) schedule_cleanup ;;
        help|-h|--help) schedule_help ;;
        menu) schedule_menu ;;
        *) 
            echo -e "\033[1;31mUnknown command: $1\033[0m"
            echo -e "\033[38;5;8mUse '\033[38;5;15m$APP_NAME schedule help\033[38;5;8m' for available commands\033[0m"
            echo
            echo -e "\033[1;37mAvailable commands:\033[0m"
            echo -e "   \033[38;5;15msetup\033[0m           Configure backup settings"
            echo -e "   \033[38;5;15menable\033[0m          Enable scheduler"
            echo -e "   \033[38;5;15mdisable\033[0m         Disable scheduler"
            echo -e "   \033[38;5;15mstatus\033[0m          Show scheduler status"
            echo -e "   \033[38;5;15mtest\033[0m            Test backup creation"
            echo -e "   \033[38;5;15mtest-telegram\033[0m   Test Telegram delivery"
            echo -e "   \033[38;5;15mrun\033[0m             Run backup now"
            echo -e "   \033[38;5;15mlogs\033[0m            View backup logs"
            echo -e "   \033[38;5;15mcleanup\033[0m         Clean old backups"
            echo -e "   \033[38;5;15mhelp\033[0m            Show this help"
            ;;
    esac
}


schedule_menu() {
    if ! ensure_backup_dirs; then
        return 1
    fi
    
    while true; do
        clear
        echo -e "\033[1;37m📅 Backup Scheduler Management\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        echo
        
        local status=$(schedule_get_status)
        if [ "$status" = "enabled" ]; then
            echo -e "\033[1;32m✅ Scheduler Status: ENABLED\033[0m"
        else
            echo -e "\033[1;31m❌ Scheduler Status: DISABLED\033[0m"
        fi
        
        if [ -f "$BACKUP_CONFIG_FILE" ]; then
            local schedule=$(jq -r '.schedule // "Not configured"' "$BACKUP_CONFIG_FILE" 2>/dev/null)
            local telegram_enabled=$(jq -r '.telegram.enabled // false' "$BACKUP_CONFIG_FILE" 2>/dev/null)
            local retention=$(jq -r '.retention.days // 7' "$BACKUP_CONFIG_FILE" 2>/dev/null)
            local compression=$(jq -r '.compression.enabled // true' "$BACKUP_CONFIG_FILE" 2>/dev/null)
            
            echo -e "\033[38;5;250mSchedule: $schedule\033[0m"
            echo -e "\033[38;5;250mBackup Type: Full (database + all configs)\033[0m"
            echo -e "\033[38;5;250mCompression: $([ "$compression" = "true" ] && echo "✅ Enabled" || echo "❌ Disabled")\033[0m"
            echo -e "\033[38;5;250mTelegram: $([ "$telegram_enabled" = "true" ] && echo "✅ Enabled" || echo "❌ Disabled")\033[0m"
            echo -e "\033[38;5;250mRetention: $retention days\033[0m"
        else
            echo -e "\033[38;5;244mNo configuration found\033[0m"
        fi
        
        # Показываем информацию о логах
        if [ -f "$BACKUP_LOG_FILE" ]; then
            local log_size=$(du -sh "$BACKUP_LOG_FILE" 2>/dev/null | cut -f1)
            local last_entry=$(tail -1 "$BACKUP_LOG_FILE" 2>/dev/null | grep -o '\[.*\]' | head -1 || echo "No entries")
            echo -e "\033[38;5;250mLog size: $log_size, Last: $last_entry\033[0m"
        fi
        
        echo
        echo -e "\033[1;37m📋 Available Actions:\033[0m"
        echo -e "   \033[38;5;15m1)\033[0m 🔧 Configure backup settings"
        echo -e "   \033[38;5;15m2)\033[0m ⚙️  Enable/Disable scheduler"
        echo -e "   \033[38;5;15m3)\033[0m 🧪 Test backup creation"
        echo -e "   \033[38;5;15m4)\033[0m 📱 Test Telegram delivery"
        echo -e "   \033[38;5;15m5)\033[0m 📊 Show scheduler status"
        echo -e "   \033[38;5;15m6)\033[0m 📋 View backup logs"
        echo -e "   \033[38;5;15m7)\033[0m 🧹 Cleanup old backups"
        echo -e "   \033[38;5;15m8)\033[0m ▶️  Run full backup now"
        echo -e "   \033[38;5;15m9)\033[0m 🗑️  Clear logs"
        echo -e "   \033[38;5;244m0)\033[0m ⬅️  Back to main menu"
        echo
        echo -e "\033[38;5;8m💡 All scheduled backups include database + configurations\033[0m"
        echo
        
        read -p "Select option [0-9]: " choice
        
        case "$choice" in
            1) schedule_setup_menu ;;
            2) schedule_toggle ;;
            3) schedule_test_backup ;;
            4) schedule_test_telegram ;;
            5) schedule_status ;;
            6) schedule_show_logs ;;
            7) schedule_cleanup ;;
            8) schedule_run_backup ;;
            9) schedule_clear_logs ;;
            0) 
                clear
                return 0  
                ;;
            *) 
                echo -e "\033[1;31mInvalid option!\033[0m"
                sleep 1
                ;;
        esac
    done
}

# Новая функция очистки логов
schedule_clear_logs() {
    echo
    read -p "Clear all backup logs? [y/N]: " confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        if [ -f "$BACKUP_LOG_FILE" ]; then
            > "$BACKUP_LOG_FILE"  # Очищаем файл
            echo -e "\033[1;32m✅ Backup logs cleared\033[0m"
        else
            echo -e "\033[38;5;244mNo log file to clear\033[0m"
        fi
    else
        echo -e "\033[38;5;250mOperation cancelled\033[0m"
    fi
    
    sleep 2
}


schedule_setup_menu() {
    while true; do
        clear
        echo -e "\033[1;37m🔧 Backup Configuration\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
        echo
        
        if [ -f "$BACKUP_CONFIG_FILE" ]; then
            echo -e "\033[1;37m📋 Current Settings:\033[0m"
            local schedule=$(jq -r '.schedule // "Not set"' "$BACKUP_CONFIG_FILE" 2>/dev/null)
            local compression=$(jq -r '.compression.enabled // false' "$BACKUP_CONFIG_FILE" 2>/dev/null)
            local retention=$(jq -r '.retention.days // 7' "$BACKUP_CONFIG_FILE" 2>/dev/null)
            local telegram_enabled=$(jq -r '.telegram.enabled // false' "$BACKUP_CONFIG_FILE" 2>/dev/null)
            
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Schedule:" "$schedule"
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Compression:" "$([ "$compression" = "true" ] && echo "Enabled" || echo "Disabled")"
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s days\033[0m\n" "Retention:" "$retention"
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Telegram:" "$([ "$telegram_enabled" = "true" ] && echo "Enabled (49MB limit)" || echo "Disabled")"
            echo
        fi
        
        echo -e "\033[1;37m⚙️  Configuration Options:\033[0m"
        echo -e "   \033[38;5;15m1)\033[0m ⏰ Set backup schedule"
        echo -e "   \033[38;5;15m2)\033[0m 🗜️  Configure compression"
        echo -e "   \033[38;5;15m3)\033[0m 🗂️  Set retention policy"
        echo -e "   \033[38;5;15m4)\033[0m 📱 Configure Telegram"
        echo -e "   \033[38;5;15m5)\033[0m 🔄 Reset to defaults"
        echo -e "   \033[38;5;244m0)\033[0m ⬅️  Back"
        echo
        
        read -p "Select option [0-6]: " choice
        
        case "$choice" in
            1) schedule_configure_schedule ;;
            2) schedule_configure_compression ;;
            3) schedule_configure_retention ;;
            4) schedule_configure_telegram ;;
            5) schedule_reset_config ;;
            0) 
                return 0  
                ;;
            *) 
                echo -e "\033[1;31mInvalid option!\033[0m"
                sleep 1
                ;;
        esac
    done
}

schedule_configure_schedule() {
    clear
    echo -e "\033[1;37m⏰ Configure Backup Schedule\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 35))\033[0m"
    echo
    echo -e "\033[1;37m📋 Predefined Schedules:\033[0m"
    echo -e "   \033[38;5;15m1)\033[0m Daily at 2:00 AM"
    echo -e "   \033[38;5;15m2)\033[0m Daily at 4:00 AM"
    echo -e "   \033[38;5;15m3)\033[0m Every 12 hours"
    echo -e "   \033[38;5;15m4)\033[0m Weekly (Sunday 2:00 AM)"
    echo -e "   \033[38;5;15m5)\033[0m Custom cron expression"
    echo
    
    read -p "Select schedule [1-5]: " choice
    
    local cron_expression=""
    case "$choice" in
        1) cron_expression="0 2 * * *" ;;
        2) cron_expression="0 4 * * *" ;;
        3) cron_expression="0 */12 * * *" ;;
        4) cron_expression="0 2 * * 0" ;;
        5) 
            echo
            echo -e "\033[1;37m⚙️  Custom Cron Expression\033[0m"
            echo -e "\033[38;5;244mFormat: minute hour day month weekday\033[0m"
            echo -e "\033[38;5;244mExample: 0 3 * * * (daily at 3:00 AM)\033[0m"
            echo
            read -p "Enter cron expression: " cron_expression
            
            if ! echo "$cron_expression" | grep -E '^[0-9\*\-\,\/]+ [0-9\*\-\,\/]+ [0-9\*\-\,\/]+ [0-9\*\-\,\/]+ [0-9\*\-\,\/]+$' >/dev/null; then
                echo -e "\033[1;31m❌ Invalid cron expression!\033[0m"
                sleep 2
                return
            fi
            ;;
        *) echo -e "\033[1;31mInvalid option!\033[0m"; sleep 1; return ;;
    esac
    
    schedule_update_config ".schedule" "\"$cron_expression\""
    echo -e "\033[1;32m✅ Schedule updated: $cron_expression\033[0m"
    sleep 2
}

schedule_configure_compression() {
    clear
    echo -e "\033[1;37m🗜️  Configure Compression\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
    echo
    echo -e "\033[38;5;250mCompression reduces backup size but increases CPU usage\033[0m"
    echo
    
    read -p "Enable compression? [y/N]: " enable_compression
    
    if [[ $enable_compression =~ ^[Yy]$ ]]; then
        schedule_update_config ".compression.enabled" "true"
        
        echo
        echo -e "\033[1;37m📊 Compression Level:\033[0m"
        echo -e "   \033[38;5;15m1)\033[0m Fast (level 1)"
        echo -e "   \033[38;5;15m2)\033[0m Balanced (level 6)"
        echo -e "   \033[38;5;15m3)\033[0m Best (level 9)"
        echo
        
        read -p "Select compression level [1-3]: " level_choice
        
        local compression_level=6
        case "$level_choice" in
            1) compression_level=1 ;;
            2) compression_level=6 ;;
            3) compression_level=9 ;;
        esac
        
        schedule_update_config ".compression.level" "$compression_level"
        echo -e "\033[1;32m✅ Compression enabled (level $compression_level)\033[0m"
    else
        schedule_update_config ".compression.enabled" "false"
        echo -e "\033[1;32m✅ Compression disabled\033[0m"
    fi
    
    sleep 2
}

schedule_configure_retention() {
    clear
    echo -e "\033[1;37m🗂️  Configure Retention Policy\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 35))\033[0m"
    echo
    echo -e "\033[38;5;250mHow long to keep backup files before automatic deletion\033[0m"
    echo
    
    read -p "Retention period in days [7]: " retention_days
    retention_days=${retention_days:-7}
    
    if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || [ "$retention_days" -lt 1 ]; then
        echo -e "\033[1;31m❌ Invalid number!\033[0m"
        sleep 2
        return
    fi
    
    schedule_update_config ".retention.days" "$retention_days"
    
    echo
    read -p "Keep minimum number of backups regardless of age? [y/N]: " keep_minimum
    if [[ $keep_minimum =~ ^[Yy]$ ]]; then
        read -p "Minimum backups to keep [3]: " min_backups
        min_backups=${min_backups:-3}
        
        if [[ "$min_backups" =~ ^[0-9]+$ ]] && [ "$min_backups" -ge 1 ]; then
            schedule_update_config ".retention.min_backups" "$min_backups"
        fi
    fi
    
    echo -e "\033[1;32m✅ Retention policy updated: $retention_days days\033[0m"
    sleep 2
}

# Настройка Telegram
schedule_configure_telegram() {
    clear
    echo -e "\033[1;37m📱 Configure Telegram Integration\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
    echo
    
    read -p "Enable Telegram notifications? [y/N]: " enable_telegram
    
    if [[ $enable_telegram =~ ^[Yy]$ ]]; then
        schedule_update_config ".telegram.enabled" "true"
        
        # Устанавливаем параметры для официального API
        schedule_update_config ".telegram.use_custom_api" "false"
        schedule_update_config ".telegram.api_server" "\"https://api.telegram.org\""
        schedule_update_config ".telegram.max_file_size" "49"
        schedule_update_config ".telegram.split_large_files" "true"
        
        echo -e "\033[1;32m✅ Using official Telegram Bot API (49MB file limit)\033[0m"
        
        # Bot Token
        echo
        echo -e "\033[1;37m🤖 Bot Token Configuration\033[0m"
        echo -e "\033[38;5;244mGet token from @BotFather on Telegram\033[0m"
        
        local current_token=$(jq -r '.telegram.bot_token // ""' "$BACKUP_CONFIG_FILE" 2>/dev/null)
        if [ -n "$current_token" ] && [ "$current_token" != "null" ]; then
            echo -e "\033[38;5;250mCurrent token: ${current_token:0:10}...\033[0m"
            read -p "Keep current token? [Y/n]: " keep_token
            if [[ ! $keep_token =~ ^[Nn]$ ]]; then
                current_token=""
            fi
        fi
        
        if [ -z "$current_token" ] || [ "$current_token" = "null" ]; then
            read -p "Enter bot token: " bot_token
            if [ -z "$bot_token" ]; then
                echo -e "\033[1;31m❌ Token is required!\033[0m"
                sleep 2
                return
            fi
            schedule_update_config ".telegram.bot_token" "\"$bot_token\""
        fi
        
        # Chat ID
        echo
        echo -e "\033[1;37m💬 Chat Configuration\033[0m"
        echo -e "\033[38;5;244mFor groups: use negative ID (e.g., -1001234567890)\033[0m"
        echo -e "\033[38;5;244mFor private: use positive ID (e.g., 123456789)\033[0m"
        
        read -p "Enter chat ID: " chat_id
        if [ -z "$chat_id" ]; then
            echo -e "\033[1;31m❌ Chat ID is required!\033[0m"
            sleep 2
            return
        fi
        schedule_update_config ".telegram.chat_id" "\"$chat_id\""
        
        # Thread ID (optional)
        echo
        echo -e "\033[1;37m🧵 Thread Configuration (Optional)\033[0m"
        echo -e "\033[38;5;244mFor group threads/topics. Leave empty if not using threads.\033[0m"
        
        read -p "Enter thread ID (optional): " thread_id
        if [ -n "$thread_id" ]; then
            schedule_update_config ".telegram.thread_id" "\"$thread_id\""
        else
            schedule_update_config ".telegram.thread_id" "null"
        fi
        
        echo -e "\033[1;32m✅ Telegram integration configured!\033[0m"
        echo -e "\033[38;5;8m   Files larger than 49MB will be automatically split\033[0m"
        echo -e "\033[38;5;8m   Use 'Test Telegram' to verify settings\033[0m"
    else
        schedule_update_config ".telegram.enabled" "false"
        echo -e "\033[1;32m✅ Telegram notifications disabled\033[0m"
    fi
    
    sleep 2
}

# Функция обновления конфигурации
schedule_update_config() {
    local key="$1"
    local value="$2"
    
    # Создаем конфиг если не существует
    if [ ! -f "$BACKUP_CONFIG_FILE" ]; then
        echo '{}' > "$BACKUP_CONFIG_FILE"
    fi
    
    # Обновляем значение
    local temp_file=$(mktemp)
    jq "$key = $value" "$BACKUP_CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$BACKUP_CONFIG_FILE"
}

# Функция получения статуса
schedule_get_status() {
    if crontab -l 2>/dev/null | grep -q "$BACKUP_SCRIPT_FILE"; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Включение/выключение планировщика
schedule_toggle() {
    local status=$(schedule_get_status)
    
    if [ "$status" = "enabled" ]; then
        schedule_disable
    else
        schedule_enable
    fi
}

# Включение планировщика
schedule_enable() {
    if [ ! -f "$BACKUP_CONFIG_FILE" ]; then
        echo -e "\033[1;31m❌ No configuration found! Please configure backup settings first.\033[0m"
        sleep 2
        return
    fi
    
    local schedule=$(jq -r '.schedule // ""' "$BACKUP_CONFIG_FILE" 2>/dev/null)
    if [ -z "$schedule" ] || [ "$schedule" = "null" ]; then
        echo -e "\033[1;31m❌ No schedule configured! Please set backup schedule first.\033[0m"
        sleep 2
        return
    fi
    
    # Создаем скрипт планировщика
    schedule_create_backup_script
    
    # Добавляем в crontab
    local cron_entry="$schedule $BACKUP_SCRIPT_FILE >> $BACKUP_LOG_FILE 2>&1"
    
    # Удаляем старую запись если есть
    (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT_FILE"; echo "$cron_entry") | crontab -
    
    echo -e "\033[1;32m✅ Backup scheduler enabled!\033[0m"
    echo -e "\033[38;5;250mSchedule: $schedule\033[0m"
    sleep 2
}

# Отключение планировщика
schedule_disable() {
    crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT_FILE" | crontab -
    echo -e "\033[1;32m✅ Backup scheduler disabled!\033[0m"
    sleep 2
}



schedule_create_backup_script() {
    cat > "$BACKUP_SCRIPT_FILE" << 'EOF'
#!/bin/bash
# Автоматически сгенерированный скрипт резервного копирования

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup-config.json"
APP_DIR="$SCRIPT_DIR"
BACKUP_DIR="$APP_DIR/backups"
TEMP_DIR="$APP_DIR/temp"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Функция отправки в Telegram
send_telegram() {
    local message="$1"
    local file_path="$2"
    
    local bot_token=$(jq -r '.telegram.bot_token' "$CONFIG_FILE" 2>/dev/null)
    local chat_id=$(jq -r '.telegram.chat_id' "$CONFIG_FILE" 2>/dev/null)
    local thread_id=$(jq -r '.telegram.thread_id' "$CONFIG_FILE" 2>/dev/null)
    local api_server=$(jq -r '.telegram.api_server // "https://api.telegram.org"' "$CONFIG_FILE" 2>/dev/null)
    local use_custom_api=$(jq -r '.telegram.use_custom_api // false' "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$bot_token" ] || [ "$bot_token" = "null" ] || [ -z "$chat_id" ] || [ "$chat_id" = "null" ]; then
        log "ERROR: Telegram credentials not configured"
        return 1
    fi
    
    # Удаляем завершающий слеш если есть
    api_server=${api_server%/}
    
    local api_url="$api_server/bot$bot_token"
    local params="chat_id=$chat_id"
    
    if [ -n "$thread_id" ] && [ "$thread_id" != "null" ]; then
        params="$params&message_thread_id=$thread_id"
    fi
    
    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        log "Sending file via Telegram API: $(basename "$file_path")"
        
        # Отправка файла
        local response=$(curl -s -X POST "$api_url/sendDocument" \
            -F "$params" \
            -F "document=@$file_path" \
            -F "caption=$message")
        
        # Проверяем ответ
        if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
            log "File sent successfully to Telegram"
            return 0
        else
            local error_desc=$(echo "$response" | jq -r '.description // "Unknown error"')
            log "ERROR: Failed to send file to Telegram: $error_desc"
            
            # Если файл слишком большой для официального API, предупреждаем
            if echo "$error_desc" | grep -qi "file.*too.*large\|entity.*too.*large"; then
                log "File too large for official API. Consider using custom Bot API server for files up to 2GB"
            fi
            
            return 1
        fi
    else
        # Отправка текста
        local response=$(curl -s -X POST "$api_url/sendMessage" \
            -d "$params" \
            -d "text=$message")
        
        if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
            log "Message sent successfully to Telegram"
            return 0
        else
            local error_desc=$(echo "$response" | jq -r '.description // "Unknown error"')
            log "ERROR: Failed to send message to Telegram: $error_desc"
            return 1
        fi
    fi
}

# Функция разделения файла (только для официального API)
split_file() {
    local file_path="$1"
    local max_size_mb="$2"
    local base_name=$(basename "$file_path")
    local split_dir="$TEMP_DIR/split_$$"
    
    log "Splitting file $base_name into ${max_size_mb}MB parts..."
    
    mkdir -p "$split_dir"
    
    # Разделяем файл на части
    split -b "${max_size_mb}M" "$file_path" "$split_dir/${base_name}.part_"
    
    # Отправляем каждую часть
    local part_num=1
    local success=true
    
    for part_file in "$split_dir"/*; do
        if [ -f "$part_file" ]; then
            local part_name="${base_name}.part_${part_num}"
            mv "$part_file" "$split_dir/$part_name"
            
            local part_message="📦 Backup part $part_num/${total_parts:-?}
📁 Original file: $base_name"
            
            if ! send_telegram "$part_message" "$split_dir/$part_name"; then
                success=false
                break
            fi
            
            part_num=$((part_num + 1))
        fi
    done
    
    # Очищаем временные файлы
    rm -rf "$split_dir"
    
    if [ "$success" = true ]; then
        log "All file parts sent successfully"
        return 0
    else
        log "ERROR: Failed to send some file parts"
        return 1
    fi
}

# Основная функция резервного копирования
main() {
    log "Starting scheduled backup..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR: Configuration file not found"
        exit 1
    fi
    
    # Читаем конфигурацию
    local compression_enabled=$(jq -r '.compression.enabled // false' "$CONFIG_FILE")
    local compression_level=$(jq -r '.compression.level // 6' "$CONFIG_FILE")
    local telegram_enabled=$(jq -r '.telegram.enabled // false' "$CONFIG_FILE")
    local split_files=$(jq -r '.telegram.split_large_files // true' "$CONFIG_FILE")
    local max_file_size=$(jq -r '.telegram.max_file_size // 49' "$CONFIG_FILE")
    local use_custom_api=$(jq -r '.telegram.use_custom_api // false' "$CONFIG_FILE")
    
    # Получаем данные для подключения к БД
    local POSTGRES_USER=$(grep "^POSTGRES_USER=" "$APP_DIR/.env" | cut -d'=' -f2)
    local POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$APP_DIR/.env" | cut -d'=' -f2)
    local POSTGRES_DB=$(grep "^POSTGRES_DB=" "$APP_DIR/.env" | cut -d'=' -f2)
    
    # Устанавливаем значения по умолчанию
    POSTGRES_USER=${POSTGRES_USER:-postgres}
    POSTGRES_DB=${POSTGRES_DB:-postgres}
    
    if [ -z "$POSTGRES_PASSWORD" ]; then
        log "ERROR: POSTGRES_PASSWORD not found in .env file"
        exit 1
    fi
    
    # Создаем резервную копию (всегда полную с конфигами для scheduled backup)
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="remnawave_scheduled_${timestamp}"
    local backup_dir="$BACKUP_DIR/$backup_name"
    mkdir -p "$backup_dir"
    
    log "Creating full system backup: $backup_name"
    
    # Создаем дамп базы данных
    log "Step 1: Exporting database..."
    if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" \
        "${APP_NAME:-remnawave}-db" \
        pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F p --verbose > "$backup_dir/database.sql" 2>/dev/null; then
        local db_size=$(du -sh "$backup_dir/database.sql" | cut -f1)
        log "Database exported successfully ($db_size)"
    else
        log "ERROR: Database export failed"
        rm -rf "$backup_dir"
        exit 1
    fi
    
    # Универсальное копирование конфигурационных файлов
    log "Step 2: Including configuration files..."
    mkdir -p "$backup_dir/configs"
    
    local config_count=0
    
    # Копируем основные конфигурационные файлы
    log "Copying main configuration files..."
    for config_file in "$APP_DIR/.env" "$APP_DIR/.env.subscription" "$APP_DIR/docker-compose.yml"; do
        if [ -f "$config_file" ]; then
            local filename=$(basename "$config_file")
            cp "$config_file" "$backup_dir/configs/"
            config_count=$((config_count + 1))
            log "✓ $filename"
        fi
    done
    
    # Копируем дополнительные конфигурационные файлы по расширениям
    log "Scanning for additional config files..."
    local extensions=("json" "yml" "yaml" "toml" "ini" "conf" "config" "cfg")
    
    for ext in "${extensions[@]}"; do
        for config_file in "$APP_DIR"/*."$ext"; do
            if [ -f "$config_file" ]; then
                local filename=$(basename "$config_file")
                # Исключаем файлы, которые могут быть временными или логами
                if [[ ! "$filename" =~ ^(temp|tmp|cache|log|debug) ]]; then
                    cp "$config_file" "$backup_dir/configs/"
                    config_count=$((config_count + 1))
                    log "✓ $filename"
                fi
            fi
        done
    done
    
    # Копируем важные директории с конфигурациями
    log "Checking for configuration directories..."
    local config_dirs=("certs" "certificates" "ssl" "configs" "config" "custom" "themes" "plugins")
    
    for dir_name in "${config_dirs[@]}"; do
        local config_dir="$APP_DIR/$dir_name"
        if [ -d "$config_dir" ] && [ "$(ls -A "$config_dir" 2>/dev/null)" ]; then
            cp -r "$config_dir" "$backup_dir/configs/"
            local dir_files=$(find "$config_dir" -type f | wc -l)
            config_count=$((config_count + dir_files))
            log "✓ $dir_name/ ($dir_files files)"
        fi
    done
    
    # Создаем метаданные
    log "Step 3: Creating backup metadata..."
    cat > "$backup_dir/metadata.json" << METADATA_EOF
{
    "backup_type": "scheduled_full",
    "timestamp": "$timestamp",
    "app_name": "${APP_NAME:-remnawave}",
    "script_version": "2.1",
    "database_included": true,
    "configs_included": true,
    "config_files_count": $config_count,
    "hostname": "$(hostname)",
    "scheduled": true,
    "compression": $compression_enabled,
    "backup_size": "calculated_after_compression"
}
METADATA_EOF
    
    # Создаем информационный файл
    cat > "$backup_dir/backup_info.txt" << INFO_EOF
Remnawave Panel Scheduled Backup Information
===========================================

Backup Date: $(date)
Backup Type: Scheduled Full System Backup
Hostname: $(hostname)
APP_NAME: ${APP_NAME:-remnawave}

Included Components:
✓ PostgreSQL Database (complete dump)
✓ Environment Files (.env, .env.subscription)
✓ Docker Compose Configuration
✓ Additional Config Files ($config_count files)
✓ Configuration Directories (if present)
✓ SSL Certificates (if present)

Restoration:
1. Install Remnawave Panel on target system
2. Stop services: sudo ${APP_NAME:-remnawave} down
3. Extract this backup
4. Restore database: cat database.sql | docker exec -i DB_CONTAINER psql -U postgres -d postgres
5. Copy configs to appropriate locations
6. Start services: sudo ${APP_NAME:-remnawave} up

Generated by Remnawave Scheduled Backup System v2.1
INFO_EOF
    
    log "Configuration files included ($config_count items)"
    
    local backup_path=""
    
    # Компрессия (всегда применяется для scheduled backup если включена)
    if [ "$compression_enabled" = "true" ]; then
        log "Step 4: Compressing backup..."
        cd "$BACKUP_DIR"
        if tar -czf "${backup_name}.tar.gz" -C . "$(basename "$backup_dir")" 2>/dev/null; then
            local compressed_size=$(du -sh "${backup_name}.tar.gz" | cut -f1)
            log "Backup compressed successfully ($compressed_size)"
            backup_path="$BACKUP_DIR/${backup_name}.tar.gz"
            
            # Удаляем некомпрессированную версию
            rm -rf "$backup_dir"
        else
            log "ERROR: Compression failed, keeping uncompressed backup"
            backup_path="$backup_dir"
        fi
    else
        backup_path="$backup_dir"
    fi
    
    if [ -f "$backup_path" ] || [ -d "$backup_path" ]; then
        if [ -f "$backup_path" ]; then
            local file_size=$(du -h "$backup_path" | cut -f1)
            local file_size_mb=$(du -m "$backup_path" | cut -f1)
        else
            local file_size=$(du -sh "$backup_path" | cut -f1)
            local file_size_mb=$(du -sm "$backup_path" | cut -f1)
        fi
        
        log "Backup created successfully: $(basename "$backup_path") ($file_size)"
        
        # Отправка в Telegram
        if [ "$telegram_enabled" = "true" ]; then
            log "Sending backup to Telegram..."
            
            local message="✅ Scheduled backup completed successfully!
📅 Date: $(date '+%Y-%m-%d %H:%M:%S')
📦 File: $(basename "$backup_path")
📊 Size: $file_size
🗄️ Database: Remnawave Panel
📁 Configs: $config_count files included
🗜️ Compression: $([ "$compression_enabled" = "true" ] && echo "Enabled" || echo "Disabled")
🤖 API: $([ "$use_custom_api" = "true" ] && echo "Custom (2GB limit)" || echo "Official (49MB limit)")"
            
            local telegram_success=false
            
            # Проверяем нужно ли разделять файл
            if [ "$use_custom_api" = "true" ]; then
                # Для кастомного API отправляем файл целиком (до 2GB)
                log "Using custom API, sending full file (${file_size_mb}MB)"
                if send_telegram "$message" "$backup_path"; then
                    telegram_success=true
                fi
            elif [ "$split_files" = "true" ] && [ "$file_size_mb" -gt "$max_file_size" ]; then
                # Для официального API разделяем большие файлы
                log "File size ($file_size_mb MB) exceeds limit ($max_file_size MB), splitting..."
                send_telegram "$message"
                if split_file "$backup_path" "$max_file_size"; then
                    telegram_success=true
                fi
            else
                # Отправляем файл целиком если он помещается
                if send_telegram "$message" "$backup_path"; then
                    telegram_success=true
                fi
            fi
            
            if [ "$telegram_success" = true ]; then
                log "Backup sent to Telegram successfully"
            else
                log "WARNING: Failed to send backup to Telegram"
            fi
        fi
        
        # Очистка старых бэкапов
        local retention_days=$(jq -r '.retention.days // 7' "$CONFIG_FILE")
        local min_backups=$(jq -r '.retention.min_backups // 3' "$CONFIG_FILE")
        
        log "Cleaning up backups older than $retention_days days..."
        
        # Удаляем старые файлы, но оставляем минимальное количество
        local backup_count=$(ls -1 "$BACKUP_DIR"/remnawave_scheduled_*.{sql*,tar.gz} 2>/dev/null | wc -l)
        
        if [ "$backup_count" -gt "$min_backups" ]; then
            find "$BACKUP_DIR" -name "remnawave_scheduled_*" -type f -mtime +$retention_days -delete 2>/dev/null
            find "$BACKUP_DIR" -name "remnawave_scheduled_*" -type d -mtime +$retention_days -exec rm -rf {} + 2>/dev/null
            log "Old backups cleaned up"
        else
            log "Keeping all backups (count: $backup_count, minimum: $min_backups)"
        fi
        
        log "Backup process completed successfully"
    else
        log "ERROR: Backup creation failed"
        
        if [ "$telegram_enabled" = "true" ]; then
            send_telegram "❌ Scheduled backup FAILED!
📅 Date: $(date '+%Y-%m-%d %H:%M:%S')
⚠️ Please check the backup logs and system status."
        fi
        
        exit 1
    fi
}

main "$@"
EOF

    chmod +x "$BACKUP_SCRIPT_FILE"
}

# Тест создания резервной копии
schedule_test_backup() {
    clear
    echo -e "\033[1;37m🧪 Testing Backup Creation\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
    echo
    
    if ! is_remnawave_up; then
        echo -e "\033[1;31m❌ Remnawave services are not running!\033[0m"
        echo -e "\033[38;5;8m   Start services first with 'sudo $APP_NAME up'\033[0m"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo -e "\033[38;5;250mCreating test backup...\033[0m"
    
    # Создаем скрипт если не существует
    if [ ! -f "$BACKUP_SCRIPT_FILE" ]; then
        schedule_create_backup_script
    fi
    
    # Запускаем тест
    if bash "$BACKUP_SCRIPT_FILE"; then
        echo -e "\033[1;32m✅ Test backup completed successfully!\033[0m"
        echo -e "\033[38;5;250mCheck $BACKUP_DIR for the backup file\033[0m"
    else
        echo -e "\033[1;31m❌ Test backup failed!\033[0m"
        echo -e "\033[38;5;8m   Check logs: $BACKUP_LOG_FILE\033[0m"
    fi
    
    read -p "Press Enter to continue..."
}

# Тест Telegram
schedule_test_telegram() {
    clear
    echo -e "\033[1;37m📱 Testing Telegram Integration\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 35))\033[0m"
    echo
    
    if [ ! -f "$BACKUP_CONFIG_FILE" ]; then
        echo -e "\033[1;31m❌ No configuration found!\033[0m"
        read -p "Press Enter to continue..."
        return
    fi
    
    local telegram_enabled=$(jq -r '.telegram.enabled // false' "$BACKUP_CONFIG_FILE" 2>/dev/null)
    if [ "$telegram_enabled" != "true" ]; then
        echo -e "\033[1;31m❌ Telegram integration is disabled!\033[0m"
        read -p "Press Enter to continue..."
        return
    fi
    
    local bot_token=$(jq -r '.telegram.bot_token' "$BACKUP_CONFIG_FILE" 2>/dev/null)
    local chat_id=$(jq -r '.telegram.chat_id' "$BACKUP_CONFIG_FILE" 2>/dev/null)
    local thread_id=$(jq -r '.telegram.thread_id' "$BACKUP_CONFIG_FILE" 2>/dev/null)
    
    echo -e "\033[38;5;250mSending test message...\033[0m"
    
    local api_url="https://api.telegram.org/bot$bot_token"
    local message="🧪 Test message from Remnawave Backup System
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Telegram integration is working correctly!"
    
    local params="chat_id=$chat_id&text=$(echo "$message" | sed 's/ /%20/g')"
    
    if [ -n "$thread_id" ] && [ "$thread_id" != "null" ]; then
        params="$params&message_thread_id=$thread_id"
    fi
    
    local response=$(curl -s -X POST "$api_url/sendMessage" -d "$params")
    
    if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        echo -e "\033[1;32m✅ Test message sent successfully!\033[0m"
        echo -e "\033[38;5;250mCheck your Telegram for the test message\033[0m"
    else
        echo -e "\033[1;31m❌ Failed to send test message!\033[0m"
        echo -e "\033[38;5;244mResponse: $(echo "$response" | jq -r '.description // "Unknown error"')\033[0m"
    fi
    
    read -p "Press Enter to continue..."
}

schedule_status() {
    clear
    echo -e "\033[1;37m📊 Backup Scheduler Status\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 35))\033[0m"
    echo
    
    local status=$(schedule_get_status)
    
    if [ "$status" = "enabled" ]; then
        echo -e "\033[1;32m✅ Status: ENABLED\033[0m"
        
        # Показываем cron задачу
        local cron_line=$(crontab -l 2>/dev/null | grep "$BACKUP_SCRIPT_FILE")
        if [ -n "$cron_line" ]; then
            local schedule=$(echo "$cron_line" | awk '{print $1" "$2" "$3" "$4" "$5}')
            echo -e "\033[38;5;250mSchedule: $schedule\033[0m"
        fi
        
        
        if command -v crontab >/dev/null && [ -n "$cron_line" ]; then
            
            local schedule_desc=""
            case "$schedule" in
                "0 2 * * *") schedule_desc="Daily at 2:00 AM" ;;
                "0 4 * * *") schedule_desc="Daily at 4:00 AM" ;;
                "0 */12 * * *") schedule_desc="Every 12 hours" ;;
                "0 2 * * 0") schedule_desc="Weekly on Sunday at 2:00 AM" ;;
                *) schedule_desc="Custom: $schedule" ;;
            esac
            echo -e "\033[38;5;250mFrequency: $schedule_desc\033[0m"
        fi
    else
        echo -e "\033[1;31m❌ Status: DISABLED\033[0m"
    fi
    
    
    echo
    echo -e "\033[1;37m📦 Recent Backups:\033[0m"
    
    
    local backup_files=""
    
    
    backup_files=$(ls -t "$BACKUP_DIR"/remnawave_scheduled_*.tar.gz "$BACKUP_DIR"/remnawave_scheduled_*.sql 2>/dev/null | head -5)
    
    
    if [ -z "$backup_files" ]; then
        backup_files=$(ls -t "$BACKUP_DIR"/remnawave_*.tar.gz "$BACKUP_DIR"/remnawave_*.sql* 2>/dev/null | head -5)
    fi
    
    if [ -n "$backup_files" ]; then
        echo "$backup_files" | while IFS= read -r file; do
            if [ -f "$file" ]; then
                local filename=$(basename "$file")
                local file_size=$(du -sh "$file" 2>/dev/null | cut -f1)
                local file_date=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
                
                
                local backup_type="📦"
                if [[ "$filename" =~ scheduled ]]; then
                    backup_type="🤖"  # автоматический
                elif [[ "$filename" =~ full ]]; then
                    backup_type="📁"  # полный ручной
                else
                    backup_type="📊"  # обычный
                fi
                
                printf "   %s \033[38;5;250m%-35s\033[0m \033[38;5;244m%s\033[0m \033[38;5;244m%s\033[0m\n" "$backup_type" "$filename" "$file_size" "$file_date"
            fi
        done
    else
        echo -e "\033[38;5;244m   No backup files found\033[0m"
        echo -e "\033[38;5;244m   Run a backup to see files here\033[0m"
    fi
    

    echo
    echo -e "\033[1;37m📈 Statistics:\033[0m"
    

    local total_backups=$(ls -1 "$BACKUP_DIR"/remnawave_*.{tar.gz,sql*} 2>/dev/null | wc -l)
    local scheduled_backups=$(ls -1 "$BACKUP_DIR"/remnawave_scheduled_*.{tar.gz,sql} 2>/dev/null | wc -l)
    local manual_backups=$(ls -1 "$BACKUP_DIR"/remnawave_full_*.{tar.gz,sql} "$BACKUP_DIR"/remnawave_db_*.{sql*} 2>/dev/null | wc -l)
    
    printf "   \033[38;5;15m%-20s\033[0m \033[38;5;250m%s\033[0m\n" "Total backups:" "$total_backups"
    printf "   \033[38;5;15m%-20s\033[0m \033[38;5;250m%s\033[0m\n" "Scheduled backups:" "$scheduled_backups"
    printf "   \033[38;5;15m%-20s\033[0m \033[38;5;250m%s\033[0m\n" "Manual backups:" "$manual_backups"
    

    if [ -d "$BACKUP_DIR" ]; then
        local backup_dir_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        printf "   \033[38;5;15m%-20s\033[0m \033[38;5;250m%s\033[0m\n" "Total size:" "$backup_dir_size"
    fi
    
    read -p "Press Enter to continue..."
}


schedule_show_logs() {
    clear
    echo -e "\033[1;37m📋 Backup Logs\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 20))\033[0m"
    echo
    
    if [ -f "$BACKUP_LOG_FILE" ]; then

        local log_size=$(du -sh "$BACKUP_LOG_FILE" 2>/dev/null | cut -f1)
        echo -e "\033[38;5;250mLog file: $(basename "$BACKUP_LOG_FILE") ($log_size)\033[0m"
        echo -e "\033[38;5;250mLocation: $BACKUP_LOG_FILE\033[0m"
        echo
        echo -e "\033[38;5;250mLast 30 log entries:\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        
        tail -30 "$BACKUP_LOG_FILE" | while IFS= read -r line; do
            if echo "$line" | grep -q "ERROR\|FAILED\|Failed"; then
                echo -e "\033[1;31m$line\033[0m"
            elif echo "$line" | grep -q "SUCCESS\|successfully\|SUCCESS\|✅\|completed"; then
                echo -e "\033[1;32m$line\033[0m"
            elif echo "$line" | grep -q "MANUAL BACKUP\|==="; then
                echo -e "\033[1;37m$line\033[0m"
            elif echo "$line" | grep -q "WARNING\|⚠️"; then
                echo -e "\033[1;33m$line\033[0m"
            elif echo "$line" | grep -q "Starting\|Step\|Creating"; then
                echo -e "\033[1;36m$line\033[0m"
            else
                echo -e "\033[38;5;250m$line\033[0m"
            fi
        done
        
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        echo
        echo -e "\033[38;5;244m💡 Commands:\033[0m"
        echo -e "\033[38;5;244m   View full log: tail -f $BACKUP_LOG_FILE\033[0m"
        echo -e "\033[38;5;244m   Clear log: > $BACKUP_LOG_FILE\033[0m"
    else
        echo -e "\033[38;5;244mNo log file found at: $BACKUP_LOG_FILE\033[0m"
        echo -e "\033[38;5;244mLogs will be created after first backup run\033[0m"
    fi
    
    echo
    read -p "Press Enter to continue..."
}

schedule_run_backup() {
    clear
    echo -e "\033[1;37m▶️  Manual Full Backup Run\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 35))\033[0m"
    echo
    
    if ! is_remnawave_up; then
        echo -e "\033[1;31m❌ Remnawave services are not running!\033[0m"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo -e "\033[1;37m📦 Backup Type: Full System Backup\033[0m"
    echo -e "\033[38;5;250m   ✓ PostgreSQL Database (complete dump)\033[0m"
    echo -e "\033[38;5;250m   ✓ Environment files (.env, .env.subscription)\033[0m"
    echo -e "\033[38;5;250m   ✓ Docker Compose configuration\033[0m"
    echo -e "\033[38;5;250m   ✓ All additional config files (*.json, *.yml, etc.)\033[0m"
    echo -e "\033[38;5;250m   ✓ Configuration directories (certs, custom, etc.)\033[0m"
    echo
    echo -e "\033[38;5;250m🏃‍♂️ Running backup now...\033[0m"
    echo
    

    if [ ! -f "$BACKUP_SCRIPT_FILE" ]; then
        schedule_create_backup_script
    mkdir -p "$(dirname "$BACKUP_LOG_FILE")"
    
    echo "" >> "$BACKUP_LOG_FILE"
    echo "=============================================" >> "$BACKUP_LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MANUAL FULL BACKUP STARTED by user" >> "$BACKUP_LOG_FILE"
    echo "=============================================" >> "$BACKUP_LOG_FILE"
    
    bash "$BACKUP_SCRIPT_FILE" 2>&1 | tee -a "$BACKUP_LOG_FILE"
    
    local exit_code=${PIPESTATUS[0]}
    
    echo "=============================================" >> "$BACKUP_LOG_FILE"
    if [ $exit_code -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] MANUAL FULL BACKUP COMPLETED SUCCESSFULLY" >> "$BACKUP_LOG_FILE"
        echo -e "\033[1;32m🎉 Manual full backup completed successfully!\033[0m"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] MANUAL FULL BACKUP FAILED" >> "$BACKUP_LOG_FILE"
        echo -e "\033[1;31m❌ Manual full backup failed!\033[0m"
    fi
    echo "=============================================" >> "$BACKUP_LOG_FILE"
    echo "" >> "$BACKUP_LOG_FILE"
    
    echo
    echo -e "\033[1;37m📋 Backup Information:\033[0m"
    echo -e "\033[38;5;250m   Type: Full system backup (database + all configs)\033[0m"
    echo -e "\033[38;5;250m   Location: $APP_DIR/backups/\033[0m"
    echo -e "\033[38;5;250m   Logs: $BACKUP_LOG_FILE\033[0m"
    
    local latest_backup=$(ls -t "$APP_DIR/backups"/remnawave_scheduled_*.{tar.gz,sql} 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        local backup_size=$(du -sh "$latest_backup" | cut -f1)
        echo -e "\033[38;5;250m   Latest: $(basename "$latest_backup") ($backup_size)\033[0m"
    fi
    
    echo
    read -p "Press Enter to continue..."
}

schedule_cleanup() {
    clear
    echo -e "\033[1;37m🧹 Cleanup Old Backups\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 25))\033[0m"
    echo
    
    local backup_count=$(ls -1 "$BACKUP_DIR"/remnawave_*.sql* 2>/dev/null | wc -l)
    echo -e "\033[38;5;250mFound $backup_count backup files\033[0m"
    
    if [ "$backup_count" -eq 0 ]; then
        echo -e "\033[38;5;244mNo backup files to clean\033[0m"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo
    read -p "Delete backups older than how many days? [7]: " days
    days=${days:-7}
    
    if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ]; then
        echo -e "\033[1;31m❌ Invalid number!\033[0m"
        read -p "Press Enter to continue..."
        return
    fi
    
    local files_to_delete=$(find "$BACKUP_DIR" -name "remnawave_*.sql*" -type f -mtime +$days)
    local delete_count=$(echo "$files_to_delete" | wc -l)
    
    if [ -z "$files_to_delete" ]; then
        echo -e "\033[38;5;250mNo files older than $days days found\033[0m"
    else
        echo -e "\033[38;5;250mFiles to delete ($delete_count):\033[0m"
        echo "$files_to_delete" | while read file; do
            echo -e "\033[38;5;244m   $(basename "$file")\033[0m"
        done
        
        echo
        read -p "Proceed with deletion? [y/N]: " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            echo "$files_to_delete" | xargs rm -f
            echo -e "\033[1;32m✅ Deleted $delete_count old backup files\033[0m"
        else
            echo -e "\033[38;5;250mCleanup cancelled\033[0m"
        fi
    fi
    
    read -p "Press Enter to continue..."
}

# Сброс конфигурации
schedule_reset_config() {
    echo
    read -p "Reset all backup configuration to defaults? [y/N]: " confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        cat > "$BACKUP_CONFIG_FILE" << 'EOF'
{
  "schedule": "0 2 * * *",
  "compression": {
    "enabled": true,
    "level": 6
  },
  "retention": {
    "days": 7,
    "min_backups": 3
  },
  "telegram": {
    "enabled": false,
    "bot_token": null,
    "chat_id": null,
    "thread_id": null,
    "split_large_files": true,
    "max_file_size": 49,
    "api_server": "https://api.telegram.org",
    "use_custom_api": false
  }
}
EOF
        echo -e "\033[1;32m✅ Configuration reset to defaults\033[0m"
    else
        echo -e "\033[38;5;250mReset cancelled\033[0m"
    fi
    
    sleep 2
}

# Справка
schedule_help() {
    clear
    echo -e "\033[1;37m📚 Backup Scheduler Help\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
    echo
    echo -e "\033[1;37mCommands:\033[0m"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "setup" "🔧 Configure backup settings"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "enable" "✅ Enable scheduler"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "disable" "❌ Disable scheduler"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "status" "📊 Show status"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "test" "🧪 Test backup creation"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "test-telegram" "📱 Test Telegram delivery"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "run" "▶️  Run backup now"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "logs" "📋 View logs"
    printf "   \033[38;5;15m%-15s\033[0m %s\n" "cleanup" "🧹 Clean old backups"
    echo
    read -p "Press Enter to continue..."
}

generate_random_string() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex $((${1}/2))
    else
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1} | head -n 1
    fi
}

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
    
    # Проверяем на конфликт с известными сервисами
    case "$port" in
        22|80|443|53|25|110|143|993|995)
            colorized_echo yellow "Warning: Port $port is commonly used by system services"
            ;;
    esac
    
    return 0
}

get_occupied_ports() {
    local ports=""
    
    if command -v ss &>/dev/null; then
        ports=$(ss -tuln 2>/dev/null | awk 'NR>1 {print $5}' | grep -Eo '[0-9]+$' | sort -n | uniq)
    elif command -v netstat &>/dev/null; then
        ports=$(netstat -tuln 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eo '[0-9]+$' | sort -n | uniq)
    else
        colorized_echo yellow "Installing network tools for port checking..."
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

sanitize_domain() {
    # Remove leading/trailing whitespace, trailing slashes, and protocol
    echo "$1" | sed -e 's|^https\?://||' -e 's|/$||' | xargs
}

validate_domain() {
    local domain="$1"
    # Check if domain contains slashes or spaces after sanitization
    if [[ "$domain" == */* ]] || [[ "$domain" == *\ * ]]; then
        return 1
    fi
    return 0
}

validate_prefix() {
    local prefix="$1"
    # Check if prefix contains only alphanumeric characters and hyphens
    if [[ ! "$prefix" =~ ^[a-zA-Z0-9-]+$ ]]; then
        return 1
    fi
    return 0
}

install_remnawave() {
    mkdir -p "$APP_DIR"

    # Generate random JWT secrets using openssl if available
    JWT_AUTH_SECRET=$(openssl rand -hex 128)
    JWT_API_TOKENS_SECRET=$(openssl rand -hex 128)

    # Generate random metrics credentials
    METRICS_USER=$(generate_random_string 12)
    METRICS_PASS=$(generate_random_string 32)

    # Check for occupied ports
    get_occupied_ports

    # Default ports
    DEFAULT_APP_PORT=3000
    DEFAULT_METRICS_PORT=3001
    DEFAULT_SUB_PAGE_PORT=3010
    DEFAULT_DB_PORT=6767

    # Check if default ports are occupied and ask for alternatives if needed
    APP_PORT=$DEFAULT_APP_PORT
    if is_port_occupied "$APP_PORT"; then
        colorized_echo yellow "Default APP_PORT $APP_PORT is already in use."
        while true; do
            read -p "Enter an alternative APP_PORT: " -r APP_PORT
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
    fi

    METRICS_PORT=$DEFAULT_METRICS_PORT
    if is_port_occupied "$METRICS_PORT"; then
        colorized_echo yellow "Default METRICS_PORT $METRICS_PORT is already in use."
        while true; do
            read -p "Enter an alternative METRICS_PORT: " -r METRICS_PORT
            if [[ "$METRICS_PORT" -ge 1 && "$METRICS_PORT" -le 65535 ]]; then
                if is_port_occupied "$METRICS_PORT"; then
                    colorized_echo red "Port $METRICS_PORT is already in use. Please enter another port."
                else
                    break
                fi
            else
                colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
            fi
        done
    fi

    SUB_PAGE_PORT=$DEFAULT_SUB_PAGE_PORT
    if is_port_occupied "$SUB_PAGE_PORT"; then
        colorized_echo yellow "Default subscription page port $SUB_PAGE_PORT is already in use."
        while true; do
            read -p "Enter an alternative subscription page port: " -r SUB_PAGE_PORT
            if [[ "$SUB_PAGE_PORT" -ge 1 && "$SUB_PAGE_PORT" -le 65535 ]]; then
                if is_port_occupied "$SUB_PAGE_PORT"; then
                    colorized_echo red "Port $SUB_PAGE_PORT is already in use. Please enter another port."
                else
                    break
                fi
            else
                colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
            fi
        done
    fi

    DB_PORT=$DEFAULT_DB_PORT
    if is_port_occupied "$DB_PORT"; then
        colorized_echo yellow "Default DB_PORT $DB_PORT is already in use."
        while true; do
            read -p "Enter an alternative DB_PORT: " -r DB_PORT
            if [[ "$DB_PORT" -ge 1 && "$DB_PORT" -le 65535 ]]; then
                if is_port_occupied "$DB_PORT"; then
                    colorized_echo red "Port $DB_PORT is already in use. Please enter another port."
                else
                    break
                fi
            else
                colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
            fi
        done
    fi

    # Ask for domain names
    while true; do
        read -p "Enter the panel domain (e.g., panel.example.com or * for any domain): " -r FRONT_END_DOMAIN
        FRONT_END_DOMAIN=$(sanitize_domain "$FRONT_END_DOMAIN")
        if [[ "$FRONT_END_DOMAIN" == http* ]]; then
            colorized_echo red "Please enter only the domain without http:// or https://"
        elif [[ -z "$FRONT_END_DOMAIN" ]]; then
            colorized_echo red "Domain cannot be empty"
        elif ! validate_domain "$FRONT_END_DOMAIN" && [[ "$FRONT_END_DOMAIN" != "*" ]]; then
            colorized_echo red "Invalid domain format. Domain should not contain slashes or spaces."
        else
            break
        fi
    done

    # Ask for subscription page domain and prefix
    while true; do
        read -p "Enter the subscription page domain (e.g., sub-link.example.com): " -r SUB_DOMAIN
        SUB_DOMAIN=$(sanitize_domain "$SUB_DOMAIN")
        if [[ "$SUB_DOMAIN" == http* ]]; then
            colorized_echo red "Please enter only the domain without http:// or https://"
        elif [[ -z "$SUB_DOMAIN" ]]; then
            colorized_echo red "Domain cannot be empty"
        elif [[ "$SUB_DOMAIN" == */* ]]; then
            colorized_echo red "Invalid domain format. Domain should not contain slashes."
        elif ! validate_domain "$SUB_DOMAIN"; then
            colorized_echo red "Invalid domain format. Domain should not contain slashes or spaces."
        else
            break
        fi
    done

    while true; do
        read -p "Enter the subscription page prefix (default: sub): " -r CUSTOM_SUB_PREFIX
        if [[ -z "$CUSTOM_SUB_PREFIX" ]]; then
            CUSTOM_SUB_PREFIX="sub"
            break
        elif ! validate_prefix "$CUSTOM_SUB_PREFIX"; then
            colorized_echo red "Invalid prefix format. Prefix should contain only letters, numbers, and hyphens."
        else
            break
        fi
    done

    # Construct SUB_PUBLIC_DOMAIN with the prefix
    SUB_PUBLIC_DOMAIN="${SUB_DOMAIN}/${CUSTOM_SUB_PREFIX}"

    # Ask for META_TITLE and META_DESCRIPTION
    read -p "Enter the META_TITLE for subscription page (default: 'Remnawave VPN - Your Subscription Page'): " -r META_TITLE
    if [[ -z "$META_TITLE" ]]; then
        META_TITLE="Remnawave VPN - Your Subscription Page"
    fi

    read -p "Enter the META_DESCRIPTION for subscription page (default: 'Remnawave VPN - The best VPN service'): " -r META_DESCRIPTION
    if [[ -z "$META_DESCRIPTION" ]]; then
        META_DESCRIPTION="Remnawave VPN - The best VPN service"
    fi

    # Ask about Telegram integration
    read -p "Do you want to enable Telegram notifications? (y/n): " -r enable_telegram
    IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_NOTIFY_USERS_CHAT_ID=""
    TELEGRAM_NOTIFY_NODES_CHAT_ID=""
    TELEGRAM_NOTIFY_NODES_THREAD_ID=""
    TELEGRAM_NOTIFY_USERS_THREAD_ID=""

    if [[ "$enable_telegram" =~ ^[Yy]$ ]]; then
        IS_TELEGRAM_NOTIFICATIONS_ENABLED=true
        read -p "Enter your Telegram Bot Token: " -r TELEGRAM_BOT_TOKEN
        read -p "Enter your Users Notify Chat ID: " -r TELEGRAM_NOTIFY_USERS_CHAT_ID
        read -p "Enter your Nodes Notify Chat ID (default: same as Users Notify Chat ID): " -r TELEGRAM_NOTIFY_NODES_CHAT_ID
        if [[ -z "$TELEGRAM_NOTIFY_NODES_CHAT_ID" ]]; then
            TELEGRAM_NOTIFY_NODES_CHAT_ID="$TELEGRAM_NOTIFY_USERS_CHAT_ID"
        fi
        read -p "Enter your Users Notify Thread ID (optional): " -r TELEGRAM_NOTIFY_USERS_THREAD_ID
        read -p "Enter your Nodes Notify Thread ID (optional): " -r TELEGRAM_NOTIFY_NODES_THREAD_ID
        if [[ -z "$TELEGRAM_NOTIFY_NODES_THREAD_ID" ]]; then
            TELEGRAM_NOTIFY_NODES_THREAD_ID="$TELEGRAM_NOTIFY_USERS_THREAD_ID"
        fi
    fi

    # Ask about Telegram OAuth authorization
    read -p "Do you want to enable Telegram OAuth login for admin panel? (y/n): " -r enable_telegram_oauth
    TELEGRAM_OAUTH_ENABLED=false
    TELEGRAM_OAUTH_ADMIN_IDS=""

    if [[ "$enable_telegram_oauth" =~ ^[Yy]$ ]]; then
        TELEGRAM_OAUTH_ENABLED=true
        while true; do
            read -p "Enter Telegram Admin IDs (comma-separated, digits only, e.g. 123456789,987654321): " -r input_ids
            input_ids=$(echo "$input_ids" | tr -d ' ')
            if [[ "$input_ids" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                TELEGRAM_OAUTH_ADMIN_IDS="[$input_ids]"
                break
            else
                colorized_echo red "Invalid format! Please enter comma-separated numeric IDs only (no spaces)."
            fi
        done

        if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
            colorized_echo yellow "You have not provided a Telegram Bot Token yet. Enter Bot Token for OAuth to work (leave empty to skip): " -r TELEGRAM_BOT_TOKEN
        fi

        if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
            colorized_echo red "Bot token is required for Telegram OAuth. OAuth will be disabled."
            TELEGRAM_OAUTH_ENABLED=false
            TELEGRAM_OAUTH_ADMIN_IDS=""
        fi
    fi

    # Determine image tag based on --dev flag
    BACKEND_IMAGE_TAG="latest"
    if [ "$USE_DEV_BRANCH" == "true" ]; then
        BACKEND_IMAGE_TAG="dev"
    fi

    colorized_echo blue "Generating .env file"
    cat > "$ENV_FILE" <<EOL
### APP ###
APP_PORT=$APP_PORT
METRICS_PORT=$METRICS_PORT

### REDIS ###
REDIS_HOST=remnawave-redis
REDIS_PORT=6379

### API ###
# Possible values: max (start instances on all cores), number (start instances on number of cores), -1 (start instances on all cores - 1)
# !!! Do not set this value more that physical cores count in your machine !!!
API_INSTANCES=max

### DATABASE ###
# FORMAT: postgresql://{user}:{password}@{host}:{port}/{database}
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### JWT ###
### CHANGE DEFAULT VALUES ###
JWT_AUTH_SECRET=$JWT_AUTH_SECRET
JWT_API_TOKENS_SECRET=$JWT_API_TOKENS_SECRET

### TELEGRAM ###
IS_TELEGRAM_NOTIFICATIONS_ENABLED=$IS_TELEGRAM_NOTIFICATIONS_ENABLED
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_NOTIFY_USERS_CHAT_ID=$TELEGRAM_NOTIFY_USERS_CHAT_ID
TELEGRAM_NOTIFY_NODES_CHAT_ID=$TELEGRAM_NOTIFY_NODES_CHAT_ID
TELEGRAM_NOTIFY_NODES_THREAD_ID=$TELEGRAM_NOTIFY_NODES_THREAD_ID
TELEGRAM_NOTIFY_USERS_THREAD_ID=$TELEGRAM_NOTIFY_USERS_THREAD_ID

### TELEGRAM OAUTH ###
TELEGRAM_OAUTH_ENABLED=$TELEGRAM_OAUTH_ENABLED
TELEGRAM_OAUTH_ADMIN_IDS=$TELEGRAM_OAUTH_ADMIN_IDS

### FRONT_END ###
# Domain for panel access. Can be set to * to accept any domain
FRONT_END_DOMAIN=$FRONT_END_DOMAIN

### SUBSCRIPTION PUBLIC DOMAIN ###
### RAW DOMAIN, WITHOUT HTTP/HTTPS, DO NOT PLACE / to end of domain ###
SUB_PUBLIC_DOMAIN=$SUB_PUBLIC_DOMAIN

### SWAGGER ###
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=false

### PROMETHEUS ###
### Metrics are available at /api/metrics
METRICS_USER=$METRICS_USER
METRICS_PASS=$METRICS_PASS

### WEBHOOK ###
WEBHOOK_ENABLED=false
### Only https:// is allowed
#WEBHOOK_URL=https://webhook.site/1234567890
### This secret is used to sign the webhook payload, must be exact 64 characters. Only a-z, 0-9, A-Z are allowed.
#WEBHOOK_SECRET_HEADER=vsmu67Kmg6R8FjIOF1WUY8LWBHie4scdEqrfsKmyf4IAf8dY3nFS0wwYHkhh6ZvQ

### CLOUDFLARE ###
# USED ONLY FOR docker-compose-prod-with-cf.yml
# NOT USED BY THE APP ITSELF
#CLOUDFLARE_TOKEN=ey...

### Database ###
### For Postgres Docker container ###
# NOT USED BY THE APP ITSELF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
#JWT_SECRET_KEY=1d9ca50cefda20fe710bca86ca829c919334055e07623d090987680391524b8e
HWID_DEVICE_LIMIT_ENABLED=false
HWID_FALLBACK_DEVICE_LIMIT=10
HWID_MAX_DEVICES_ANNOUNCE="You have reached the maximum number of devices for your subscription."
EOL
    colorized_echo green "Environment file saved in $ENV_FILE"

SUB_ENV_FILE="$APP_DIR/.env.subscription"

colorized_echo blue "Generating .env.subscription for subscription-page"
cat > "$SUB_ENV_FILE" <<EOL
### Remnawave Panel URL, can be http://remnawave:3000 or https://panel.example.com
REMNAWAVE_PANEL_URL=http://${APP_NAME}:${APP_PORT}

APP_PORT=${SUB_PAGE_PORT}

# Serve at custom root path, for example, this value can be: CUSTOM_SUB_PREFIX=sub
# Do not place / at the start/end
CUSTOM_SUB_PREFIX=${CUSTOM_SUB_PREFIX}

# Support Marzban links
#MARZBAN_LEGACY_LINK_ENABLED=false
#MARZBAN_LEGACY_SECRET_KEY=
#REMNAWAVE_API_TOKEN=

### META FOR SUBSCRIPTION PAGE ###
META_TITLE="$META_TITLE"
META_DESCRIPTION="$META_DESCRIPTION"

# If you use "Caddy with security" addon, you can place here X-Api-Key, which will be applied to requests to Remnawave Panel.
#CADDY_AUTH_API_TOKEN=

EOL
colorized_echo green "Subscription environment saved in $SUB_ENV_FILE"

    # Create app-config.json for subscription page with app and instruction links
colorized_echo blue "Generating static app-config.json file"
cat > "$APP_CONFIG_FILE" <<'EOL'

{
    "ios": [
        {
            "id": "happ",
            "name": "Happ",
            "isFeatured": true,
            "urlScheme": "happ://add/",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://apps.apple.com/us/app/happ-proxy-utility/id6504287215",
                        "buttonText": {
                            "en": "Open in App Store",
                            "fa": "باز کردن در App Store",
                            "ru": "Открыть в App Store"
                        }
                    }
                ],
                "description": {
                    "en": "Open the page in App Store and install the app. Launch it, in the VPN configuration permission window click Allow and enter your passcode.",
                    "fa": "صفحه را در App Store باز کنید و برنامه را نصب کنید. آن را اجرا کنید، در پنجره مجوز پیکربندی VPN روی Allow کلیک کنید و رمز عبور خود را وارد کنید.",
                    "ru": "Откройте страницу в App Store и установите приложение. Запустите его, в окне разрешения VPN-конфигурации нажмите Allow и введите свой пароль."
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below — the app will open and the subscription will be added automatically",
                    "fa": "برای افزودن خودکار اشتراک روی دکمه زیر کلیک کنید - برنامه باز خواهد شد",
                    "ru": "Нажмите кнопку ниже — приложение откроется, и подписка добавится автоматически."
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "In the main section, click the large power button in the center to connect to VPN. Don't forget to select a server from the server list.",
                    "fa": "در بخش اصلی، دکمه بزرگ روشن/خاموش در مرکز را برای اتصال به VPN کلیک کنید. فراموش نکنید که یک سرور را از لیست سرورها انتخاب کنید.",
                    "ru": "В главном разделе нажмите большую кнопку включения в центре для подключения к VPN. Не забудьте выбрать сервер в списке серверов."
                }
            }
        },
        {
            "id": "v2raytun",
            "viewPosition": 2,
            "name": "V2RayTun",
            "isFeatured": false,
            "urlScheme": "v2raytun://import/",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://apps.apple.com/ru/app/v2raytun/id6476628951",
                        "buttonText": {
                            "en": "Open in App Store",
                            "fa": "باز کردن در App Store",
                            "ru": "Открыть в App Store"
                        }
                    }
                ],
                "description": {
                    "en": "Open the page in App Store and install the app. Launch it, in the VPN configuration permission window click Allow and enter your passcode.",
                    "fa": "صفحه را در App Store باز کنید و برنامه را نصب کنید. آن را اجرا کنید، در پنجره مجوز پیکربندی VPN روی Allow کلیک کنید و رمز عبور خود را وارد کنید.",
                    "ru": "Откройте страницу в App Store и установите приложение. Запустите его, в окне разрешения VPN-конфигурации нажмите Allow и введите свой пароль."
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below — the app will open and the subscription will be added automatically",
                    "fa": "برای افزودن خودکار اشتراک روی دکمه زیر کلیک کنید - برنامه باز خواهد شد",
                    "ru": "Нажмите кнопку ниже — приложение откроется, и подписка добавится автоматически."
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "Select a server and press the connect button.",
                    "fa": "یک سرور را انتخاب کنید و دکمه اتصال را فشار دهید.",
                    "ru": "Выберите сервер и нажмите кнопку подключения."
                }
            }
        },
        {
            "id": "shadowrocket",
            "viewPosition": 3,
            "name": "Shadowrocket",
            "isFeatured": false,
            "urlScheme": "sub://",
            "isNeedBase64Encoding": true,
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://apps.apple.com/ru/app/shadowrocket/id932747118",
                        "buttonText": {
                            "en": "Open in App Store",
                            "fa": "باز کردن در App Store",
                            "ru": "Открыть в App Store"
                        }
                    }
                ],
                "description": {
                    "en": "Open the page in App Store and install the app. Launch it, in the VPN configuration permission window click Allow and enter your passcode.",
                    "fa": "صفحه را در App Store باز کنید و برنامه را نصب کنید. آن را اجرا کنید، در پنجره مجوز پیکربندی VPN روی Allow کلیک کنید و رمز عبور خود را وارد کنید.",
                    "ru": "Откройте страницу в App Store и установите приложение. Запустите его, в окне разрешения VPN-конфигурации нажмите Allow и введите свой пароль."
                }
            },
            "additionalBeforeAddSubscriptionStep": {
                "buttons": [
                    {
                        "buttonLink": "shadowrocket://config/add/https://dignezzz.github.io/ru_direct.conf",
                        "buttonText": {
                            "en": "Add routing",
                            "fa": "افزودن مسیر",
                            "ru": "Добавить роутинг"
                        }
                    }
                ],
                "title": {
                    "en": "Add routing",
                    "fa": "افزودن مسیر",
                    "ru": "Добавить роутинг"
                },
                "description": {
                    "en": "Click the button below to add the ru_direct.conf configuration file.",
                    "fa": "برای افزودن فایل پیکربندی ru_direct.conf روی دکمه زیر کلیک کنید.",
                    "ru": "Нажмите кнопку ниже, чтобы добавить файл конфигурации ru_direct.conf."
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below — the app will open and the subscription will be added automatically",
                    "fa": "برای افزودن خودکار اشتراک روی دکمه زیر کلیک کنید - برنامه باز خواهد شد",
                    "ru": "Нажмите кнопку ниже — приложение откроется, и подписка добавится автоматически."
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "Select a server and press the connect button.",
                    "fa": "یک سرور را انتخاب کنید و دکمه اتصال را فشار دهید.",
                    "ru": "Выберите сервер и нажмите кнопку подключения."
                }
            }
        }
    ],
    "android": [
        {
            "id": "happ",
            "name": "Happ",
            "isFeatured": true,
            "urlScheme": "happ://add/",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://play.google.com/store/apps/details?id=com.happproxy",
                        "buttonText": {
                            "en": "Open in Google Play",
                            "fa": "باز کردن در Google Play",
                            "ru": "Открыть в Google Play"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/Happ-proxy/happ-android/releases/latest/download/Happ.apk",
                        "buttonText": {
                            "en": "Download APK",
                            "fa": "دانلود APK",
                            "ru": "Скачать APK"
                        }
                    }
                ],
                "description": {
                    "en": "Open the page in Google Play and install the app. Or install the app directly from the APK file if Google Play is not working.",
                    "fa": "صفحه را در Google Play باز کنید و برنامه را نصب کنید. یا برنامه را مستقیماً از فایل APK نصب کنید، اگر Google Play کار نمی کند.",
                    "ru": "Откройте страницу в Google Play и установите приложение. Или установите приложение из APK файла напрямую, если Google Play не работает."
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below to add subscription",
                    "fa": "برای افزودن اشتراک روی دکمه زیر کلیک کنید",
                    "ru": "Нажмите кнопку ниже, чтобы добавить подписку"
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "Open the app and connect to the server",
                    "fa": "برنامه را باز کنید و به سرور متصل شوید",
                    "ru": "Откройте приложение и подключитесь к серверу"
                }
            }
        },
        {
            "id": "v2raytun",
            "name": "V2RayTun",
            "isFeatured": false,
            "urlScheme": "v2raytun://import/",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://play.google.com/store/apps/details?id=com.v2raytun.android",
                        "buttonText": {
                            "en": "Open in Google Play",
                            "fa": "باز کردن در Google Play",
                            "ru": "Открыть в Google Play"
                        }
                    }
                ],
                "description": {
                    "en": "Open the page in Google Play and install the app.",
                    "fa": "صفحه را در Google Play باز کنید و برنامه را نصب کنید.",
                    "ru": "Откройте страницу в Google Play и установите приложение."
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below to add subscription",
                    "fa": "برای افزودن اشتراک روی دکمه زیر کلیک کنید",
                    "ru": "Нажмите кнопку ниже, чтобы добавить подписку"
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "Select a server and press the connect button.",
                    "fa": "یک سرور را انتخاب کنید و دکمه اتصال را فشار دهید.",
                    "ru": "Выберите сервер и нажмите кнопку подключения."
                }
            }
        },
        {
            "id": "hiddify",
            "name": "Hiddify",
            "isFeatured": false,
            "urlScheme": "hiddify://import/",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://play.google.com/store/apps/details?id=app.hiddify.com",
                        "buttonText": {
                            "en": "Open in Google Play",
                            "fa": "باز کردن در Google Play",
                            "ru": "Открыть в Google Play"
                        }
                    }
                ],
                "description": {
                    "en": "Open the page in Google Play and install the app.",
                    "fa": "صفحه را در Google Play باز کنید و برنامه را نصب کنید.",
                    "ru": "Откройте страницу в Google Play и установите приложение."
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below to add subscription",
                    "fa": "برای افزودن اشتراک روی دکمه زیر کلیک کنید",
                    "ru": "Нажмите кнопку ниже, чтобы добавить подписку"
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "Select a server and connect.",
                    "fa": "یک سرور را انتخاب کنید و متصل شوید.",
                    "ru": "Выберите сервер и подключитесь."
                }
            }
        },
        {
            "id": "clash-meta",
            "name": "Clash Meta",
            "isFeatured": false,
            "urlScheme": "clash://install-config?url=",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://github.com/MetaCubeX/ClashMetaForAndroid/releases/download/v2.11.7/cmfa-2.11.7-meta-universal-release.apk",
                        "buttonText": {
                            "en": "Download APK",
                            "fa": "دانلود APK",
                            "ru": "Скачать APK"
                        }
                    },
                    {
                        "buttonLink": "https://f-droid.org/packages/com.github.metacubex.clash.meta/",
                        "buttonText": {
                            "en": "Open in F-Droid",
                            "fa": "در F-Droid باز کنید",
                            "ru": "Открыть в F-Droid"
                        }
                    }
                ],
                "description": {
                    "en": "Download and install Clash Meta APK",
                    "fa": "دانلود و نصب Clash Meta APK",
                    "ru": "Скачайте и установите Clash Meta APK"
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Tap the button to import configuration",
                    "fa": "برای وارد کردن پیکربندی روی دکمه ضربه بزنید",
                    "ru": "Нажмите кнопку, чтобы импортировать конфигурацию"
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "Open Clash Meta and tap on Connect",
                    "fa": "Clash Meta را باز کنید و روی اتصال ضربه بزنید",
                    "ru": "Откройте Clash Meta и нажмите Подключиться"
                }
            }
        }
    ],
    "pc": [
        {
            "id": "hiddify",
            "name": "Hiddify",
            "isFeatured": true,
            "urlScheme": "hiddify://import/",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://github.com/hiddify/hiddify-app/releases/download/v2.5.7/Hiddify-Windows-Setup-x64.exe",
                        "buttonText": {
                            "en": "Windows",
                            "fa": "ویندوز",
                            "ru": "Windows"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/hiddify/hiddify-app/releases/download/v2.5.7/Hiddify-MacOS.dmg",
                        "buttonText": {
                            "en": "macOS",
                            "fa": "مک",
                            "ru": "macOS"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/hiddify/hiddify-app/releases/download/v2.5.7/Hiddify-Linux-x64.AppImage",
                        "buttonText": {
                            "en": "Linux",
                            "fa": "لینوکس",
                            "ru": "Linux"
                        }
                    }
                ],
                "description": {
                    "en": "Choose the version for your device, click the button below and install the app.",
                    "fa": "نسخه مناسب برای دستگاه خود را انتخاب کنید، دکمه زیر را فشار دهید و برنامه را نصب کنید",
                    "ru": "Выберите подходящую версию для вашего устройства, нажмите на кнопку ниже и установите приложение."
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below to add subscription",
                    "fa": "برای افزودن اشتراک روی دکمه زیر کلیک کنید",
                    "ru": "Нажмите кнопку ниже, чтобы добавить подписку"
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "In the main section, click the large power button in the center to connect to VPN. Don't forget to select a server from the server list. If needed, select a different server from the server list.",
                    "fa": "در بخش اصلی، دکمه بزرگ روشن/خاموش در مرکز را برای اتصال به VPN کلیک کنید. فراموش نکنید که یک سرور را از لیست سرورها انتخاب کنید. در صورت نیاز، سرور دیگری را از لیست سرورها انتخاب کنید.",
                    "ru": "В главном разделе нажмите большую кнопку включения в центре для подключения к VPN. Не забудьте выбрать сервер в списке серверов. При необходимости выберите другой сервер из списка серверов."
                }
            }
        },
        {
            "id": "flclash",
            "name": "FLClash",
            "isFeatured": false,
            "urlScheme": "clash://install-config?url=",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://github.com/chen08209/FlClash/releases/download/v0.8.80/FlClash-0.8.80-windows-amd64-setup.exe",
                        "buttonText": {
                            "en": "Windows",
                            "fa": "ویندوز",
                            "ru": "Windows"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/chen08209/FlClash/releases/download/v0.8.80/FlClash-0.8.80-macos-arm64.dmg",
                        "buttonText": {
                            "en": "macOS Apple Silicon",
                            "fa": "مک (Apple Silicon)",
                            "ru": "macOS (Apple Silicon)"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/chen08209/FlClash/releases/download/v0.8.80/FlClash-0.8.80-macos-amd64.dmg",
                        "buttonText": {
                            "en": "macOS Intel x64",
                            "fa": "مک (Intel x64)",
                            "ru": "macOS (Intel x64)"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/chen08209/FlClash/releases/download/v0.8.80/FlClash-0.8.80-linux-amd64.AppImage",
                        "buttonText": {
                            "en": "Linux",
                            "fa": "لینوکس",
                            "ru": "Linux"
                        }
                    }
                ],
                "description": {
                    "en": "Choose the version for your device, click the button below and install the app.",
                    "fa": "نسخه مناسب برای دستگاه خود را انتخاب کنید، دکمه زیر را فشار دهید و برنامه را نصب کنید",
                    "ru": "Выберите подходящую версию для вашего устройства, нажмите на кнопку ниже и установите приложение."
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below to add subscription",
                    "fa": "برای افزودن اشتراک روی دکمه زیر کلیک کنید",
                    "ru": "Нажмите кнопку ниже, чтобы добавить подписку"
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "Select a server and activate the connection.",
                    "fa": "یک سرور را انتخاب کنید و اتصال را فعال کنید.",
                    "ru": "Выберите сервер и активируйте подключение."
                }
            }
        },
        {
            "id": "clash-verge",
            "name": "Clash Verge",
            "isFeatured": false,
            "urlScheme": "clash://install-config?url=",
            "installationStep": {
                "buttons": [
                    {
                        "buttonLink": "https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v2.2.2/Clash.Verge_2.2.2_x64-setup.exe",
                        "buttonText": {
                            "en": "Windows",
                            "fa": "ویندوز",
                            "ru": "Windows"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v2.2.2/Clash.Verge_2.2.2_x64.dmg",
                        "buttonText": {
                            "en": "macOS (Intel)",
                            "fa": "مک (اینتل)",
                            "ru": "macOS (Intel)"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v2.2.2/Clash.Verge_2.2.2_aarch64.dmg",
                        "buttonText": {
                            "en": "macOS (Apple Silicon)",
                            "fa": "مک (Apple Silicon)",
                            "ru": "macOS (Apple Silicon)"
                        }
                    },
                    {
                        "buttonLink": "https://github.com/clash-verge-rev/clash-verge-rev/releases",
                        "buttonText": {
                            "en": "Linux",
                            "fa": "لینوکس",
                            "ru": "Linux"
                        }
                    }
                ],
                "description": {
                    "en": "Choose the version for your device, click the button below and install the app.",
                    "fa": "نسخه مناسب برای دستگاه خود را انتخاب کنید، دکمه زیر را فشار دهید و برنامه را نصب کنید",
                    "ru": "Выبерите подходящую версию для вашего устройства, нажмите на кнопку ниже и установите приложение."
                }
            },
            "additionalBeforeAddSubscriptionStep": {
                "buttons": [],
                "description": {
                    "en": "After launching the app, you can change the language in settings. In the left panel, find the gear icon, then navigate to Verge 设置 and select 语言设置.",
                    "fa": "پس از راه‌اندازی برنامه، می‌توانید زبان را در تنظیمات تغییر دهید. در پنل سمت چپ، نماد چرخ دنده را پیدا کنید، سپس به Verge 设置 بروید و 语言设置 را انتخاب کنید.",
                    "ru": "После запуска приложения вы можете сменить язык в настройках. В левой панели найдите иконку шестеренки, далее ориентируйтесь на Verge 设置 и выберите пункт 语言设置."
                },
                "title": {
                    "en": "Change language",
                    "fa": "تغییر زبان",
                    "ru": "Смена языка"
                }
            },
            "addSubscriptionStep": {
                "description": {
                    "en": "Click the button below to add subscription",
                    "fa": "برای افزودن اشتراک روی دکمه زیر کلیک کنید",
                    "ru": "Нажмите кнопку ниже, чтобы добавить подписку"
                }
            },
            "additionalAfterAddSubscriptionStep": {
                "buttons": [],
                "title": {
                    "en": "If the subscription is not added",
                    "fa": "اگر اشتراک در برنامه نصب نشده است",
                    "ru": "Если подписка не добавилась"
                },
                "description": {
                    "en": "If nothing happens after clicking the button, add the subscription manually. Click the Get Link button in the top right corner of this page, copy the link. In Clash Verge, go to the Profiles section and paste the link in the text field, then click the Import button.",
                    "fa": "اگر پس از کلیک روی دکمه اتفاقی نیفتاد، اشتراک را به صورت دستی اضافه کنید. در گوشه بالا سمت راست این صفحه روی دکمه دریافت لینک کلیک کنید، لینک را کپی کنید. در Clash Verge به بخش پروفایل‌ها بروید و لینک را در فیلد متنی وارد کنید، سپس روی دکمه وارد کردن کلیک کنید.",
                    "ru": "Если после нажатия на кнопку ничего не произошло, добавьте подписку вручную. Нажмите на этой странице кнопку Получить ссылку в правом верхнем углу, скопируйте ссылку. В Clash Verge перейдите в раздел Профили и вставьте ссылку в текстовое поле, затем нажмите на кнопку Импорт."
                }
            },
            "connectAndUseStep": {
                "description": {
                    "en": "You can select a server in the Proxy section, and enable VPN in the Settings section. Set the TUN Mode switch to ON.",
                    "fa": "می‌توانید در بخش پروکسی سرور را انتخاب کنید و در بخش تنظیمات VPN را فعال کنید. کلید TUN Mode را در حالت روشن قرار دهید.",
                    "ru": "Выбрать сервер можно в разделе Прокси, включить VPN можно в разделе Настройки. Установите переключатель TUN Mode в положение ВКЛ."
                }
            }
        }
    ]
}

EOL
colorized_echo green "Static instruction file saved in $APP_CONFIG_FILE"


    colorized_echo blue "Generating docker-compose.yml file"
    cat > "$COMPOSE_FILE" <<EOL
services:
    remnawave-db:
        image: postgres:17
        container_name: '${APP_NAME}-db'
        hostname: ${APP_NAME}-db
        restart: always
        env_file:
            - .env
        environment:
            - POSTGRES_USER=\${POSTGRES_USER}
            - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
            - POSTGRES_DB=\${POSTGRES_DB}
            - TZ=UTC
        ports:
            - '127.0.0.1:6767:5432'
        volumes:
            - ${APP_NAME}-db-data:/var/lib/postgresql/data
        networks:
            - ${APP_NAME}-network
        healthcheck:
            test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
            interval: 3s
            timeout: 10s
            retries: 3
        logging:
          driver: json-file
          options:
            max-size: "30m"
            max-file: "5"


    remnawave:
        image: remnawave/backend:${BACKEND_IMAGE_TAG}
        container_name: '${APP_NAME}'
        hostname: ${APP_NAME}
        restart: always
        ports:
            - '127.0.0.1:${APP_PORT}:${APP_PORT}'
            - '127.0.0.1:${METRICS_PORT}:${METRICS_PORT}'
        env_file:
            - .env
        networks:
            - ${APP_NAME}-network
        depends_on:
          remnawave-db:
            condition: service_healthy
          remnawave-redis:
            condition: service_healthy
        logging:
          driver: json-file
          options:
            max-size: "30m"
            max-file: "5"
            

    remnawave-subscription-page:
        image: remnawave/subscription-page:latest
        container_name: ${APP_NAME}-subscription-page
        hostname: ${APP_NAME}-subscription-page
        restart: always
        env_file:
            - .env.subscription
# Picked up from file .env.subscription
#        environment:
#            - REMNAWAVE_PLAIN_DOMAIN=http://${APP_NAME}:${APP_PORT}
#            - SUBSCRIPTION_PAGE_PORT=${SUB_PAGE_PORT}
#            - CUSTOM_SUB_PREFIX=${CUSTOM_SUB_PREFIX}
#            - META_TITLE=${META_TITLE}
#            - META_DESCRIPTION=${META_DESCRIPTION}
        ports:
            - '127.0.0.1:${SUB_PAGE_PORT}:${SUB_PAGE_PORT}'
        networks:
            - ${APP_NAME}-network
        volumes:
            - ${APP_DIR}/app-config.json:/opt/app/frontend/assets/app-config.json
        logging:
          driver: json-file
          options:
            max-size: "30m"
            max-file: "5"
            

    remnawave-redis:
        image: valkey/valkey:8.0.2-alpine
        container_name: ${APP_NAME}-redis
        hostname: ${APP_NAME}-redis
        restart: always
        networks:
            - ${APP_NAME}-network
        volumes:
            - ${APP_NAME}-redis-data:/data
        healthcheck:
            test: [ "CMD", "valkey-cli", "ping" ]
            interval: 3s
            timeout: 10s
            retries: 3
        logging:
            driver: json-file
            options:
                max-size: "30m"
                max-file: "5"
        

networks:
    ${APP_NAME}-network:
        name: ${APP_NAME}-network
        driver: bridge
        external: false

volumes:
    ${APP_NAME}-db-data:
        driver: local
        external: false
        name: ${APP_NAME}-db-data
    ${APP_NAME}-redis-data:
      driver: local
      external: false
      name: ${APP_NAME}-redis-data
EOL
    colorized_echo green "Docker Compose file saved in $COMPOSE_FILE"
}

uninstall_remnawave_script() {
    if [ -f "/usr/local/bin/$APP_NAME" ]; then
        colorized_echo yellow "Removing remnawave script"
        rm "/usr/local/bin/$APP_NAME"
    fi
}

uninstall_remnawave() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_remnawave_docker_images() {
    images=$(docker images | grep remnawave | awk '{print $3}')
    if [ -n "$images" ]; then
        colorized_echo yellow "Removing Docker images of remnawave"
        for image in $images; do
            if docker rmi "$image" >/dev/null 2>&1; then
                colorized_echo yellow "Image $image removed"
            fi
        done
    fi
}

uninstall_remnawave_volumes() {
    volumes=$(docker volume ls | grep "${APP_NAME}" | awk '{print $2}')
    if [ -n "$volumes" ]; then
        colorized_echo yellow "Removing Docker volumes of remnawave"
        for volume in $volumes; do
            if docker volume rm "$volume" >/dev/null 2>&1; then
                colorized_echo yellow "Volume $volume removed"
            fi
        done
    fi
}

up_remnawave() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" up -d --remove-orphans
}

down_remnawave() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" down
}

show_remnawave_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs
}

follow_remnawave_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

update_remnawave_script() {
    colorized_echo blue "Updating remnawave script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/$APP_NAME
    colorized_echo green "Remnawave script updated successfully"
}

update_remnawave() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull
}

backup_command() {
    check_running_as_root
    detect_compose  
    
    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        exit 1
    fi

    local compress=false
    local include_configs=false
    
    # Парсинг аргументов
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --compress|-c) compress=true ;;
            --include-configs) include_configs=true ;;
            -h|--help) 
                echo -e "\033[1;37m💾 Remnawave Database Backup\033[0m"
                echo
                echo -e "\033[1;37mUsage:\033[0m"
                echo -e "  \033[38;5;15m$APP_NAME backup\033[0m [\033[38;5;244moptions\033[0m]"
                echo
                echo -e "\033[1;37mOptions:\033[0m"
                echo -e "  \033[38;5;244m--compress, -c\033[0m      Compress backup file with gzip"
                echo -e "  \033[38;5;244m--include-configs\033[0m   Include configuration files"
                echo -e "  \033[38;5;244m--help, -h\033[0m          Show this help"
                echo
                echo -e "\033[1;37mExample:\033[0m"
                echo -e "  \033[38;5;15m$APP_NAME backup --compress --include-configs\033[0m"
                echo
                echo -e "\033[38;5;8mBackup includes full database (schema + data)\033[0m"
                echo -e "\033[38;5;8mWith --include-configs: also includes all config files\033[0m"
                exit 0
                ;;
            *) 
                echo "Unknown option: $1" >&2
                echo "Use '$APP_NAME backup --help' for usage information."
                exit 1
                ;;
        esac
        shift
    done
    
    if [ ! -f "$ENV_FILE" ]; then
        colorized_echo red ".env file not found!"
        exit 1
    fi

    # Проверяем, что база данных запущена
    if ! is_remnawave_up; then
        colorized_echo red "Remnawave services are not running!"
        echo -e "\033[38;5;8m   Run '\033[38;5;15msudo $APP_NAME up\033[38;5;8m' first\033[0m"
        exit 1
    fi

    # Проверяем, что контейнер базы данных доступен
    local db_container="${APP_NAME}-db"
    if ! docker ps --format "{{.Names}}" | grep -q "^${db_container}$"; then
        colorized_echo red "Database container '$db_container' not found or not running!"
        exit 1
    fi

    # Получаем данные подключения к БД
    local POSTGRES_USER=$(grep "^POSTGRES_USER=" "$ENV_FILE" | cut -d '=' -f2)
    local POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "$ENV_FILE" | cut -d '=' -f2)
    local POSTGRES_DB=$(grep "^POSTGRES_DB=" "$ENV_FILE" | cut -d '=' -f2)

    # Устанавливаем значения по умолчанию
    POSTGRES_USER=${POSTGRES_USER:-postgres}
    POSTGRES_DB=${POSTGRES_DB:-postgres}

    if [ -z "$POSTGRES_PASSWORD" ]; then
        colorized_echo red "POSTGRES_PASSWORD not found in .env file!"
        exit 1
    fi

    # Создаем директорию для бэкапов
    local BACKUP_DIR="$APP_DIR/backups"
    mkdir -p "$BACKUP_DIR"

    # Генерируем имя файла
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name=""
    local backup_path=""
    
    if [ "$include_configs" = true ]; then
        # Полный бэкап с конфигами
        backup_name="remnawave_full_${timestamp}"
        local backup_dir="$BACKUP_DIR/$backup_name"
        mkdir -p "$backup_dir"
        
        echo -e "\033[1;37m💾 Creating full system backup...\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        
        # Создаем дамп базы данных
        echo -e "\033[38;5;250m📝 Step 1:\033[0m Exporting database..."
        if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$db_container" \
            pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F p --verbose > "$backup_dir/database.sql" 2>/dev/null; then
            local db_size=$(du -sh "$backup_dir/database.sql" | cut -f1)
            echo -e "\033[1;32m✅ Database exported successfully ($db_size)\033[0m"
        else
            echo -e "\033[1;31m❌ Database export failed!\033[0m"
            rm -rf "$backup_dir"
            exit 1
        fi
        
        # Универсальное копирование конфигурационных файлов
        echo -e "\033[38;5;250m📝 Step 2:\033[0m Including configuration files..."
        mkdir -p "$backup_dir/configs"
        
        local config_count=0
        
        # Копируем основные конфигурационные файлы
        echo -e "\033[38;5;244m   Copying main configuration files...\033[0m"
        for config_file in "$ENV_FILE" "$SUB_ENV_FILE" "$COMPOSE_FILE"; do
            if [ -f "$config_file" ]; then
                local filename=$(basename "$config_file")
                cp "$config_file" "$backup_dir/configs/"
                config_count=$((config_count + 1))
                echo -e "\033[38;5;244m   ✓ $filename\033[0m"
            fi
        done
        
        # Копируем дополнительные конфигурационные файлы по расширениям
        echo -e "\033[38;5;244m   Scanning for additional config files...\033[0m"
        local extensions=("json" "yml" "yaml" "toml" "ini" "conf" "config" "cfg")
        
        for ext in "${extensions[@]}"; do
            for config_file in "$APP_DIR"/*."$ext"; do
                if [ -f "$config_file" ]; then
                    local filename=$(basename "$config_file")
                    # Исключаем файлы, которые могут быть временными или логами
                    if [[ ! "$filename" =~ ^(temp|tmp|cache|log|debug) ]]; then
                        cp "$config_file" "$backup_dir/configs/"
                        config_count=$((config_count + 1))
                        echo -e "\033[38;5;244m   ✓ $filename\033[0m"
                    fi
                fi
            done
        done
        
        # Копируем важные директории с конфигурациями
        echo -e "\033[38;5;244m   Checking for configuration directories...\033[0m"
        local config_dirs=("certs" "certificates" "ssl" "configs" "config" "custom" "themes" "plugins")
        
        for dir_name in "${config_dirs[@]}"; do
            local config_dir="$APP_DIR/$dir_name"
            if [ -d "$config_dir" ] && [ "$(ls -A "$config_dir" 2>/dev/null)" ]; then
                cp -r "$config_dir" "$backup_dir/configs/"
                local dir_files=$(find "$config_dir" -type f | wc -l)
                config_count=$((config_count + dir_files))
                echo -e "\033[38;5;244m   ✓ $dir_name/ ($dir_files files)\033[0m"
            fi
        done
        
        # Создаем метаданные
        echo -e "\033[38;5;250m📝 Step 3:\033[0m Creating backup metadata..."
        cat > "$backup_dir/metadata.json" << EOF
{
    "backup_type": "full",
    "timestamp": "$timestamp",
    "app_name": "$APP_NAME",
    "script_version": "$SCRIPT_VERSION",
    "database_included": true,
    "configs_included": true,
    "config_files_count": $config_count,
    "hostname": "$(hostname)",
    "backup_size": "calculated_after_compression"
}
EOF
        
        # Создаем информационный файл
        cat > "$backup_dir/backup_info.txt" << EOF
Remnawave Panel Backup Information
==================================

Backup Date: $(date)
Backup Type: Full System Backup
Script Version: $SCRIPT_VERSION
Hostname: $(hostname)

Included Components:
✓ PostgreSQL Database (complete dump)
✓ Environment Files (.env, .env.subscription)
✓ Docker Compose Configuration
✓ Additional Config Files ($config_count files)
✓ Configuration Directories
✓ SSL Certificates (if present)

Restoration:
1. Install Remnawave Panel on target system
2. Stop services: sudo $APP_NAME down
3. Extract this backup
4. Restore database: cat database.sql | docker exec -i DB_CONTAINER psql -U postgres -d postgres
5. Copy configs to appropriate locations
6. Start services: sudo $APP_NAME up

Generated by Remnawave Management CLI v$SCRIPT_VERSION
EOF
        
        echo -e "\033[1;32m✅ Configuration files included ($config_count items)\033[0m"
        
        # Компрессия если требуется
        if [ "$compress" = true ]; then
            echo -e "\033[38;5;250m📝 Step 4:\033[0m Compressing backup..."
            cd "$BACKUP_DIR"
            if tar -czf "${backup_name}.tar.gz" -C . "$(basename "$backup_dir")" 2>/dev/null; then
                local compressed_size=$(du -sh "${backup_name}.tar.gz" | cut -f1)
                echo -e "\033[1;32m✅ Backup compressed successfully ($compressed_size)\033[0m"
                backup_path="$BACKUP_DIR/${backup_name}.tar.gz"
                
                # Удаляем некомпрессированную версию
                rm -rf "$backup_dir"
            else
                echo -e "\033[1;31m❌ Compression failed, keeping uncompressed backup\033[0m"
                backup_path="$backup_dir"
            fi
        else
            backup_path="$backup_dir"
        fi
        
    else
        # Простой бэкап только базы данных
        if [ "$compress" = true ]; then
            backup_name="remnawave_db_${timestamp}.sql.gz"
            backup_path="$BACKUP_DIR/$backup_name"
        else
            backup_name="remnawave_db_${timestamp}.sql"
            backup_path="$BACKUP_DIR/$backup_name"
        fi
        
        echo -e "\033[1;37m💾 Creating database backup...\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        echo -e "\033[38;5;250mDatabase: $POSTGRES_DB\033[0m"
        echo -e "\033[38;5;250mContainer: $db_container\033[0m"
        echo -e "\033[38;5;250mBackup file: $backup_name\033[0m"
        echo

        # Создаем бэкап
        if [ "$compress" = true ]; then
            if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$db_container" \
                pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F p --verbose 2>/dev/null | \
                gzip > "$backup_path"; then
                local backup_size=$(du -sh "$backup_path" | cut -f1)
                echo -e "\033[1;32m✅ Compressed database backup created successfully ($backup_size)!\033[0m"
            else
                echo -e "\033[1;31m❌ Database backup failed!\033[0m"
                rm -f "$backup_path"
                exit 1
            fi
        else
            if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$db_container" \
                pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F p --verbose > "$backup_path" 2>/dev/null; then
                local backup_size=$(du -sh "$backup_path" | cut -f1)
                echo -e "\033[1;32m✅ Database backup created successfully ($backup_size)!\033[0m"
            else
                echo -e "\033[1;31m❌ Database backup failed!\033[0m"
                rm -f "$backup_path"
                exit 1
            fi
        fi
    fi

    # Показываем итоговую информацию
    echo
    echo -e "\033[1;37m📋 Backup Information:\033[0m"
    printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Location:" "$backup_path"
    
    if [ -f "$backup_path" ]; then
        local file_size=$(du -sh "$backup_path" | cut -f1)
        printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Size:" "$file_size"
    elif [ -d "$backup_path" ]; then
        local dir_size=$(du -sh "$backup_path" | cut -f1)
        printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Size:" "$dir_size"
    fi
    
    if [ "$include_configs" = true ]; then
        printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Type:" "Full backup (database + configs)"
    else
        printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Type:" "Database only"
    fi
    
    if [ "$compress" = true ]; then
        printf "   \033[38;5;15m%-12s\033[0m \033[38;5;250m%s\033[0m\n" "Compression:" "gzip"
    fi
    echo
    
    # Показываем как восстановить
    echo -e "\033[1;37m🔄 To restore this backup:\033[0m"
    if [ "$include_configs" = true ]; then
        if [ "$compress" = true ]; then
            echo -e "\033[38;5;244m1. tar -xzf \"$backup_path\"\033[0m"
            echo -e "\033[38;5;244m2. Copy configs to appropriate locations\033[0m"
            echo -e "\033[38;5;244m3. cat database.sql | docker exec -i DB_CONTAINER psql -U postgres -d postgres\033[0m"
        else
            echo -e "\033[38;5;244m1. Copy configs from backup directory\033[0m"
            echo -e "\033[38;5;244m2. cat \"$backup_path/database.sql\" | docker exec -i DB_CONTAINER psql -U postgres -d postgres\033[0m"
        fi
    else
        if [ "$compress" = true ]; then
            echo -e "\033[38;5;244mzcat \"$backup_path\" | docker exec -i -e PGPASSWORD=\"\$POSTGRES_PASSWORD\" \"$db_container\" psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\"\033[0m"
        else
            echo -e "\033[38;5;244mcat \"$backup_path\" | docker exec -i -e PGPASSWORD=\"\$POSTGRES_PASSWORD\" \"$db_container\" psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\"\033[0m"
        fi
    fi
    echo
    
    # Автоматическая очистка старых бэкапов (оставляем последние 10)
    local old_backups=$(ls -t "$BACKUP_DIR"/remnawave_*_*.{sql*,tar.gz} 2>/dev/null | tail -n +11)
    if [ -n "$old_backups" ]; then
        echo "$old_backups" | xargs rm -rf
        local removed_count=$(echo "$old_backups" | wc -l)
        echo -e "\033[38;5;8m🧹 Cleaned up $removed_count old backup(s) (keeping last 10)\033[0m"
    fi
}



monitor_command() {
    check_running_as_root
    
    if ! is_remnawave_installed; then
        echo -e "\033[1;31m❌ Remnawave not installed!\033[0m"
        return 1
    fi
    
    if ! is_remnawave_up; then
        echo -e "\033[1;31m❌ Remnawave services are not running!\033[0m"
        echo -e "\033[38;5;8m   Use 'sudo $APP_NAME up' to start services\033[0m"
        return 1
    fi
    
    # Однократный вывод статистики
    echo -e "\033[1;37m📊 Remnawave Performance Monitor - $(date '+%Y-%m-%d %H:%M:%S')\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 70))\033[0m"
    echo
    
    # Показываем статистику контейнеров
    echo -e "\033[1;37m🐳 Container Statistics:\033[0m"
    local stats_available=false
    
    # Проверяем доступность docker stats
    if docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null | grep -q "${APP_NAME}"; then
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" | grep -E "(NAME|${APP_NAME})"
        stats_available=true
    else
        echo -e "\033[38;5;244m   Docker stats not available or no containers running\033[0m"
    fi
    
    echo
    
    # Показываем системные ресурсы
    echo -e "\033[1;37m💻 System Resources:\033[0m"
    
    # CPU
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "N/A")
    echo -e "   \033[38;5;15mCPU:\033[0m $cpu_usage% usage"
    
    # Memory
    local mem_info=$(free -h | grep "Mem:" 2>/dev/null)
    if [ -n "$mem_info" ]; then
        local mem_used=$(echo "$mem_info" | awk '{print $3}')
        local mem_total=$(echo "$mem_info" | awk '{print $2}')
        local mem_percent=$(free | grep Mem | awk '{printf("%.1f", $3/$2 * 100.0)}')
        echo -e "   \033[38;5;15mMemory:\033[0m $mem_percent% usage ($mem_used used / $mem_total total)"
    else
        echo -e "   \033[38;5;15mMemory:\033[0m N/A"
    fi
    
    # Disk
    local disk_info=$(df -h "$APP_DIR" 2>/dev/null | tail -1)
    if [ -n "$disk_info" ]; then
        local disk_used=$(echo "$disk_info" | awk '{print $3}')
        local disk_total=$(echo "$disk_info" | awk '{print $2}')
        local disk_percent=$(echo "$disk_info" | awk '{print $5}' | sed 's/%//')
        echo -e "   \033[38;5;15mDisk:\033[0m $disk_used used / $disk_total total ($disk_percent%)"
    else
        echo -e "   \033[38;5;15mDisk:\033[0m N/A"
    fi
    
    echo
    
    # Дополнительная информация о контейнерах
    if [ "$stats_available" = true ]; then
        echo -e "\033[1;37m📋 Container Details:\033[0m"
        detect_compose
        cd "$APP_DIR" 2>/dev/null || true
        
        local container_info=$($COMPOSE -f "$COMPOSE_FILE" ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)
        if [ -n "$container_info" ]; then
            echo "$container_info" | tail -n +2 | while IFS=$'\t' read -r service status ports; do
                local status_icon="❓"
                local status_color="38;5;244"
                
                if [[ "$status" =~ "Up" ]]; then
                    if [[ "$status" =~ "healthy" ]]; then
                        status_icon="✅"
                        status_color="1;32"
                    elif [[ "$status" =~ "unhealthy" ]]; then
                        status_icon="❌"
                        status_color="1;31"
                    else
                        status_icon="🟡"
                        status_color="1;33"
                    fi
                elif [[ "$status" =~ "Exit" ]]; then
                    status_icon="❌"
                    status_color="1;31"
                fi
                
                printf "   \033[38;5;15m%-20s\033[0m \033[${status_color}m${status_icon} %-25s\033[0m \033[38;5;244m%s\033[0m\n" "$service:" "$status" "$ports"
            done
        fi
    fi
    
    echo
    echo -e "\033[38;5;8m📊 Snapshot taken at $(date '+%H:%M:%S')\033[0m"
    echo -e "\033[38;5;8m💡 For continuous monitoring, use: docker stats\033[0m"

        if [[ "${BASH_SOURCE[1]}" =~ "main_menu" ]] || [[ "$0" =~ "$APP_NAME" ]] && [[ "$1" != "--no-pause" ]]; then
        echo
        read -p "Press Enter to continue..."
    fi
}

is_remnawave_installed() {
    if [ -d "$APP_DIR" ]; then
        return 0
    else
        return 1
    fi
}

is_remnawave_up() {
    detect_compose
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
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

warn_already_installed() {
    colorized_echo red "⚠️ Remnawave is already installed at: \e[1m$APP_DIR\e[0m"
    colorized_echo yellow "To install another instance, use the \e[1m--name <custom_name>\e[0m flag."
    colorized_echo cyan "Example: remnawave install --name mypanel"
}


install_command() {
    check_running_as_root
    if is_remnawave_installed; then
        warn_already_installed
        read -r -p "Do you want to override the previous installation? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi
    detect_os
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        install_package openssl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi

    detect_compose
    install_remnawave_script
    install_remnawave
    up_remnawave

    follow_remnawave_logs

    colorized_echo green "==================================================="
    colorized_echo green "Remnawave Panel has been installed successfully!"
    colorized_echo green "Panel URL (local access only): http://127.0.0.1:$APP_PORT"
    colorized_echo green "Subscription Page URL (local access only): http://127.0.0.1:$SUB_PAGE_PORT"
    colorized_echo green "==================================================="
    colorized_echo yellow "IMPORTANT: These URLs are only accessible from the server itself."
    colorized_echo yellow "You must set up a reverse proxy to make them accessible from the internet."
    colorized_echo yellow "Configure your reverse proxy to point to:"
    colorized_echo yellow "Panel domain: $FRONT_END_DOMAIN -> 127.0.0.1:$APP_PORT"
    colorized_echo yellow "Subscription domain: $SUB_DOMAIN -> 127.0.0.1:$SUB_PAGE_PORT"
    colorized_echo green "==================================================="
}

uninstall_command() {
    check_running_as_root
    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        exit 1
    fi

    read -p "Do you really want to uninstall Remnawave? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi

    detect_compose
    if is_remnawave_up; then
        down_remnawave
    fi
    uninstall_remnawave_script
    uninstall_remnawave
    uninstall_remnawave_docker_images

    read -p "Do you want to remove Remnawave data volumes too? This will DELETE ALL DATABASE DATA! (y/n) "
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        uninstall_remnawave_volumes
    fi

    colorized_echo green "Remnawave uninstalled successfully"
}

up_command() {
    help() {
        colorized_echo red "Usage: remnawave up [options]"
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }

    local no_logs=false
    
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs) no_logs=true ;;
            -h|--help) 
                echo -e "\033[1;37m▶️  up\033[0m - Start all Remnawave services"
                echo
                echo -e "\033[1;37mUsage:\033[0m"
                echo -e "  \033[38;5;15m$APP_NAME\033[0m \033[38;5;250mup\033[0m [\033[38;5;244m--no-logs\033[0m]"
                echo
                echo -e "\033[1;37mOptions:\033[0m"
                echo -e "  \033[38;5;244m-n, --no-logs\033[0m   Start without following logs"
                echo
                exit 0
                ;;
            *) 
                echo "Error: Invalid option: $1" >&2
                echo "Use '$APP_NAME up --help' for usage information."
                exit 1
                ;;
        esac
        shift
    done
    

    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        exit 1
    fi

    detect_compose

    if is_remnawave_up; then
        colorized_echo red "Remnawave already up"
        exit 1
    fi

    up_remnawave
    if [ "$no_logs" = false ]; then
        follow_remnawave_logs
    fi
}

down_command() {
    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        exit 1
    fi

    detect_compose

    if ! is_remnawave_up; then
        colorized_echo red "Remnawave already down"
        exit 1
    fi

    down_remnawave
}

restart_command() {
    help() {
        colorized_echo red "Usage: remnawave restart [options]"
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

    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        exit 1
    fi

    detect_compose

    down_remnawave
    up_remnawave

    if [ "$no_logs" = false ]; then
        follow_remnawave_logs
    fi
}

health_check_command() {
    echo -e "\033[1;37m🏥 Remnawave System Health Check\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    echo
    
    local issues=0
    
    # Проверка установки
    if ! is_remnawave_installed; then
        echo -e "\033[1;31m❌ Panel not installed\033[0m"
        return 1
    fi
    
    # Проверка Docker
    if ! command -v docker >/dev/null; then
        echo -e "\033[1;31m❌ Docker not installed\033[0m"
        issues=$((issues + 1))
    else
        echo -e "\033[1;32m✅ Docker installed\033[0m"
        
        # Проверка статуса Docker daemon
        if ! docker info >/dev/null 2>&1; then
            echo -e "\033[1;31m❌ Docker daemon not running\033[0m"
            issues=$((issues + 1))
        else
            echo -e "\033[1;32m✅ Docker daemon running\033[0m"
        fi
    fi
    
    # Проверка Docker Compose
    detect_compose
    if [ -z "$COMPOSE" ]; then
        echo -e "\033[1;31m❌ Docker Compose not found\033[0m"
        issues=$((issues + 1))
    else
        echo -e "\033[1;32m✅ Docker Compose available ($COMPOSE)\033[0m"
    fi
    
    # Проверка конфигурационных файлов
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "\033[1;31m❌ Environment file missing: $ENV_FILE\033[0m"
        issues=$((issues + 1))
    else
        echo -e "\033[1;32m✅ Environment file exists\033[0m"
        
        # Проверка обязательных переменных
        local required_vars=("APP_PORT" "JWT_AUTH_SECRET" "JWT_API_TOKENS_SECRET" "POSTGRES_USER" "POSTGRES_PASSWORD" "POSTGRES_DB")
        for var in "${required_vars[@]}"; do
            if ! grep -q "^${var}=" "$ENV_FILE"; then
                echo -e "\033[1;31m❌ Missing required variable: $var\033[0m"
                issues=$((issues + 1))
            fi
        done
    fi
    
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "\033[1;31m❌ Docker Compose file missing: $COMPOSE_FILE\033[0m"
        issues=$((issues + 1))
    else
        echo -e "\033[1;32m✅ Docker Compose file exists\033[0m"
        
        # Проверка валидности compose файла
        if validate_compose_file "$COMPOSE_FILE"; then
            echo -e "\033[1;32m✅ Docker Compose file valid\033[0m"
        else
            echo -e "\033[1;31m❌ Docker Compose file invalid\033[0m"
            issues=$((issues + 1))
        fi
    fi
    
    # Проверка портов
    if [ -f "$ENV_FILE" ]; then
        echo -e "\033[1;37m🔌 Port Status Check:\033[0m"
        
        local app_port=$(grep "^APP_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        local metrics_port=$(grep "^METRICS_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        
        if [ -f "$SUB_ENV_FILE" ]; then
            local sub_port=$(grep "^APP_PORT=" "$SUB_ENV_FILE" | cut -d'=' -f2)
        fi
        
        # Проверяем каждый порт отдельно
        for port in $app_port $metrics_port $sub_port; do
            if [ -n "$port" ]; then
                local port_info=""
                local status_color="1;32"
                local status_icon="✅"
                
                # Получаем информацию о процессе, использующем порт
                if command -v ss >/dev/null 2>&1; then
                    port_info=$(ss -tlnp 2>/dev/null | grep ":$port " | head -1)
                elif command -v netstat >/dev/null 2>&1; then
                    port_info=$(netstat -tlnp 2>/dev/null | grep ":$port " | head -1)
                fi
                
                if [ -n "$port_info" ]; then
                    # Извлекаем имя процесса
                    local process_name=""
                    if echo "$port_info" | grep -q "docker-proxy"; then
                        process_name="docker-proxy"
                    elif echo "$port_info" | grep -q "nginx"; then
                        process_name="nginx"
                    elif echo "$port_info" | grep -q "apache"; then
                        process_name="apache"
                    else
                        # Попытка извлечь имя процесса из вывода
                        process_name=$(echo "$port_info" | grep -o 'users:(([^)]*))' | sed 's/users:((\([^)]*\)).*/\1/' | cut -d',' -f1 | tr -d '"' | head -1)
                        if [ -z "$process_name" ]; then
                            process_name="unknown process"
                        fi
                    fi
                    
                    # Определяем, это наш порт или чужой
                    if echo "$process_name" | grep -q "docker"; then
                        status_color="1;32"
                        status_icon="✅"
                        printf "   \033[38;5;15mPort %s:\033[0m \033[${status_color}m${status_icon} Used by Remnawave (docker)\033[0m\n" "$port"
                    else
                        status_color="1;33"
                        status_icon="⚠️ "
                        printf "   \033[38;5;15mPort %s:\033[0m \033[${status_color}m${status_icon} Occupied by %s\033[0m\n" "$port" "$process_name"
                        issues=$((issues + 1))
                    fi
                else
                    printf "   \033[38;5;15mPort %s:\033[0m \033[1;32m✅ Available\033[0m\n" "$port"
                fi
            fi
        done
    fi
    
    # Проверка дискового пространства
    local available_space=$(df "$APP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$available_space" -lt 1048576 ]; then  # 1GB в KB
        echo -e "\033[1;33m⚠️  Low disk space: $(( available_space / 1024 ))MB available\033[0m"
        issues=$((issues + 1))
    else
        echo -e "\033[1;32m✅ Sufficient disk space: $(( available_space / 1024 ))MB available\033[0m"
    fi
    
    # Проверка RAM
    local available_ram=$(free -m | awk 'NR==2{print $7}')
    if [ "$available_ram" -lt 256 ]; then
        echo -e "\033[1;33m⚠️  Low available RAM: ${available_ram}MB\033[0m"
    else
        echo -e "\033[1;32m✅ Sufficient RAM: ${available_ram}MB available\033[0m"
    fi
    
    # Проверка состояния сервисов (если установлены)
    if is_remnawave_up; then
        echo -e "\033[1;37m🐳 Services Status:\033[0m"
        detect_compose
        cd "$APP_DIR" 2>/dev/null || true
        
        # Получаем статус каждого сервиса
        local services_status=$($COMPOSE -f "$COMPOSE_FILE" ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null || echo "")
        
        if [ -n "$services_status" ]; then
            echo "$services_status" | tail -n +2 | while IFS=$'\t' read -r service status; do
                local status_icon="❓"
                local status_color="38;5;244"
                
                if [[ "$status" =~ "Up" ]]; then
                    if [[ "$status" =~ "healthy" ]]; then
                        status_icon="✅"
                        status_color="1;32"
                    elif [[ "$status" =~ "unhealthy" ]]; then
                        status_icon="❌"
                        status_color="1;31"
                    else
                        status_icon="🟡"
                        status_color="1;33"
                    fi
                elif [[ "$status" =~ "Exit" ]]; then
                    status_icon="❌"
                    status_color="1;31"
                elif [[ "$status" =~ "Restarting" ]]; then
                    status_icon="🔄"
                    status_color="1;33"
                fi
                
                printf "   \033[38;5;15m%-20s\033[0m \033[${status_color}m${status_icon} ${status}\033[0m\n" "$service:"
            done
        fi
    fi
    
    echo
    if [ $issues -eq 0 ]; then
        echo -e "\033[1;32m🎉 System health: EXCELLENT\033[0m"
        return 0
    else
        echo -e "\033[1;33m⚠️  Found $issues issue(s) that may affect performance\033[0m"
        
        # Предлагаем решения для типичных проблем
        echo
        echo -e "\033[1;37m💡 Recommendations:\033[0m"
        if [ $issues -gt 0 ]; then
            echo -e "\033[38;5;244m   • Check port conflicts and reconfigure if needed\033[0m"
            echo -e "\033[38;5;244m   • Review logs with '\033[38;5;15msudo $APP_NAME logs\033[38;5;244m'\033[0m"
            echo -e "\033[38;5;244m   • Restart services with '\033[38;5;15msudo $APP_NAME restart\033[38;5;244m'\033[0m"
        fi
        
        return 1
    fi
}



validate_compose_file() {
    local compose_file="$1"
    
    if [ ! -f "$compose_file" ]; then
        return 1
    fi
    
    local current_dir=$(pwd)
    cd "$(dirname "$compose_file")"
    
    if command -v docker >/dev/null 2>&1; then
        detect_compose
        
        if $COMPOSE config >/dev/null 2>&1; then
            cd "$current_dir"
            return 0
        else
            cd "$current_dir"
            return 1
        fi
    fi
    
    cd "$current_dir"
    return 0
}

status_command() {
    check_running_as_root
    detect_compose
    
    echo -e "\033[1;37m📊 Remnawave Panel Status Check:\033[0m"
    echo
    
    # Проверяем статус панели
    if is_remnawave_installed; then
        if is_remnawave_up; then
            printf "   \033[38;5;15m%-12s\033[0m \033[1;32m✅ Running\033[0m\n" "Status:"
        else
            printf "   \033[38;5;15m%-12s\033[0m \033[1;31m❌ Stopped\033[0m\n" "Status:"
        fi
    else
        printf "   \033[38;5;15m%-12s\033[0m \033[1;33m⚠️  Not Installed\033[0m\n" "Status:"
        return 1
    fi
    
    echo
    
    # Показываем статус сервисов
    echo -e "\033[1;37m🔧 Services Status:\033[0m"
    cd "$APP_DIR" 2>/dev/null || true
    
    local services_status=$($COMPOSE -f "$COMPOSE_FILE" ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "")
    
    if [ -n "$services_status" ]; then
        echo "$services_status" | tail -n +2 | while IFS=$'\t' read -r service status ports; do
            local status_icon="❓"
            local status_color="38;5;244"
            
            if [[ "$status" =~ "Up" ]]; then
                if [[ "$status" =~ "healthy" ]]; then
                    status_icon="✅"
                    status_color="1;32"
                elif [[ "$status" =~ "unhealthy" ]]; then
                    status_icon="❌"
                    status_color="1;31"
                else
                    status_icon="🟡"
                    status_color="1;33"
                fi
            elif [[ "$status" =~ "Exit" ]]; then
                status_icon="❌"
                status_color="1;31"
            elif [[ "$status" =~ "Restarting" ]]; then
                status_icon="🔄"
                status_color="1;33"
            fi
            
            printf "   \033[38;5;15m%-25s\033[0m \033[${status_color}m${status_icon} %-25s\033[0m \033[38;5;244m%s\033[0m\n" "$service" "$status" "$ports"
        done
    else
        echo -e "\033[38;5;244m   No services found\033[0m"
    fi
    
    echo
    
    # Показываем использование ресурсов основного контейнера
    echo -e "\033[1;37m💾 Resource Usage:\033[0m"
    local main_stats=$(docker stats --no-stream --format "{{.CPUPerc}}\t{{.MemUsage}}" "${APP_NAME}" 2>/dev/null || echo "N/A\tN/A")
    local cpu_perc=$(echo "$main_stats" | cut -f1)
    local mem_usage=$(echo "$main_stats" | cut -f2)
    
    if [ "$cpu_perc" != "N/A" ]; then
        printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250mCPU: %-10s %s\033[0m\n" "Main Panel:" "$cpu_perc" "$mem_usage"
    else
        printf "   \033[38;5;15m%-15s\033[0m \033[38;5;244mStats not available\033[0m\n" "Main Panel:"
    fi
    
    echo
    
    # Показываем информацию о подключении
    if [ -f "$ENV_FILE" ]; then
        echo -e "\033[1;37m🌐 Connection Information:\033[0m"
        
        local app_port=$(grep "^APP_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        local metrics_port=$(grep "^METRICS_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        local panel_domain=$(grep "^FRONT_END_DOMAIN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs 2>/dev/null)
        local sub_domain=$(grep "^SUB_PUBLIC_DOMAIN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs 2>/dev/null)
        
        # Subscription port
        local sub_port=""
        if [ -f "$SUB_ENV_FILE" ]; then
            sub_port=$(grep "^APP_PORT=" "$SUB_ENV_FILE" | cut -d'=' -f2)
        fi
        
        # IP адрес
        local server_ip="${NODE_IP:-127.0.0.1}"
        
        # URL подключения
        if [ -n "$app_port" ]; then
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s:%s\033[0m\n" "Panel URL:" "$server_ip" "$app_port"
        fi
        
        if [ -n "$sub_port" ]; then
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s:%s\033[0m\n" "Sub Page URL:" "$server_ip" "$sub_port"
        fi
        
        if [ -n "$metrics_port" ]; then
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s:%s/api/metrics\033[0m\n" "Metrics URL:" "$server_ip" "$metrics_port"
        fi
        
        # Домены
        if [ -n "$panel_domain" ] && [ "$panel_domain" != "null" ]; then
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Panel Domain:" "$panel_domain"
        fi
        
        if [ -n "$sub_domain" ] && [ "$sub_domain" != "null" ]; then
            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Sub Domain:" "$sub_domain"
        fi
    fi
    
    echo
    
    # Итоговое сообщение
    if is_remnawave_up; then
        # Проверяем здоровье всех сервисов
        local unhealthy_count=$(docker ps --format "{{.Names}}\t{{.Status}}" | grep "$APP_NAME" | grep -c "unhealthy" || echo "0")
        
        if [ "$unhealthy_count" -eq 0 ]; then
            echo -e "\033[1;32m🎉 All services are healthy and running!\033[0m"
        else
            echo -e "\033[1;33m⚠️  Some services may have health issues ($unhealthy_count unhealthy)\033[0m"
        fi
    else
        echo -e "\033[1;31m❌ Services are not running\033[0m"
        echo -e "\033[38;5;8m   Use 'sudo $APP_NAME up' to start services\033[0m"
    fi
    
    # Добавляем паузу только если запущено из меню (проверяем переменную окружения или родительский процесс)
    if [[ "${BASH_SOURCE[1]}" =~ "main_menu" ]] || [[ "$0" =~ "$APP_NAME" ]] && [[ "$1" != "--no-pause" ]]; then
        echo
        read -p "Press Enter to continue..."
    fi
}

# Замените logs_command на:
logs_command() {
    check_running_as_root
    detect_compose
    
    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        return 1
    fi

    if ! is_remnawave_up; then
        colorized_echo red "Remnawave services are not running!"
        colorized_echo yellow "   Run 'sudo $APP_NAME up' first"
        return 1
    fi

    logs_menu
}

# Добавьте новую функцию logs_menu:
logs_menu() {
    while true; do
        clear
        echo -e "\033[1;37m📋 Application Logs\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
        echo
        
        echo -e "\033[1;37m📊 Log Options:\033[0m"
        echo -e "   \033[38;5;15m1)\033[0m 📱 Follow all logs (real-time)"
        echo -e "   \033[38;5;15m2)\033[0m 📄 Show last 100 lines"
        echo -e "   \033[38;5;15m3)\033[0m 🔍 Show specific service logs"
        echo -e "   \033[38;5;15m4)\033[0m ❌ Show error logs only"
        echo -e "   \033[38;5;244m0)\033[0m ⬅️  Back"
        echo
        
        read -p "Select option [0-4]: " choice
        
        case "$choice" in
            1) show_live_logs ;;
            2) show_recent_logs ;;
            3) show_service_logs ;;
            4) show_error_logs ;;
            0) return 0 ;;
            *) 
                echo -e "\033[1;31mInvalid option!\033[0m"
                sleep 1
                ;;
        esac
    done
}

# Функции для просмотра логов:
show_live_logs() {
    clear
    echo -e "\033[1;37m📱 Live Logs (Press Ctrl+C to exit)\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    echo
    
    cd "$APP_DIR"
    $COMPOSE -f "$COMPOSE_FILE" logs -f --tail=50
    
    echo
    read -p "Press Enter to return to logs menu..."
}

show_recent_logs() {
    clear
    echo -e "\033[1;37m📄 Last 100 Log Lines\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    echo
    
    cd "$APP_DIR"
    $COMPOSE -f "$COMPOSE_FILE" logs --tail=100
    
    echo
    read -p "Press Enter to return to logs menu..."
}

show_service_logs() {
    while true; do
        clear
        echo -e "\033[1;37m🔍 Service Logs\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
        echo
        
        echo -e "\033[1;37m📦 Available Services:\033[0m"
        echo -e "   \033[38;5;15m1)\033[0m 🚀 Main Panel (remnawave)"
        echo -e "   \033[38;5;15m2)\033[0m 🗄️  Database (remnawave-db)"
        echo -e "   \033[38;5;15m3)\033[0m 📊 Redis (remnawave-redis)"
        echo -e "   \033[38;5;15m4)\033[0m 📄 Subscription Page"
        echo -e "   \033[38;5;244m0)\033[0m ⬅️  Back"
        echo
        
        read -p "Select service [0-4]: " service_choice
        
        local service_name=""
        case "$service_choice" in
            1) service_name="remnawave" ;;
            2) service_name="remnawave-db" ;;
            3) service_name="remnawave-redis" ;;
            4) service_name="remnawave-subscription-page" ;;
            0) return 0 ;;
            *) 
                echo -e "\033[1;31mInvalid option!\033[0m"
                sleep 1
                continue
                ;;
        esac
        
        clear
        echo -e "\033[1;37m📋 Logs for: $service_name\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        echo
        
        cd "$APP_DIR"
        $COMPOSE -f "$COMPOSE_FILE" logs --tail=100 "$service_name"
        
        echo
        read -p "Press Enter to continue..."
    done
}

show_error_logs() {
    clear
    echo -e "\033[1;37m❌ Error Logs Only\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    echo
    
    cd "$APP_DIR"
    $COMPOSE -f "$COMPOSE_FILE" logs --tail=200 | grep -i "error\|exception\|failed\|fatal" || echo "No errors found in recent logs"
    
    echo
    read -p "Press Enter to return to logs menu..."
}
update_command() {
    check_running_as_root
    if ! is_remnawave_installed; then
        echo -e "\033[1;31m❌ Remnawave not installed!\033[0m"
        echo -e "\033[38;5;8m   Run '\033[38;5;15msudo $APP_NAME install\033[38;5;8m' first\033[0m"
        exit 1
    fi
    
    detect_compose
    
    echo -e "\033[1;37m🔄 Starting Remnawave Update Check...\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    
    # Получаем текущую версию скрипта
    local current_script_version="$SCRIPT_VERSION"
    
    # Получаем последнюю версию скрипта с GitHub
    echo -e "\033[38;5;250m📝 Step 1:\033[0m Checking for script updates..."
    local remote_script_version=$(curl -s "$SCRIPT_URL" 2>/dev/null | grep "^SCRIPT_VERSION=" | cut -d'"' -f2)
    
    if [ -n "$remote_script_version" ] && [ "$remote_script_version" != "$current_script_version" ]; then
        echo -e "\033[1;33m🔄 Script update available: \033[38;5;15mv$current_script_version\033[0m → \033[1;37mv$remote_script_version\033[0m"
        read -p "Do you want to update the script first? (y/n): " -r update_script
        if [[ $update_script =~ ^[Yy]$ ]]; then
            update_remnawave_script
            echo -e "\033[1;32m✅ Script updated to v$remote_script_version\033[0m"
            echo -e "\033[38;5;8m   Please run the update command again to continue\033[0m"
            exit 0
        fi
    else
        echo -e "\033[1;32m✅ Script is up to date (v$current_script_version)\033[0m"
    fi
    
    # Переходим в директорию приложения
    cd "$APP_DIR" 2>/dev/null || { echo -e "\033[1;31m❌ Cannot access app directory\033[0m"; exit 1; }
    
    # Получаем список образов из compose файла
    echo -e "\033[38;5;250m📝 Step 2:\033[0m Checking current images..."
    local compose_images=$($COMPOSE -f "$COMPOSE_FILE" config 2>/dev/null | grep "image:" | awk '{print $2}' | sort | uniq)
    
    if [ -z "$compose_images" ]; then
        echo -e "\033[1;31m❌ Cannot read compose file images\033[0m"
        exit 1
    fi
    
    echo -e "\033[38;5;244mImages to check:\033[0m"
    echo "$compose_images" | while read image; do
        echo -e "\033[38;5;244m   $image\033[0m"
    done
    
    # Выполняем pull и анализируем вывод
    echo -e "\033[38;5;250m📝 Step 3:\033[0m Pulling latest images..."
    
    local pull_output=""
    local pull_exit_code=0
    
    # Захватываем полный вывод pull команды
    pull_output=$($COMPOSE -f "$COMPOSE_FILE" pull 2>&1) || pull_exit_code=$?
    
    if [ $pull_exit_code -ne 0 ]; then
        echo -e "\033[1;31m❌ Failed to pull images:\033[0m"
        echo -e "\033[38;5;244m$pull_output\033[0m"
        exit 1
    fi
    
    # Анализируем вывод pull команды для определения обновлений
    local images_updated=false
    local update_indicators=""
    
    # Ищем индикаторы обновления в выводе
    if echo "$pull_output" | grep -qi "downloading\|downloaded\|pulling fs layer\|extracting\|pull complete"; then
        images_updated=true
        update_indicators="New layers downloaded"
    fi
    
    # Проверяем количество "up to date" сообщений
    local up_to_date_count=$(echo "$pull_output" | grep -ci "image is up to date\|already exists")
    local total_images_count=$(echo "$compose_images" | wc -l)
    
    # Если ВСЕ образы показали "up to date", то обновлений точно нет
    if [ "$up_to_date_count" -ge "$total_images_count" ] && [ "$total_images_count" -gt 0 ]; then
        if ! echo "$pull_output" | grep -qi "downloading\|downloaded\|pulling fs layer\|extracting\|pull complete"; then
            images_updated=false
        fi
    fi
    
    # Дополнительная проверка для надежности
    if echo "$pull_output" | grep -qi "digest.*differs\|newer image\|status.*downloaded"; then
        images_updated=true
        update_indicators="$update_indicators, Newer versions detected"
    fi
    
    # Выводим детальную информацию для диагностики
    echo -e "\033[38;5;244mPull analysis:\033[0m"
    echo -e "\033[38;5;244m   Images checked: $total_images_count\033[0m"
    echo -e "\033[38;5;244m   Up-to-date responses: $up_to_date_count\033[0m"
    
    # Показываем результат
    if [ "$images_updated" = true ]; then
        echo -e "\033[1;32m✅ New image versions available!\033[0m"
        if [ -n "$update_indicators" ]; then
            echo -e "\033[38;5;244m   Indicators: $update_indicators\033[0m"
        fi
        
        # Показываем какие образы были обновлены (из вывода pull)
        local updated_images=$(echo "$pull_output" | grep -i "pulling\|downloaded" | head -3)
        if [ -n "$updated_images" ]; then
            echo -e "\033[38;5;244m   Update activity detected\033[0m"
        fi
    else
        echo -e "\033[1;32m✅ All images are already up to date\033[0m"
        echo
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        echo -e "\033[1;37m🎉 No updates available!\033[0m"
        echo -e "\033[38;5;250m� All components are running the latest versions\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
        exit 0
    fi
    
    # Проверяем, запущен ли контейнер
    local was_running=false
    if is_remnawave_up; then
        was_running=true
        echo -e "\033[38;5;250m📝 Step 4:\033[0m Stopping services for update..."
        if down_remnawave; then
            echo -e "\033[1;32m✅ Services stopped\033[0m"
        else
            echo -e "\033[1;31m❌ Failed to stop services\033[0m"
            exit 1
        fi
    else
        echo -e "\033[38;5;250m📝 Step 4:\033[0m Services already stopped\033[0m"
    fi
    
    # Запускаем сервисы с новыми образами
    if [ "$was_running" = true ]; then
        echo -e "\033[38;5;250m📝 Step 5:\033[0m Starting updated services..."
        if up_remnawave; then
            echo -e "\033[1;32m✅ Services started successfully\033[0m"
            
            # Проверяем здоровье сервисов после запуска
            echo -e "\033[38;5;250m🔍 Waiting for services to become healthy...\033[0m"
            local attempts=0
            local max_attempts=30
            
            while [ $attempts -lt $max_attempts ]; do
                if is_remnawave_up; then
                    echo -e "\033[1;32m✅ All services are healthy\033[0m"
                    break
                fi
                
                sleep 2
                attempts=$((attempts + 1))
                
                if [ $attempts -eq $max_attempts ]; then
                    echo -e "\033[1;33m⚠️  Services started but may still be initializing\033[0m"
                    echo -e "\033[38;5;8m   Check status with '\033[38;5;15msudo $APP_NAME status\033[38;5;8m'\033[0m"
                fi
            done
        else
            echo -e "\033[1;31m❌ Failed to start services\033[0m"
            echo -e "\033[38;5;8m   Check logs with '\033[38;5;15msudo $APP_NAME logs\033[38;5;8m'\033[0m"
            exit 1
        fi
    else
        echo -e "\033[38;5;250m📝 Step 5:\033[0m Services were not running, skipping startup\033[0m"
        echo -e "\033[38;5;8m   Run '\033[38;5;15msudo $APP_NAME up\033[38;5;8m' to start when ready\033[0m"
    fi
    
    echo
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    echo -e "\033[1;37m🎉 Remnawave updated successfully!\033[0m"
    
    # Показываем итоговую информацию
    if [ "$was_running" = true ]; then
        echo -e "\033[38;5;250m💡 Services are running with latest versions\033[0m"
        echo -e "\033[38;5;8m   Check status: '\033[38;5;15msudo $APP_NAME status\033[38;5;8m'\033[0m"
    fi
    
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
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

edit_env_command() {
    detect_os
    check_editor
    if [ -f "$ENV_FILE" ]; then
        $EDITOR "$ENV_FILE"
    else
        colorized_echo red "Environment file not found at $ENV_FILE"
        exit 1
    fi
}

edit_env_sub_command() {
    detect_os
    check_editor
    if [ -f "$SUB_ENV_FILE" ]; then
        $EDITOR "$SUB_ENV_FILE"
    else
        colorized_echo red "Environment file not found at $SUB_ENV_FILE"
        exit 1
    fi
}

console_command() {
        if ! is_remnawave_installed; then
            colorized_echo red "Remnawave not installed!"
            exit 1
        fi
    
     detect_compose
 
        if ! is_remnawave_up; then
            colorized_echo red "Remnawave is not running. Start it first with 'remnawave up'"
            exit 1
        fi

    docker exec -it $APP_NAME remnawave
}

pm2_monitor() {
        if ! is_remnawave_installed; then
            colorized_echo red "Remnawave not installed!"
            exit 1
        fi
    
     detect_compose
 
        if ! is_remnawave_up; then
            colorized_echo red "Remnawave is not running. Start it first with 'remnawave up'"
            exit 1
        fi

    docker exec -it $APP_NAME pm2 monit
}

main_menu() {
    while true; do
        clear
        echo -e "\033[1;37m⚡ $APP_NAME Panel Management\033[0m \033[38;5;244mv$SCRIPT_VERSION\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
        echo
        
        # Проверка статуса панели
        if is_remnawave_installed; then
            if is_remnawave_up; then
                echo -e "\033[1;32m✅ Panel Status: RUNNING\033[0m"
                
                if [ -f "$ENV_FILE" ]; then

                    local panel_domain=$(grep "FRONT_END_DOMAIN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs 2>/dev/null)
                    local sub_domain=$(grep "SUB_PUBLIC_DOMAIN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs 2>/dev/null)
                    
                    echo
                    echo -e "\033[1;37m🌐 Access URLs:\033[0m"
                    
                    local domains_found=0
                    
                    # Panel Domain (FRONT_END_DOMAIN)
                    if [ -n "$panel_domain" ] && [ "$panel_domain" != "null" ]; then
                        domains_found=$((domains_found + 1))
                        if [[ "$panel_domain" =~ ^https?:// ]]; then
                            printf "   \033[38;5;15m📊 Admin Panel:\033[0m    \033[38;5;117m%s\033[0m\n" "$panel_domain"
                        else
                            printf "   \033[38;5;15m📊 Admin Panel:\033[0m    \033[38;5;117mhttps://%s\033[0m\n" "$panel_domain"
                        fi
                    fi
                    
                    # Subscription Domain (SUB_PUBLIC_DOMAIN)
                    if [ -n "$sub_domain" ] && [ "$sub_domain" != "null" ]; then
                        domains_found=$((domains_found + 1))
                        if [[ "$sub_domain" =~ ^https?:// ]]; then
                            printf "   \033[38;5;15m📄 Subscriptions:\033[0m   \033[38;5;117m%s\033[0m\n" "$sub_domain"
                        else
                            printf "   \033[38;5;15m📄 Subscriptions:\033[0m   \033[38;5;117mhttps://%s\033[0m\n" "$sub_domain"
                        fi
                    fi
                    
                    echo
                    if [ "$domains_found" -gt 0 ]; then
                        echo -e "\033[38;5;32m✅ Domains configured - Panel accessible via HTTPS\033[0m"
                    else
                        echo -e "\033[1;33m⚠️  No domains configured - Panel not accessible!\033[0m"
                        echo
                        echo -e "\033[1;37m🔧 Setup Required:\033[0m"
                        echo -e "\033[38;5;244m   1. Configure reverse proxy (nginx/cloudflare)\033[0m"
                        echo -e "\033[38;5;244m   2. Set domains in environment (option 13)\033[0m"
                        echo -e "\033[38;5;244m   3. Configure SSL certificates\033[0m"
                    fi
                fi
                
                # Показываем статус сервисов
                echo
                echo -e "\033[1;37m🔧 Services Status:\033[0m"
                detect_compose
                cd "$APP_DIR" 2>/dev/null || true
                local services_status=$($COMPOSE -f "$COMPOSE_FILE" ps --format "table" 2>/dev/null || echo "")
                
                if [ -n "$services_status" ]; then
                    # Подсчитываем сервисы
                    local total_services=$(echo "$services_status" | tail -n +2 | wc -l)
                    local running_services=$(echo "$services_status" | tail -n +2 | grep -c "Up" || echo "0")
                    local healthy_services=$(echo "$services_status" | tail -n +2 | grep -c "healthy" || echo "0")
                    
                    printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s/%s running\033[0m\n" "Total Services:" "$running_services" "$total_services"
                    if [ "$healthy_services" -gt 0 ]; then
                        printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s healthy\033[0m\n" "Health Checks:" "$healthy_services"
                    fi
                fi
                
                # Показываем использование ресурсов
                echo
                echo -e "\033[1;37m💾 Resource Usage:\033[0m"
                
                # CPU и Memory
                local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "N/A")
                local mem_info=$(free -h | grep "Mem:" 2>/dev/null)
                local mem_used=$(echo "$mem_info" | awk '{print $3}' 2>/dev/null || echo "N/A")
                local mem_total=$(echo "$mem_info" | awk '{print $2}' 2>/dev/null || echo "N/A")
                
                printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s%%\033[0m\n" "CPU Usage:" "$cpu_usage"
                printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s / %s\033[0m\n" "Memory Usage:" "$mem_used" "$mem_total"
                
                # Дисковое пространство
                local disk_usage=$(df -h "$APP_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' 2>/dev/null || echo "N/A")
                local disk_available=$(df -h "$APP_DIR" 2>/dev/null | tail -1 | awk '{print $4}' 2>/dev/null || echo "N/A")
                
                printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s%% used, %s available\033[0m\n" "Disk Usage:" "$disk_usage" "$disk_available"
                
                # Информация о бэкапах
                if [ -f "$BACKUP_CONFIG_FILE" ]; then
                    echo
                    echo -e "\033[1;37m📅 Backup Status:\033[0m"
                    local backup_enabled=$(jq -r '.telegram.enabled // false' "$BACKUP_CONFIG_FILE" 2>/dev/null)
                    local backup_schedule=$(jq -r '.schedule // "Not configured"' "$BACKUP_CONFIG_FILE" 2>/dev/null)
                    local scheduler_status=$(schedule_get_status 2>/dev/null || echo "disabled")
                    
                    printf "   \033[38;5;15m%-15s\033[0m " "Scheduler:"
                    if [ "$scheduler_status" = "enabled" ]; then
                        echo -e "\033[1;32m✅ Enabled\033[0m"
                    else
                        echo -e "\033[1;31m❌ Disabled\033[0m"
                    fi
                    
                    printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Schedule:" "$backup_schedule"
                    printf "   \033[38;5;15m%-15s\033[0m " "Telegram:"
                    if [ "$backup_enabled" = "true" ]; then
                        echo -e "\033[1;32m✅ Enabled\033[0m"
                    else
                        echo -e "\033[38;5;244m❌ Disabled\033[0m"
                    fi
                    
                    # Последний бэкап
                    if [ -d "$APP_DIR/backups" ]; then
                        local last_backup=$(ls -t "$APP_DIR/backups"/*.sql* 2>/dev/null | head -1)
                        if [ -n "$last_backup" ]; then
                            local backup_date=$(stat -c %y "$last_backup" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
                            printf "   \033[38;5;15m%-15s\033[0m \033[38;5;250m%s\033[0m\n" "Last Backup:" "$backup_date"
                        fi
                    fi
                fi
                
            else
                echo -e "\033[1;31m❌ Panel Status: STOPPED\033[0m"
                echo -e "\033[38;5;244m   Services are installed but not running\033[0m"
                echo -e "\033[38;5;244m   Use option 4 to start services\033[0m"
            fi
        else
            echo -e "\033[1;33m⚠️  Panel Status: NOT INSTALLED\033[0m"
            echo -e "\033[38;5;244m   Use option 1 to install Remnawave Panel\033[0m"
        fi
        
        echo
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
        echo
        echo -e "\033[1;37m🚀 Installation & Updates:\033[0m"
        echo -e "   \033[38;5;15m1)\033[0m 🛠️  Install Remnawave panel"
        echo -e "   \033[38;5;15m2)\033[0m ⬆️  Update to latest version"
        echo -e "   \033[38;5;15m3)\033[0m 🗑️  Remove panel completely"
        echo
        echo -e "\033[1;37m⚙️  Service Management:\033[0m"
        echo -e "   \033[38;5;15m4)\033[0m ▶️  Start all services"
        echo -e "   \033[38;5;15m5)\033[0m ⏹️  Stop all services"
        echo -e "   \033[38;5;15m6)\033[0m 🔄 Restart all services"
        echo -e "   \033[38;5;15m7)\033[0m 📊 Show services status"
        echo
        echo -e "\033[1;37m📊 Monitoring & Logs:\033[0m"
        echo -e "   \033[38;5;15m8)\033[0m 📋 View application logs"
        echo -e "   \033[38;5;15m9)\033[0m 📈 System performance monitor"
        echo -e "   \033[38;5;15m10)\033[0m 🩺 Health check diagnostics"
        echo
        echo -e "\033[1;37m💾 Backup & Automation:\033[0m"
        echo -e "   \033[38;5;15m11)\033[0m 💾 Manual database backup"
        echo -e "   \033[38;5;15m12)\033[0m 📅 Scheduled backup system"
        echo
        echo -e "\033[1;37m🔧 Configuration & Access:\033[0m"
        echo -e "   \033[38;5;15m13)\033[0m 📝 Edit configuration files"
        echo -e "   \033[38;5;15m14)\033[0m 🖥️  Access container shell"
        echo -e "   \033[38;5;15m15)\033[0m 📊 PM2 process monitor"
        echo
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
        echo -e "\033[38;5;15m   0)\033[0m 🚪 Exit to terminal"
        echo
        echo -e "\033[38;5;8mRemnawave Panel CLI v$SCRIPT_VERSION by DigneZzZ • gig.ovh\033[0m"
        echo
        read -p "$(echo -e "\033[1;37mSelect option [0-15]:\033[0m ")" choice
        
        case "$choice" in
            1) install_command; read -p "Press Enter to continue..." ;;
            2) update_command; read -p "Press Enter to continue..." ;;
            3) uninstall_command; read -p "Press Enter to continue..." ;;
            4) up_command; read -p "Press Enter to continue..." ;;
            5) down_command; read -p "Press Enter to continue..." ;;
            6) restart_command; read -p "Press Enter to continue..." ;;
            7) status_command; read -p "Press Enter to continue..." ;;
            8) logs_command ;;
            9) monitor_command ;;
            10) health_check_command; read -p "Press Enter to continue..." ;;
            11) backup_command; read -p "Press Enter to continue..." ;;
            12) schedule_menu ;;
            13) edit_command_menu ;;
            14) console_command ;;
            15) pm2_monitor ;;
            0) clear; exit 0 ;;
            *) 
                echo -e "\033[1;31mInvalid option!\033[0m"
                sleep 1
                ;;
        esac
    done
}


edit_command_menu() {
    while true; do
        clear
        echo -e "\033[1;37m📝 Configuration Editor\033[0m"
        echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
        echo
        echo -e "   \033[38;5;15m1)\033[0m 📝 Edit docker-compose.yml"
        echo -e "   \033[38;5;15m2)\033[0m ⚙️  Edit main environment (.env)"
        echo -e "   \033[38;5;15m3)\033[0m 📄 Edit subscription environment (.env.subscription)"
        echo -e "   \033[38;5;244m0)\033[0m ⬅️  Back"
        echo
        
        read -p "Select option [0-3]: " choice
        
        case "$choice" in
            1) edit_command; read -p "Press Enter to continue..." ;;
            2) edit_env_command; read -p "Press Enter to continue..." ;;
            3) edit_env_sub_command; read -p "Press Enter to continue..." ;;
            0) return 0 ;;
            *) 
                echo -e "\033[1;31mInvalid option!\033[0m"
                sleep 1
                ;;
        esac
    done
}

usage() {
    echo -e "\033[1;37m⚡ $APP_NAME\033[0m \033[38;5;8mPanel Management CLI\033[0m \033[38;5;244mv$SCRIPT_VERSION\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
    echo
    echo -e "\033[1;37m� Installation & Updates:\033[0m"
    printf "   \033[38;5;15m%-18s\033[0m %s\n" "install" "🛠️  Install Remnawave panel"
    printf "   \033[38;5;15m%-18s\033[0m %s\n" "update" "⬆️  Update to latest version"
    printf "   \033[38;5;15m%-18s\033[0m %s\n" "uninstall" "🗑️  Remove panel completely"
    echo

    echo -e "\033[1;37m⚙️  Service Management:\033[0m"
    printf "   \033[38;5;250m%-18s\033[0m %s\n" "up" "▶️  Start all services"
    printf "   \033[38;5;250m%-18s\033[0m %s\n" "down" "⏹️  Stop all services"
    printf "   \033[38;5;250m%-18s\033[0m %s\n" "restart" "🔄 Restart all services"
    printf "   \033[38;5;250m%-18s\033[0m %s\n" "status" "📊 Show services status"
    echo

    echo -e "\033[1;37m📊 Monitoring & Logs:\033[0m"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "logs" "📋 View application logs"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "monitor" "📈 System performance monitor"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "health" "🩺 Health check diagnostics"
    echo

    echo -e "\033[1;37m💾 Backup & Automation:\033[0m"
    printf "   \033[38;5;178m%-18s\033[0m %s\n" "backup" "💾 Manual database backup"
    printf "   \033[38;5;178m%-18s\033[0m %s\n" "schedule" "📅 Scheduled backup system"
    echo

    echo -e "\033[1;37m🔧 Configuration & Access:\033[0m"
    printf "   \033[38;5;117m%-18s\033[0m %s\n" "edit" "📝 Edit docker-compose.yml"
    printf "   \033[38;5;117m%-18s\033[0m %s\n" "edit-env" "⚙️  Edit environment variables"
    printf "   \033[38;5;117m%-18s\033[0m %s\n" "edit-env-sub" "⚙️  Edit subscription environment variables"
    printf "   \033[38;5;117m%-18s\033[0m %s\n" "console" "�️  Access container shell"
    printf "   \033[38;5;117m%-18s\033[0m %s\n" "pm2-monitor" "📊 PM2 process monitor"
    echo

    echo -e "\033[1;37m� Script Management:\033[0m"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "install-script" "📥 Install this script globally"
    printf "   \033[38;5;244m%-18s\033[0m %s\n" "uninstall-script" "📤 Remove script from system"
    echo

    if is_remnawave_installed && [ -f "$ENV_FILE" ]; then
        local panel_domain=$(grep "FRONT_END_DOMAIN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs 2>/dev/null)
        if [ -n "$panel_domain" ] && [ "$panel_domain" != "null" ]; then
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
            if [[ "$panel_domain" =~ ^https?:// ]]; then
                echo -e "\033[1;37m🌐 Panel Access:\033[0m \033[38;5;117m$panel_domain\033[0m"
            else
                echo -e "\033[1;37m🌐 Panel Access:\033[0m \033[38;5;117mhttps://$panel_domain\033[0m"
            fi
        fi
    fi

    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
    echo -e "\033[1;37m📖 Examples:\033[0m"
    echo -e "\033[38;5;244m   sudo $APP_NAME install --name mypanel\033[0m"
    echo -e "\033[38;5;244m   sudo $APP_NAME schedule setup\033[0m"
    echo -e "\033[38;5;244m   sudo $APP_NAME backup --compress\033[0m"
    echo -e "\033[38;5;244m   $APP_NAME menu           # Interactive menu\033[0m"
    echo -e "\033[38;5;244m   $APP_NAME                # Same as menu\033[0m"
    echo
    echo -e "\033[38;5;8mUse '\033[38;5;15m$APP_NAME <command> --help\033[38;5;8m' for detailed command help\033[0m"
    echo
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
    echo -e "\033[38;5;8m📚 Project: \033[38;5;250mhttps://gig.ovh\033[0m"
    echo -e "\033[38;5;8m🐛 Issues: \033[38;5;250mhttps://github.com/DigneZzZ/remnawave-scripts\033[0m"
    echo -e "\033[38;5;8m💬 Support: \033[38;5;250mhttps://t.me/remnawave\033[0m"
    echo -e "\033[38;5;8m👨‍💻 Author: \033[38;5;250mDigneZzZ\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
}

# Обновляем usage_minimal()
usage_minimal() {
    echo -e "\033[1;37m⚡ $APP_NAME\033[0m \033[38;5;244mv$SCRIPT_VERSION\033[0m"
    echo
    echo -e "\033[1;37mMain:\033[0m"
    printf "   \033[38;5;15m%-12s\033[0m %s\n" "install" "🛠️  Install"
    printf "   \033[38;5;15m%-12s\033[0m %s\n" "update" "⬆️  Update"
    printf "   \033[38;5;15m%-12s\033[0m %s\n" "uninstall" "🗑️  Remove"
    echo
    echo -e "\033[1;37mControl:\033[0m"
    printf "   \033[38;5;250m%-12s\033[0m %s\n" "up" "▶️  Start"
    printf "   \033[38;5;250m%-12s\033[0m %s\n" "down" "⏹️  Stop"
    printf "   \033[38;5;250m%-12s\033[0m %s\n" "restart" "🔄 Restart"
    printf "   \033[38;5;250m%-12s\033[0m %s\n" "status" "📊 Status"
    echo
    echo -e "\033[1;37mTools:\033[0m"
    printf "   \033[38;5;244m%-12s\033[0m %s\n" "logs" "📋 Logs"
    printf "   \033[38;5;244m%-12s\033[0m %s\n" "monitor" "📈 Monitor"
    printf "   \033[38;5;244m%-12s\033[0m %s\n" "health" "🩺 Health"
    printf "   \033[38;5;244m%-12s\033[0m %s\n" "backup" "💾 Backup"
    printf "   \033[38;5;244m%-12s\033[0m %s\n" "schedule" "📅 Schedule"
    echo
    echo -e "\033[38;5;8mUse '\033[38;5;15m$APP_NAME help\033[38;5;8m' for full help\033[0m"
    echo -e "\033[38;5;8m👨‍💻 DigneZzZ | 📚 gig.ovh\033[0m"
}

# Обновляем usage_compact()
usage_compact() {
    echo -e "\033[1;37m⚡ $APP_NAME\033[0m \033[38;5;8mPanel CLI\033[0m \033[38;5;244mv$SCRIPT_VERSION\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 50))\033[0m"
    echo
    
    echo -e "\033[1;37m🚀 Main:\033[0m"
    printf "   \033[38;5;15m%-16s\033[0m %s\n" "install" "🛠️  Install panel"
    printf "   \033[38;5;15m%-16s\033[0m %s\n" "update" "⬆️  Update system"
    printf "   \033[38;5;15m%-16s\033[0m %s\n" "uninstall" "🗑️  Remove panel"
    echo

    echo -e "\033[1;37m⚙️  Control:\033[0m"
    printf "   \033[38;5;250m%-16s\033[0m %s\n" "up" "▶️  Start services"
    printf "   \033[38;5;250m%-16s\033[0m %s\n" "down" "⏹️  Stop services"
    printf "   \033[38;5;250m%-16s\033[0m %s\n" "restart" "🔄 Restart services"
    printf "   \033[38;5;250m%-16s\033[0m %s\n" "status" "📊 Show status"
    echo

    echo -e "\033[1;37m📊 Monitoring:\033[0m"
    printf "   \033[38;5;244m%-16s\033[0m %s\n" "logs" "📋 View logs"
    printf "   \033[38;5;244m%-16s\033[0m %s\n" "monitor" "📈 Performance"
    printf "   \033[38;5;244m%-16s\033[0m %s\n" "health" "🩺 Health check"
    echo

    echo -e "\033[1;37m💾 Backup:\033[0m"
    printf "   \033[38;5;178m%-16s\033[0m %s\n" "backup" "💾 Manual backup"
    printf "   \033[38;5;178m%-16s\033[0m %s\n" "schedule" "📅 Auto backup"
    echo

    echo -e "\033[1;37m🔧 Config:\033[0m"
    printf "   \033[38;5;117m%-16s\033[0m %s\n" "edit" "📝 Edit compose"
    printf "   \033[38;5;117m%-16s\033[0m %s\n" "edit-env" "⚙️  Edit environment"
    printf "   \033[38;5;117m%-16s\033[0m %s\n" "edit-env-sub" "⚙️  Edit subscription environment"
    printf "   \033[38;5;117m%-16s\033[0m %s\n" "console" "🖥️  Shell access"
    echo

    if is_remnawave_installed && [ -f "$ENV_FILE" ]; then
        local panel_domain=$(grep "FRONT_END_DOMAIN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs 2>/dev/null)
        if [ -n "$panel_domain" ] && [ "$panel_domain" != "null" ]; then
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 60))\033[0m"
            if [[ "$panel_domain" =~ ^https?:// ]]; then
                echo -e "\033[1;37m🌐 Panel Access:\033[0m \033[38;5;117m$panel_domain\033[0m"
            else
                echo -e "\033[1;37m🌐 Panel Access:\033[0m \033[38;5;117mhttps://$panel_domain\033[0m"
            fi
        fi
    fi
    echo
    echo -e "\033[38;5;8mUse '\033[38;5;15m$APP_NAME <command> help\033[38;5;8m' for details\033[0m"
    echo
    echo -e "\033[38;5;8m📚 \033[38;5;250mhttps://gig.ovh\033[38;5;8m | 💬 \033[38;5;250m@remnawave\033[38;5;8m | 👨‍💻 \033[38;5;250mDigneZzZ\033[0m"
}


show_version() {
    echo -e "\033[1;37m⚡ Remnawave Panel CLI\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
    echo -e "\033[38;5;250mVersion: \033[38;5;15m$SCRIPT_VERSION\033[0m"
    echo -e "\033[38;5;250mAuthor:  \033[38;5;15mDigneZzZ\033[0m"
    echo -e "\033[38;5;250mGitHub:  \033[38;5;15mhttps://github.com/DigneZzZ/remnawave-scripts\033[0m"
    echo -e "\033[38;5;250mProject: \033[38;5;15mhttps://gig.ovh\033[0m"
    echo -e "\033[38;5;250mCommunity: \033[38;5;15mhttps://openode.xyz\033[0m"
    echo -e "\033[38;5;250mSupport: \033[38;5;15mhttps://t.me/remnawave\033[0m"
    echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 40))\033[0m"
}


command_help() {
    local cmd="$1"
    
    case "$cmd" in
        install)
            echo -e "\033[1;37m📖 Install Command Help\033[0m"
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
            echo
            echo -e "\033[1;37mUsage:\033[0m"
            echo -e "   \033[38;5;15m$APP_NAME install [options]\033[0m"
            echo
            echo -e "\033[1;37mOptions:\033[0m"
            echo -e "   \033[38;5;15m--name <name>\033[0m    Custom installation name"
            echo -e "   \033[38;5;15m--dev\033[0m            Use development branch"
            echo
            echo -e "\033[1;37mExamples:\033[0m"
            echo -e "   \033[38;5;244m$APP_NAME install\033[0m"
            echo -e "   \033[38;5;244m$APP_NAME install --name mypanel\033[0m"
            echo -e "   \033[38;5;244m$APP_NAME install --dev\033[0m"
            ;;
        schedule)
            echo -e "\033[1;37m📖 Schedule Command Help\033[0m"
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
            echo
            echo -e "\033[1;37mUsage:\033[0m"
            echo -e "   \033[38;5;15m$APP_NAME schedule [action]\033[0m"
            echo
            echo -e "\033[1;37mActions:\033[0m"
            echo -e "   \033[38;5;15msetup\033[0m           Configure backup settings"
            echo -e "   \033[38;5;15menable\033[0m          Enable scheduler"
            echo -e "   \033[38;5;15mdisable\033[0m         Disable scheduler"
            echo -e "   \033[38;5;15mstatus\033[0m          Show scheduler status"
            echo -e "   \033[38;5;15mtest\033[0m            Test backup creation"
            echo -e "   \033[38;5;15mtest-telegram\033[0m   Test Telegram delivery"
            echo -e "   \033[38;5;15mrun\033[0m             Run backup now"
            echo -e "   \033[38;5;15mlogs\033[0m            View backup logs"
            echo -e "   \033[38;5;15mcleanup\033[0m         Clean old backups"
            echo
            echo -e "\033[1;37mFeatures:\033[0m"
            echo -e "   \033[38;5;250m• Automated database backups\033[0m"
            echo -e "   \033[38;5;250m• Telegram notifications with file splitting\033[0m"
            echo -e "   \033[38;5;250m• Configurable retention policies\033[0m"
            echo -e "   \033[38;5;250m• Compression options\033[0m"
            echo -e "   \033[38;5;250m• Thread support for group chats\033[0m"
            ;;

        backup)
            echo -e "\033[1;37m📖 Backup Command Help\033[0m"
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
            echo
            echo -e "\033[1;37mUsage:\033[0m"
            echo -e "   \033[38;5;15m$APP_NAME backup [options]\033[0m"
            echo
            echo -e "\033[1;37mOptions:\033[0m"
            echo -e "   \033[38;5;15m--compress\033[0m       Create compressed backup"
            echo -e "   \033[38;5;15m--output <dir>\033[0m   Specify output directory"
            echo
            echo -e "\033[1;37mNote:\033[0m"
            echo -e "   \033[38;5;250mFor automated backups with Telegram delivery,\033[0m"
            echo -e "   \033[38;5;250muse '\033[38;5;15m$APP_NAME schedule\033[38;5;250m' command instead.\033[0m"
            ;;
        monitor)
            echo -e "\033[1;37m📖 Monitor Command Help\033[0m"
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
            echo
            echo -e "\033[1;37mDescription:\033[0m"
            echo -e "   \033[38;5;250mReal-time system monitoring dashboard\033[0m"
            echo
            echo -e "\033[1;37mDisplays:\033[0m"
            echo -e "   \033[38;5;250m• CPU and Memory usage\033[0m"
            echo -e "   \033[38;5;250m• Docker container stats\033[0m"
            echo -e "   \033[38;5;250m• Network I/O\033[0m"
            echo -e "   \033[38;5;250m• Disk usage\033[0m"
            echo -e "   \033[38;5;250m• Service health status\033[0m"
            echo
            echo -e "\033[1;37mControls:\033[0m"
            echo -e "   \033[38;5;250mPress \033[38;5;15mCtrl+C\033[38;5;250m to exit\033[0m"
            ;;
        health)
            echo -e "\033[1;37m📖 Health Command Help\033[0m"
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 30))\033[0m"
            echo
            echo -e "\033[1;37mDescription:\033[0m"
            echo -e "   \033[38;5;250mComprehensive system health diagnostics\033[0m"
            echo
            echo -e "\033[1;37mChecks:\033[0m"
            echo -e "   \033[38;5;250m• Service availability\033[0m"
            echo -e "   \033[38;5;250m• Database connectivity\033[0m"
            echo -e "   \033[38;5;250m• Port accessibility\033[0m"
            echo -e "   \033[38;5;250m• Resource usage\033[0m"
            echo -e "   \033[38;5;250m• Docker health\033[0m"
            echo -e "   \033[38;5;250m• Configuration validation\033[0m"
            ;;
        *)
            echo -e "\033[1;37m📖 Command Help\033[0m"
            echo -e "\033[38;5;8m$(printf '─%.0s' $(seq 1 20))\033[0m"
            echo
            echo -e "\033[1;31mUnknown command: $cmd\033[0m"
            echo
            echo -e "\033[1;37mAvailable commands:\033[0m"
            echo -e "   \033[38;5;250minstall, update, uninstall, up, down, restart\033[0m"
            echo -e "   \033[38;5;250mstatus, logs, monitor, health, backup, schedule\033[0m"
            echo -e "   \033[38;5;250medit, edit-env, console, pm2-monitor\033[0m"
            echo
            echo -e "\033[38;5;8mUse '\033[38;5;15m$APP_NAME help\033[38;5;8m' for full usage\033[0m"
            ;;
    esac
}

# Обновляем smart_usage для обработки help
smart_usage() {
    # Проверяем, запрашивается ли help для конкретной команды
    if [ "$1" = "help" ] && [ -n "$2" ]; then
        command_help "$2"
        return
    fi
    
    local terminal_width=$(tput cols 2>/dev/null || echo "80")
    local terminal_height=$(tput lines 2>/dev/null || echo "24")
    
    if [ "$terminal_width" -lt 50 ]; then
        usage_minimal
    elif [ "$terminal_width" -lt 80 ] || [ "$terminal_height" -lt 35 ]; then
        usage_compact
    else
        usage
    fi
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
    monitor) monitor_command ;;
    health) health_check_command ;;
    schedule) schedule_command "$@" ;;
    install-script) install_remnawave_script ;;
    uninstall-script) uninstall_remnawave_script ;;
    edit) edit_command ;;
    edit-env) edit_env_command ;;
    edit-env-sub) edit_env_sub_command ;;
    console) console_command ;;
    pm2-monitor) pm2_monitor ;;
    backup) backup_command ;;
    menu) main_menu ;;  
    help) smart_usage "help" "$1" ;;
    --version|-v) show_version ;;
    --help|-h) smart_usage ;;
    "") main_menu ;;    
    *) smart_usage ;;
esac

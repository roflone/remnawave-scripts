#!/usr/bin/env bash
set -e

# Variables
INSTALL_DIR="/opt"
APP_NAME="remnawave"
APP_DIR="$INSTALL_DIR/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
REPO_URL="https://raw.githubusercontent.com/DigneZzZ/remnawave-scripts/main"

# Utility Functions
colorized_echo() {
    local color=$1
    local text=$2
    case $color in
        "red") printf "\e[91m${text}\e[0m\n";;
        "green") printf "\e[92m${text}\e[0m\n";;
        "yellow") printf "\e[93m${text}\e[0m\n";;
        "blue") printf "\e[94m${text}\e[0m\n";;
        *) echo "${text}";;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        colorized_echo red "Docker Compose not found. Please install Docker Compose."
        exit 1
    fi
}

# Telegram Backup Functions
send_backup_to_telegram() {
    if [ "$(grep -c "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE")" -eq 0 ]; then
        colorized_echo yellow "Backup service is not enabled. Skipping Telegram upload."
        return
    fi

    local bot_key=$(grep "BACKUP_TELEGRAM_BOT_KEY" "$ENV_FILE" | cut -d'=' -f2)
    local chat_id=$(grep "BACKUP_TELEGRAM_CHAT_ID" "$ENV_FILE" | cut -d'=' -f2)
    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local latest_backup=$(ls -t "$APP_DIR/backup" | head -n 1)
    local backup_path="$APP_DIR/backup/$latest_backup"

    if [ ! -f "$backup_path" ]; then
        colorized_echo red "No backups found to send."
        return
    fi

    local backup_size=$(du -m "$backup_path" | cut -f1)
    local split_dir="/tmp/remnawave_backup_split"
    local is_single_file=true

    mkdir -p "$split_dir"

    if [ "$backup_size" -gt 49 ]; then
        colorized_echo yellow "Backup is larger than 49MB. Splitting the archive..."
        split -b 49M "$backup_path" "$split_dir/part_"
        is_single_file=false
    else
        cp "$backup_path" "$split_dir/part_aa"
    fi

    local backup_time=$(date "+%Y-%m-%d %H:%M:%S %Z")

    for part in "$split_dir"/*; do
        local part_name=$(basename "$part")
        local custom_filename="backup_${part_name}.sql"
        local caption="📦 *Backup Information*\n🌐 *Server IP*: \`${server_ip}\`\n📁 *Backup File*: \`${custom_filename}\`\n⏰ *Backup Time*: \`${backup_time}\`"
        curl -s -F chat_id="$chat_id" \
            -F document=@"$part;filename=$custom_filename" \
            -F caption="$(echo -e "$caption" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g')" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$bot_key/sendDocument" >/dev/null 2>&1 && \
        colorized_echo green "Backup part $custom_filename successfully sent to Telegram." || \
        colorized_echo red "Failed to send backup part $custom_filename to Telegram."
    done

    rm -rf "$split_dir"
}

backup_service() {
    check_running_as_root
    detect_compose
    [ -f "$ENV_FILE" ] || { colorized_echo red "Environment file not found"; exit 1; }

    colorized_echo blue "====================================="
    colorized_echo blue "      Welcome to Backup Service      "
    colorized_echo blue "====================================="

    if grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        local bot_key=$(grep "BACKUP_TELEGRAM_BOT_KEY" "$ENV_FILE" | cut -d'=' -f2)
        local chat_id=$(grep "BACKUP_TELEGRAM_CHAT_ID" "$ENV_FILE" | cut -d'=' -f2)
        local cron_schedule=$(grep "BACKUP_CRON_SCHEDULE" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
        local interval_hours=""
        if [[ "$cron_schedule" == "0 0 * * *" ]]; then
            interval_hours=24
        else
            interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
        fi

        colorized_echo green "Current Backup Configuration:"
        colorized_echo cyan "Telegram Bot API Key: $bot_key"
        colorized_echo cyan "Telegram Chat ID: $chat_id"
        colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
        echo "Choose an option:"
        echo "1. Reconfigure Backup Service"
        echo "2. Remove Backup Service"
        echo "3. Exit"
        read -p "Enter your choice (1-3): " user_choice

        case $user_choice in
            1) remove_backup_service;;
            2) remove_backup_service; return;;
            3) return;;
            *) colorized_echo red "Invalid choice. Exiting."; return;;
        esac
    else
        colorized_echo yellow "No backup service is currently configured."
    fi

    read -p "Enable Telegram backup service? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo yellow "Telegram backup service will be disabled."
        sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
        echo "BACKUP_SERVICE_ENABLED=false" >> "$ENV_FILE"
        return
    fi

    local bot_key chat_id interval_hours cron_schedule
    while true; do
        read -p "Enter your Telegram Bot API Key: " bot_key
        [ -n "$bot_key" ] && break
        colorized_echo red "API key cannot be empty."
    done

    while true; do
        read -p "Enter your Telegram Chat ID: " chat_id
        [ -n "$chat_id" ] && break
        colorized_echo red "Chat ID cannot be empty."
    done

    while true; do
        read -p "Set backup interval in hours (1-24): " interval_hours
        if [[ "$interval_hours" =~ ^[0-9]+$ ]] && [ "$interval_hours" -ge 1 ] && [ "$interval_hours" -le 24 ]; then
            if [ "$interval_hours" -eq 24 ]; then
                cron_schedule="0 0 * * *"
                colorized_echo green "Setting backup to run daily at midnight."
            else
                cron_schedule="0 */$interval_hours * * *"
                colorized_echo green "Setting backup to run every $interval_hours hour(s)."
            fi
            break
        fi
        colorized_echo red "Invalid input. Enter a number between 1-24."
    done

    sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/^BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    echo "" >> "$ENV_FILE"
    echo "# Backup service configuration" >> "$ENV_FILE"
    echo "BACKUP_SERVICE_ENABLED=true" >> "$ENV_FILE"
    echo "BACKUP_TELEGRAM_BOT_KEY=$bot_key" >> "$ENV_FILE"
    echo "BACKUP_TELEGRAM_CHAT_ID=$chat_id" >> "$ENV_FILE"
    echo "BACKUP_CRON_SCHEDULE=\"$cron_schedule\"" >> "$ENV_FILE"

    local backup_command="$(which bash) -c 'remna backup'"
    crontab -l 2>/dev/null | grep -v "$backup_command" > /tmp/cron || true
    echo "$cron_schedule $backup_command # remnawave-backup" >> /tmp/cron
    crontab /tmp/cron
    rm /tmp/cron

    colorized_echo green "Backup service configured successfully."
    if [ "$interval_hours" -eq 24 ]; then
        colorized_echo cyan "Backups will run daily at midnight."
    else
        colorized_echo cyan "Backups will run every $interval_hours hour(s)."
    fi
}

remove_backup_service() {
    sed -i '/^# Backup service configuration/d' "$ENV_FILE"
    sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/^BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    crontab -l 2>/dev/null | grep -v "# remnawave-backup" > /tmp/cron || true
    crontab /tmp/cron
    rm /tmp/cron

    colorized_echo green "Backup service removed."
}

# Command Functions
install_command() {
    check_running_as_root

    if [ -d "$APP_DIR" ]; then
        colorized_echo red "Remnawave is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
        rm -rf "$APP_DIR"
    fi

    mkdir -p "$APP_DIR"

    colorized_echo blue "Fetching docker-compose.yml"
    cat > "$COMPOSE_FILE" <<EOF
version: '3.8'
services:
  remnawave-db:
    image: postgres:17
    container_name: 'remnawave-db'
    hostname: remnawave-db
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
      - remnawave-db-data:/var/lib/postgresql/data
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave:
    image: remnawave/backend:dev
    container_name: 'remnawave'
    hostname: remnawave
    restart: always
    ports:
      - '127.0.0.1:3000:3000'
    env_file:
      - .env
    networks:
      - remnawave-network
    depends_on:
      remnawave-db:
        condition: service_healthy

  remnawave-redis:
    image: valkey/valkey:8.0.2-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    networks:
      - remnawave-network
    volumes:
      - remnawave-redis-data:/data

  remnawave-json:
    image: ghcr.io/jolymmiles/remnawave-json:latest
    container_name: 'remnawave-json'
    ports:
      - '127.0.0.1:4000:4000'
    env_file:
      - .env
    networks:
      - remnawave-network
    volumes:
      - /opt/remnawave/remnawave-json/templates/subscription/index.html:/app/templates/subscription/index.html
      - /opt/remnawave/remnawave-json/templates/2ray/v2ray.json:/app/templates/v2ray/v2ray.json

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    external: false
    name: remnawave-db-data
  remnawave-redis-data:
    driver: local
    external: false
    name: remnawave-redis-data
EOF

    # Prompt for domains
    colorized_echo blue "Please enter the domain for the Remnawave panel (e.g., test.openode.ru):"
    read -p "Panel Domain: " panel_domain
    while [ -z "$panel_domain" ]; do
        colorized_echo red "Panel domain cannot be empty. Please try again."
        read -p "Panel Domain: " panel_domain
    done

    colorized_echo blue "Please enter the domain for the subscription page (e.g., link.openode.ru):"
    read -p "Subscription Domain: " sub_domain
    while [ -z "$sub_domain" ]; do
        colorized_echo red "Subscription domain cannot be empty. Please try again."
        read -p "Subscription Domain: " sub_domain
    done

    # Prompt for Telegram settings
    local telegram_enabled bot_token admin_id notify_chat_id
    read -p "Enable Telegram notifications? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        telegram_enabled="true"
        while true; do
            read -p "Enter your Telegram Bot Token: " bot_token
            [ -n "$bot_token" ] && break
            colorized_echo red "Bot token cannot be empty."
        done
        while true; do
            read -p "Enter your Telegram Admin ID: " admin_id
            [ -n "$admin_id" ] && break
            colorized_echo red "Admin ID cannot be empty."
        done
        while true; do
            read -p "Enter your Telegram Nodes Notify Chat ID: " notify_chat_id
            [ -n "$notify_chat_id" ] && break
            colorized_echo red "Notify Chat ID cannot be empty."
        done
    else
        telegram_enabled="false"
        bot_token="change_me"
        admin_id="change_me"
        notify_chat_id="change_me"
    fi

    # Generate secrets
    JWT_AUTH_SECRET=$(openssl rand -hex 128)
    JWT_API_TOKENS_SECRET=$(openssl rand -hex 128)
    METRICS_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

    # Create .env file
    colorized_echo blue "Generating .env file"
    cat > "$ENV_FILE" <<EOF
### APP ###
APP_PORT=3000
METRICS_PORT=3001

### API ###
API_INSTANCES=1

### DATABASE ###
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### REDIS ###
REDIS_HOST=remnawave-redis
REDIS_PORT=6379

### JWT ###
JWT_AUTH_SECRET=$JWT_AUTH_SECRET
JWT_API_TOKENS_SECRET=$JWT_API_TOKENS_SECRET

### TELEGRAM ###
IS_TELEGRAM_ENABLED=$telegram_enabled
TELEGRAM_BOT_TOKEN=$bot_token
TELEGRAM_ADMIN_ID=$admin_id
NODES_NOTIFY_CHAT_ID=$notify_chat_id

### FRONT_END ###
FRONT_END_DOMAIN=$panel_domain

### SUBSCRIPTION ###
SUB_SUPPORT_URL=https://t.me/yourname
SUB_PROFILE_TITLE=Subscription
SUB_UPDATE_INTERVAL=12
SUB_WEBPAGE_URL=https://$panel_domain

### SUBSCRIPTION PUBLIC DOMAIN ###
SUB_PUBLIC_DOMAIN=$sub_domain

### SWAGGER ###
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=true

### PROMETHEUS ###
METRICS_USER=admin
METRICS_PASS=$METRICS_PASS

### WEBHOOK ###
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://webhook.site/1234567890
WEBHOOK_SECRET_HEADER=vsmu67Kmg6R8FjIOF1WUY8LWBHie4scdEqrfsKmyf4IAf8dY3nFS0wwYHkhh6ZvQ

### Database ###
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres

### remnawave-json ###
REMNAWAVE_URL=https://$panel_domain
APP_PORT=4000
APP_HOST=0.0.0.0
V2RAY_TEMPLATE_PATH=/app/templates/v2ray/v2ray.json
WEB_PAGE_TEMPLATE_PATH=/app/templates/subscription/index.html
EOF

    # Install Docker if not present
    if ! command -v docker >/dev/null 2>&1; then
        colorized_echo blue "Installing Docker"
        curl -fsSL https://get.docker.com | sh || {
            colorized_echo red "Failed to install Docker"
            exit 1
        }
    fi

    detect_compose

    # Create directories for remnawave-json templates
    mkdir -p /opt/remnawave/remnawave-json/templates/subscription
    mkdir -p /opt/remnawave/remnawave-json/templates/2ray
    touch /opt/remnawave/remnawave-json/templates/subscription/index.html
    touch /opt/remnawave/remnawave-json/templates/2ray/v2ray.json

    # Pull and start containers
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" pull
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d || {
        colorized_echo red "Failed to start Remnawave services"
        exit 1
    }

    # Install the script as remna
    curl -sSL "$REPO_URL/remnawave.sh" -o /usr/local/bin/remna || {
        colorized_echo red "Failed to install remna script"
        exit 1
    }
    chmod +x /usr/local/bin/remna

    colorized_echo green "Remnawave installed successfully!"
    colorized_echo green "Panel URL: https://$panel_domain"
    colorized_echo green "Subscription URL: http://$sub_domain:4000"
    colorized_echo green "Metrics password: $METRICS_PASS"

    # Prompt for backup service setup
    backup_service
}

up_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d
    colorized_echo green "Remnawave services started"
}

down_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down
    colorized_echo green "Remnawave services stopped"
}

restart_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" restart
    colorized_echo green "Remnawave services restarted"
}

logs_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    if [ "$2" = "--no-follow" ]; then
        $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" logs
    else
        $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" logs -f
    fi
}

status_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" ps
}

update_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" pull
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d
    colorized_echo green "Remnawave updated successfully"
}

backup_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    local backup_dir="$APP_DIR/backup"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local backup_file="$backup_dir/backup_$timestamp.sql"
    $COMPOSE -f "$COMPOSE_FILE" exec -T remnawave-db pg_dump -U postgres -d postgres > "$backup_file" || {
        colorized_echo red "Failed to create backup"
        exit 1
    }
    colorized_echo green "Backup created at: $backup_file"
    send_backup_to_telegram
}

restore_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }

    colorized_echo yellow "WARNING: Restoring a backup will DELETE ALL CURRENT DATA in the database."
    read -p "Are you sure you want to proceed? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Restore aborted."
        exit 1
    fi

    read -p "Enter the absolute path to the backup file: " backup_path
    if [ ! -f "$backup_path" ]; then
        colorized_echo red "File not found: $backup_path"
        exit 1
    fi

    # Basic check to see if it looks like a PostgreSQL dump
    if ! head -n 10 "$backup_path" | grep -q "PostgreSQL database dump"; then
        colorized_echo red "This file does not appear to be a valid PostgreSQL backup."
        exit 1
    fi

    # Drop and recreate the database, then restore
    $COMPOSE -f "$COMPOSE_FILE" exec -T remnawave-db dropdb -U postgres postgres || {
        colorized_echo red "Failed to drop database"
        exit 1
    }
    $COMPOSE -f "$COMPOSE_FILE" exec -T remnawave-db createdb -U postgres postgres || {
        colorized_echo red "Failed to create database"
        exit 1
    }
    $COMPOSE -f "$COMPOSE_FILE" exec -T remnawave-db psql -U postgres -d postgres < "$backup_path" || {
        colorized_echo red "Failed to restore backup"
        exit 1
    }

    colorized_echo green "Database restored successfully from $backup_path"
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" restart remnawave
    colorized_echo green "Remnawave service restarted"
}

core_update_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }

    # Check for unzip dependency
    if ! command -v unzip >/dev/null 2>&1; then
        colorized_echo blue "Installing unzip"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y unzip
        elif command -v yum >/dev/null 2>&1; then
            yum install -y unzip
        else
            colorized_echo red "Package manager not found. Please install unzip manually."
            exit 1
        fi
    fi

    # Download and update Xray core (assumes amd64 for simplicity)
    local xray_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d'"' -f4)
    local xray_filename="Xray-linux-64.zip"
    local xray_url="https://github.com/XTLS/Xray-core/releases/download/$xray_version/$xray_filename"
    mkdir -p "$APP_DIR/xray-core"
    cd "$APP_DIR/xray-core"
    curl -sL "$xray_url" -o "$xray_filename"
    unzip -o "$xray_filename" xray
    rm "$xray_filename"
    chmod +x xray

    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d
    colorized_echo green "Xray core updated to $xray_version"
}

uninstall_command() {
    check_running_as_root
    detect_compose
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    read -p "Remove all data (including database volumes)? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down -v
        rm -rf "$APP_DIR"
        docker volume rm remnawave-db-data remnawave-redis-data 2>/dev/null || true
    else
        $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down
        rm -rf "$APP_DIR"
    fi
    rm -f /usr/local/bin/remna
    colorized_echo green "Remnawave uninstalled successfully"
}

edit_command() {
    [ -f "$COMPOSE_FILE" ] || { colorized_echo red "Compose file not found"; exit 1; }
    ${EDITOR:-nano} "$COMPOSE_FILE"
}

edit_env_command() {
    [ -f "$ENV_FILE" ] || { colorized_echo red "Environment file not found"; exit 1; }
    ${EDITOR:-nano} "$ENV_FILE"
}

install_script_command() {
    check_running_as_root
    curl -sSL "$REPO_URL/remnawave.sh" -o /usr/local/bin/remna || {
        colorized_echo red "Failed to install remna script"
        exit 1
    }
    chmod +x /usr/local/bin/remna
    colorized_echo green "remna script installed successfully"
}

usage() {
    colorized_echo blue "Usage: remna [command]"
    echo
    colorized_echo cyan "Commands:"
    echo "  install       Install Remnawave"
    echo "  up            Start Remnawave services"
    echo "  down          Stop Remnawave services"
    echo "  restart       Restart Remnawave services"
    echo "  logs          Show service logs (--no-follow to disable following)"
    echo "  status        Show service status"
    echo "  update        Update Remnawave to the latest version"
    echo "  backup        Create a database backup"
    echo "  backup-service Configure Telegram backup service"
    echo "  restore       Restore database from a backup file"
    echo "  core-update   Update Xray core"
    echo "  uninstall     Uninstall Remnawave"
    echo "  edit          Edit docker-compose.yml"
    echo "  edit-env      Edit .env file"
    echo "  install-script Install the remna script"
    echo "  help          Show this help message"
}

# Main Logic
case "$1" in
    install)
        shift; install_command "$@";;
    up)
        shift; up_command "$@";;
    down)
        shift; down_command "$@";;
    restart)
        shift; restart_command "$@";;
    logs)
        shift; logs_command "$@";;
    status)
        shift; status_command "$@";;
    update)
        shift; update_command "$@";;
    backup)
        shift; backup_command "$@";;
    backup-service)
        shift; backup_service "$@";;
    restore)
        shift; restore_command "$@";;
    core-update)
        shift; core_update_command "$@";;
    uninstall)
        shift; uninstall_command "$@";;
    edit)
        shift; edit_command "$@";;
    edit-env)
        shift; edit_env_command "$@";;
    install-script)
        shift; install_script_command "$@";;
    help|*)
        usage;;
esac

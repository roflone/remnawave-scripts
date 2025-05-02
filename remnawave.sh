#!/usr/bin/env bash
# Remnawave Panel Installation Script
# This script installs and manages Remnawave Panel

set -e

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        install|update|uninstall|up|down|restart|status|logs|edit|edit-env|console)
            COMMAND="$1"
            shift # past argument
        ;;
        --name)
            if [[ "$COMMAND" == "install" ]]; then
                APP_NAME="$2"
                shift # past argument
            else
                echo "Error: --name parameter is only allowed with 'install' command."
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

# Set default app name if not provided
if [[ "$COMMAND" == "install" ]] && [ -z "$APP_NAME" ]; then
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

colorized_echo() {
    local color=$1
    local text=$2
    local style=${3:-0}  # Default style is normal

    case $color in
        "red") printf "\e[${style};91m${text}\e[0m
" ;;
        "green") printf "\e[${style};92m${text}\e[0m
" ;;
        "yellow") printf "\e[${style};93m${text}\e[0m
" ;;
        "blue") printf "\e[${style};94m${text}\e[0m
" ;;
        "magenta") printf "\e[${style};95m${text}\e[0m
" ;;
        "cyan") printf "\e[${style};96m${text}\e[0m
" ;;
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
    curl -sSL $SCRIPT_URL -o $TARGET_PATH
    chmod 755 $TARGET_PATH
    colorized_echo green "Remnawave script installed successfully at $TARGET_PATH"
}

generate_random_string() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex $((${1}/2))
    else
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1} | head -n 1
    fi
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
    IS_TELEGRAM_ENABLED=false
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_ADMIN_ID=""
    NODES_NOTIFY_CHAT_ID=""
    NODES_NOTIFY_THREAD_ID=""
    TELEGRAM_ADMIN_THREAD_ID=""

    if [[ "$enable_telegram" =~ ^[Yy]$ ]]; then
        IS_TELEGRAM_ENABLED=true
        read -p "Enter your Telegram Bot Token: " -r TELEGRAM_BOT_TOKEN
        read -p "Enter your Telegram Admin Chat ID: " -r TELEGRAM_ADMIN_ID
        read -p "Enter your Nodes Notify Chat ID (default: same as Admin ID): " -r NODES_NOTIFY_CHAT_ID
        if [[ -z "$NODES_NOTIFY_CHAT_ID" ]]; then
            NODES_NOTIFY_CHAT_ID="$TELEGRAM_ADMIN_ID"
        fi
        read -p "Enter your Nodes Notify Thread ID (optional): " -r NODES_NOTIFY_THREAD_ID
        read -p "Enter your Admin Thread ID (optional): " -r TELEGRAM_ADMIN_THREAD_ID
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
IS_TELEGRAM_ENABLED=$IS_TELEGRAM_ENABLED
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ADMIN_ID=$TELEGRAM_ADMIN_ID
NODES_NOTIFY_CHAT_ID=$NODES_NOTIFY_CHAT_ID
NODES_NOTIFY_THREAD_ID=$NODES_NOTIFY_THREAD_ID
TELEGRAM_ADMIN_THREAD_ID=$TELEGRAM_ADMIN_THREAD_ID

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

    # Create app-config.json for meta information to handle UTF-8 properly
    colorized_echo blue "Generating app-config.json file"
    cat > "$APP_CONFIG_FILE" <<EOL
{
  "metaTitle": "$META_TITLE",
  "metaDescription": "$META_DESCRIPTION"
}
EOL
    colorized_echo green "App config file saved in $APP_CONFIG_FILE"

    colorized_echo blue "Generating docker-compose.yml file"
    cat > "$COMPOSE_FILE" <<EOL
services:
    remnawave-db:
        image: postgres:17
        container_name: '${APP_NAME}-db'
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
            - ${APP_NAME}-db-data:/var/lib/postgresql/data
        networks:
            - ${APP_NAME}-network
        healthcheck:
            test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
            interval: 3s
            timeout: 10s
            retries: 3

    remnawave:
        image: remnawave/backend:${BACKEND_IMAGE_TAG}
        container_name: '${APP_NAME}'
        hostname: remnawave
        restart: always
        ports:
            - '127.0.0.1:${APP_PORT}:3000'
            - '127.0.0.1:${METRICS_PORT}:3001'
        env_file:
            - .env
        networks:
            - ${APP_NAME}-network
        depends_on:
          ${APP_NAME}-db:
            condition: service_healthy
          ${APP_NAME}-redis:
            condition: service_healthy

    remnawave-subscription-page:
        image: remnawave/subscription-page:latest
        container_name: ${APP_NAME}-subscription-page
        hostname: remnawave-subscription-page
        restart: always
        environment:
            - REMNAWAVE_PLAIN_DOMAIN=remnawave:3003
            - REQUEST_REMNAWAVE_SCHEME=http
            - SUBSCRIPTION_PAGE_PORT=${SUB_PAGE_PORT}
            - CUSTOM_SUB_PREFIX=${CUSTOM_SUB_PREFIX}
            # Using ASCII-only placeholders for environment variables
            - META_TITLE=Remnawave VPN
            - META_DESCRIPTION=The best VPN service
        ports:
            - '127.0.0.1:${SUB_PAGE_PORT}:${SUB_PAGE_PORT}'
        networks:
            - ${APP_NAME}-network
        volumes:
            - ${APP_DIR}/app-config.json:/app/dist/assets/app-config.json

    remnawave-redis:
      image: valkey/valkey:8.0.2-alpine
      container_name: ${APP_NAME}-redis
      hostname: remnawave-redis
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

is_remnawave_installed() {
    if [ -d "$APP_DIR" ]; then
        return 0
    else
        return 1
    fi
}

is_remnawave_up() {
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

install_command() {
    check_running_as_root
    if is_remnawave_installed; then
        colorized_echo red "Remnawave is already installed at $APP_DIR"
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

status_command() {
    if ! is_remnawave_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi

    detect_compose

    if ! is_remnawave_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi

    echo -n "Status: "
    colorized_echo green "Up"
}

logs_command() {
    help() {
        colorized_echo red "Usage: remnawave logs [options]"
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

    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        exit 1
    fi

    detect_compose

    if ! is_remnawave_up; then
        colorized_echo red "Remnawave is not up."
        exit 1
    fi

    if [ "$no_follow" = true ]; then
        show_remnawave_logs
    else
        follow_remnawave_logs
    fi
}

update_command() {
    check_running_as_root
    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        exit 1
    fi

    detect_compose

    update_remnawave_script
    colorized_echo blue "Pulling latest version"
    update_remnawave

    colorized_echo blue "Restarting Remnawave services"
    down_remnawave
    up_remnawave

    colorized_echo blue "Remnawave updated successfully"
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

console_command() {
    if ! is_remnawave_installed; then
        colorized_echo red "Remnawave not installed!"
        exit 1
    fi

    if ! is_remnawave_up; then
        colorized_echo red "Remnawave is not running. Start it first with 'remnawave up'"
        exit 1
    fi

    docker exec -it $APP_NAME remnawave
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
    colorized_echo yellow "  install             $(tput sgr0)– Install/reinstall Remnawave Panel"
    colorized_echo yellow "  update              $(tput sgr0)– Update to latest version"
    colorized_echo yellow "  uninstall           $(tput sgr0)– Uninstall Remnawave Panel"
    colorized_echo yellow "  install-script      $(tput sgr0)– Install Remnawave script"
    colorized_echo yellow "  uninstall-script    $(tput sgr0)– Uninstall Remnawave script"
    colorized_echo yellow "  edit                $(tput sgr0)– Edit docker-compose.yml"
    colorized_echo yellow "  edit-env            $(tput sgr0)– Edit .env file"
    colorized_echo yellow "  console             $(tput sgr0)– Access Remnawave CLI console"

    echo
    colorized_echo cyan "Options for install:"
    colorized_echo yellow "  --dev               $(tput sgr0)– Use remnawave/backend:dev instead of latest"
    colorized_echo yellow "  --name NAME         $(tput sgr0)– Custom installation name (default: remnawave)"

    echo
    colorized_echo cyan "Panel Information:"
    colorized_echo magenta "  Server IP: $NODE_IP"
    echo

    if is_remnawave_installed && [ -f "$ENV_FILE" ]; then
        APP_PORT=$(grep "APP_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        METRICS_PORT=$(grep "METRICS_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        SUB_PAGE_PORT=$(grep -A 10 "remnawave-subscription-page:" "$COMPOSE_FILE" | grep "SUBSCRIPTION_PAGE_PORT=" | grep -o '[0-9]*' | head -1)
        FRONT_END_DOMAIN=$(grep "FRONT_END_DOMAIN=" "$ENV_FILE" | cut -d'=' -f2)
        SUB_PUBLIC_DOMAIN=$(grep "SUB_PUBLIC_DOMAIN=" "$ENV_FILE" | cut -d'=' -f2)

        colorized_echo cyan "Ports:"
        colorized_echo magenta "  App port: $APP_PORT"
        colorized_echo magenta "  Metrics port: $METRICS_PORT"
        colorized_echo magenta "  Subscription page port: $SUB_PAGE_PORT"
        echo
        colorized_echo cyan "Domains:"
        colorized_echo magenta "  Panel domain: $FRONT_END_DOMAIN"
        colorized_echo magenta "  Subscription domain: $SUB_PUBLIC_DOMAIN"
    fi

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
    install-script) install_remnawave_script ;;
    uninstall-script) uninstall_remnawave_script ;;
    edit) edit_command ;;
    edit-env) edit_env_command ;;
    console) console_command ;;
    *) usage ;;
esac

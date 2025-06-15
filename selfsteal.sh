#!/usr/bin/env bash
# Caddy for Reality Selfsteal Installation Script
# This script installs and manages Caddy for Reality traffic masking
# VERSION=1.6

set -e
SCRIPT_VERSION="1.6"
GITHUB_REPO="dignezzz/remnawave-scripts"
UPDATE_URL="https://raw.githubusercontent.com/$GITHUB_REPO/main/selfsteal.sh"
SCRIPT_URL="$UPDATE_URL"  # Алиас для совместимости
CONTAINER_NAME="caddy-selfsteal"
VOLUME_PREFIX="caddy"

# Configuration
APP_NAME="selfsteal"
APP_DIR="/opt/caddy"
CADDY_CONFIG_DIR="$APP_DIR"
HTML_DIR="/opt/caddy/html"

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

# Parse command line arguments
COMMAND=""
if [ $# -gt 0 ]; then
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            echo "Caddy Selfsteal Management Script v$SCRIPT_VERSION"
            exit 0
            ;;
        *)
            COMMAND="$1"
            ;;
    esac
fi
# Fetch IP address
NODE_IP=$(curl -s -4 ifconfig.io 2>/dev/null || echo "127.0.0.1")
if [ -z "$NODE_IP" ] || [ "$NODE_IP" = "" ]; then
    NODE_IP="127.0.0.1"
fi

# Check if running as root
check_running_as_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ This script must be run as root (use sudo)${NC}"
        exit 1
    fi
}

# Check system requirements
check_system_requirements() {
    echo -e "${WHITE}🔍 Checking System Requirements${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
    echo

    local requirements_met=true

    # Check Docker
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker is not installed${NC}"
        echo -e "${GRAY}   Please install Docker first${NC}"
        requirements_met=false
    else
        local docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        echo -e "${GREEN}✅ Docker installed: $docker_version${NC}"
    fi

    # Check Docker Compose
    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker Compose V2 is not available${NC}"
        requirements_met=false
    else
        local compose_version=$(docker compose version --short 2>/dev/null || echo "unknown")
        echo -e "${GREEN}✅ Docker Compose V2: $compose_version${NC}"
    fi

    # Check curl
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}❌ curl is not installed${NC}"
        requirements_met=false
    else
        echo -e "${GREEN}✅ curl is available${NC}"
    fi

    # Check available disk space
    local available_space=$(df / | tail -1 | awk '{print $4}')
    local available_gb=$((available_space / 1024 / 1024))
    
    if [ $available_gb -lt 1 ]; then
        echo -e "${RED}❌ Insufficient disk space: ${available_gb}GB available${NC}"
        requirements_met=false
    else
        echo -e "${GREEN}✅ Sufficient disk space: ${available_gb}GB available${NC}"
    fi

    echo

    if [ "$requirements_met" = false ]; then
        echo -e "${RED}❌ System requirements not met!${NC}"
        return 1
    else
        echo -e "${GREEN}🎉 All system requirements satisfied!${NC}"
        return 0
    fi
}


validate_domain_dns() {
    local domain="$1"
    local server_ip="$2"
    
    echo -e "${WHITE}🔍 Validating DNS Configuration${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
    echo
    
    # Check if domain format is valid
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        echo -e "${RED}❌ Invalid domain format!${NC}"
        echo -e "${GRAY}   Domain should be in format: subdomain.domain.com${NC}"
        return 1
    fi
    
    echo -e "${WHITE}📝 Domain:${NC} $domain"
    echo -e "${WHITE}🖥️  Server IP:${NC} $server_ip"
    echo
    
    # Check if dig is available
    if ! command -v dig >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  Installing dig utility...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update >/dev/null 2>&1
            apt-get install -y dnsutils >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y bind-utils >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y bind-utils >/dev/null 2>&1
        else
            echo -e "${RED}❌ Cannot install dig utility automatically${NC}"
            echo -e "${GRAY}   Please install manually: apt install dnsutils${NC}"
            return 1
        fi
        
        if ! command -v dig >/dev/null 2>&1; then
            echo -e "${RED}❌ Failed to install dig utility${NC}"
            return 1
        fi
        echo -e "${GREEN}✅ dig utility installed${NC}"
        echo
    fi
    
    # Perform DNS lookups
    echo -e "${WHITE}🔍 Checking DNS Records:${NC}"
    echo
    
    # A record check
    echo -e "${GRAY}   Checking A record...${NC}"
    local a_records=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    
    if [ -z "$a_records" ]; then
        echo -e "${RED}   ❌ No A record found${NC}"
        local dns_status="failed"
    else
        echo -e "${GREEN}   ✅ A record found:${NC}"
        while IFS= read -r ip; do
            echo -e "${GRAY}      → $ip${NC}"
            if [ "$ip" = "$server_ip" ]; then
                local dns_match="true"
            fi
        done <<< "$a_records"
    fi
    
    # AAAA record check (IPv6)
    echo -e "${GRAY}   Checking AAAA record...${NC}"
    local aaaa_records=$(dig +short AAAA "$domain" 2>/dev/null)
    
    if [ -z "$aaaa_records" ]; then
        echo -e "${GRAY}   ℹ️  No AAAA record found (IPv6)${NC}"
    else
        echo -e "${GREEN}   ✅ AAAA record found:${NC}"
        while IFS= read -r ip; do
            echo -e "${GRAY}      → $ip${NC}"
        done <<< "$aaaa_records"
    fi
    
    # CNAME record check
    echo -e "${GRAY}   Checking CNAME record...${NC}"
    local cname_record=$(dig +short CNAME "$domain" 2>/dev/null)
    
    if [ -n "$cname_record" ]; then
        echo -e "${GREEN}   ✅ CNAME record found:${NC}"
        echo -e "${GRAY}      → $cname_record${NC}"
        
        # Check CNAME target
        echo -e "${GRAY}   Resolving CNAME target...${NC}"
        local cname_a_records=$(dig +short A "$cname_record" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        
        if [ -n "$cname_a_records" ]; then
            echo -e "${GREEN}   ✅ CNAME target resolved:${NC}"
            while IFS= read -r ip; do
                echo -e "${GRAY}      → $ip${NC}"
                if [ "$ip" = "$server_ip" ]; then
                    local dns_match="true"
                fi
            done <<< "$cname_a_records"
        fi
    else
        echo -e "${GRAY}   ℹ️  No CNAME record found${NC}"
    fi
    
    echo
    
    # DNS propagation check with multiple servers
    echo -e "${WHITE}🌐 Checking DNS Propagation:${NC}"
    echo
    
    local dns_servers=("8.8.8.8" "1.1.1.1" "208.67.222.222" "9.9.9.9")
    local propagation_count=0
    
    for dns_server in "${dns_servers[@]}"; do
        echo -e "${GRAY}   Checking via $dns_server...${NC}"
        local remote_a=$(dig @"$dns_server" +short A "$domain" 2>/dev/null | head -1)
        
        if [ -n "$remote_a" ] && [[ "$remote_a" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if [ "$remote_a" = "$server_ip" ]; then
                echo -e "${GREEN}   ✅ $remote_a (matches server)${NC}"
                ((propagation_count++))
            else
                echo -e "${YELLOW}   ⚠️  $remote_a (different IP)${NC}"
            fi
        else
            echo -e "${RED}   ❌ No response${NC}"
        fi
    done
    
    echo
    
    # Port availability check (только важные для Reality)
    echo -e "${WHITE}🔧 Checking Port Availability:${NC}"
    echo
    
    # Check if port 443 is free (should be free for Xray)
    echo -e "${GRAY}   Checking port 443 availability...${NC}"
    if ss -tlnp | grep -q ":443 "; then
        echo -e "${YELLOW}   ⚠️  Port 443 is occupied${NC}"
        echo -e "${GRAY}      This port will be needed for Xray Reality${NC}"
        local port_info=$(ss -tlnp | grep ":443 " | head -1 | awk '{print $1, $4}')
        echo -e "${GRAY}      Current: $port_info${NC}"
    else
        echo -e "${GREEN}   ✅ Port 443 is available for Xray${NC}"
    fi
    
    # Check if port 80 is free (will be used by Caddy)
    echo -e "${GRAY}   Checking port 80 availability...${NC}"
    if ss -tlnp | grep -q ":80 "; then
        echo -e "${YELLOW}   ⚠️  Port 80 is occupied${NC}"
        echo -e "${GRAY}      This port will be used by Caddy for HTTP redirects${NC}"
        local port80_occupied=$(ss -tlnp | grep ":80 " | head -1)
        echo -e "${GRAY}      Current: $port80_occupied${NC}"
    else
        echo -e "${GREEN}   ✅ Port 80 is available for Caddy${NC}"
    fi
    
    echo
    
    # Summary and recommendations
    echo -e "${WHITE}📋 DNS Validation Summary:${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 35))${NC}"
    
    if [ "$dns_match" = "true" ]; then
        echo -e "${GREEN}✅ Domain correctly points to this server${NC}"
        echo -e "${GREEN}✅ DNS propagation: $propagation_count/4 servers${NC}"
        
        if [ "$propagation_count" -ge 2 ]; then
            echo -e "${GREEN}✅ DNS propagation looks good${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️  DNS propagation is limited${NC}"
            echo -e "${GRAY}   This might cause issues if needed${NC}"
        fi
    else
        echo -e "${RED}❌ Domain does not point to this server${NC}"
        echo -e "${GRAY}   Expected IP: $server_ip${NC}"
        
        if [ -n "$a_records" ]; then
            echo -e "${GRAY}   Current IPs: $(echo "$a_records" | tr '\n' ' ')${NC}"
        fi
    fi
    
    echo
    echo -e "${WHITE}🔧 Setup Requirements for Reality:${NC}"
    echo -e "${GRAY}   • Domain must point to this server ✓${NC}"
    echo -e "${GRAY}   • Port 443 must be free for Xray ✓${NC}"
    echo -e "${GRAY}   • Port 80 will be used by Caddy for redirects${NC}"
    echo -e "${GRAY}   • Caddy will serve content on internal port (9443)${NC}"
    echo -e "${GRAY}   • Configure Xray Reality AFTER Caddy installation${NC}"
    
    echo
    
    # Ask user decision
    if [ "$dns_match" = "true" ] && [ "$propagation_count" -ge 2 ]; then
        echo -e "${GREEN}🎉 DNS validation passed! Ready for installation.${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️  DNS validation has warnings.${NC}"
        echo
        read -p "Do you want to continue anyway? [y/N]: " -r continue_anyway
        
        if [[ $continue_anyway =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}⚠️  Continuing with installation despite DNS issues...${NC}"
            return 0
        else
            echo -e "${GRAY}Installation cancelled. Please fix DNS configuration first.${NC}"
            return 1
        fi
    fi
}

# Install function
install_command() {
    check_running_as_root
    
    clear
    echo -e "${WHITE}🚀 Caddy for Reality Selfsteal Installation${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
    echo

    # Check if already installed
    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}⚠️  Caddy installation already exists at $APP_DIR${NC}"
        echo
        read -p "Do you want to reinstall? [y/N]: " -r confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            echo -e "${GRAY}Installation cancelled${NC}"
            return 0
        fi
        echo
        echo -e "${YELLOW}🗑️  Removing existing installation...${NC}"
        stop_services
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ Existing installation removed${NC}"
        echo
    fi

    # Check system requirements
    if ! check_system_requirements; then
        return 1
    fi

    # Collect configuration
    echo -e "${WHITE}📝 Configuration Setup${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 30))${NC}"
    echo

    # Domain configuration
    echo -e "${WHITE}🌐 Domain Configuration${NC}"
    echo -e "${GRAY}This domain should match your Xray Reality configuration (realitySettings.serverNames)${NC}"
    echo
    
    local domain=""
    local skip_dns_check=false
    
    while [ -z "$domain" ]; do
        read -p "Enter your domain (e.g., reality.example.com): " domain
        if [ -z "$domain" ]; then
            echo -e "${RED}❌ Domain cannot be empty!${NC}"
            continue
        fi
        
        echo
        echo -e "${WHITE}🔍 DNS Validation Options:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Validate DNS configuration (recommended)${NC}"
        echo -e "   ${WHITE}2)${NC} ${GRAY}Skip DNS validation (for testing/development)${NC}"
        echo
        
        read -p "Select option [1-2]: " dns_choice
        
        case "$dns_choice" in
            1)
                echo
                if ! validate_domain_dns "$domain" "$NODE_IP"; then
                    echo
                    read -p "Try a different domain? [Y/n]: " -r try_again
                    if [[ ! $try_again =~ ^[Nn]$ ]]; then
                        domain=""
                        continue
                    else
                        return 1
                    fi
                fi
                ;;
            2)
                echo -e "${YELLOW}⚠️  Skipping DNS validation...${NC}"
                skip_dns_check=true
                ;;
            *)
                echo -e "${RED}❌ Invalid option!${NC}"
                domain=""
                continue
                ;;
        esac
    done

    # Port configuration
    echo
    echo -e "${WHITE}🔌 Port Configuration${NC}"
    echo -e "${GRAY}This port should match your Xray Reality configuration (realitySettings.dest)${NC}"
    echo
    
    local port="9443"
    read -p "Enter Caddy HTTPS port (default: 9443): " input_port
    if [ -n "$input_port" ]; then
        port="$input_port"
    fi

    # Validate port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}❌ Invalid port number!${NC}"
        return 1
    fi

    # Summary
    echo
    echo -e "${WHITE}📋 Installation Summary${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 30))${NC}"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "Domain:" "$domain"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "HTTPS Port:" "$port"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "Installation Path:" "$APP_DIR"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "HTML Path:" "$HTML_DIR"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "Server IP:" "$NODE_IP"
    
    if [ "$skip_dns_check" = true ]; then
        printf "   ${WHITE}%-20s${NC} ${YELLOW}%s${NC}\n" "DNS Validation:" "SKIPPED"
    else
        printf "   ${WHITE}%-20s${NC} ${GREEN}%s${NC}\n" "DNS Validation:" "PASSED"
    fi
    
    echo

    read -p "Proceed with installation? [Y/n]: " -r confirm
    if [[ $confirm =~ ^[Nn]$ ]]; then
        echo -e "${GRAY}Installation cancelled${NC}"
        return 0
    fi

    # Create directories
    echo
    echo -e "${WHITE}📁 Creating Directory Structure${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
    
    mkdir -p "$APP_DIR"
    mkdir -p "$HTML_DIR"
    mkdir -p "$APP_DIR/logs"
    
    echo -e "${GREEN}✅ Directories created${NC}"

    # Create .env file
    echo
    echo -e "${WHITE}⚙️  Creating Configuration Files${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"

    cat > "$APP_DIR/.env" << EOF
# Caddy for Reality Selfsteal Configuration
# Domain Configuration
SELF_STEAL_DOMAIN=$domain
SELF_STEAL_PORT=$port

# Generated on $(date)
# Server IP: $NODE_IP
EOF

    echo -e "${GREEN}✅ .env file created${NC}"

    # Create docker-compose.yml
    cat > "$APP_DIR/docker-compose.yml" << EOF
services:
  caddy:
    image: caddy:2.9.1
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - $HTML_DIR:/var/www/html
      - ./logs:/var/log/caddy
      - ${VOLUME_PREFIX}_data:/data
      - ${VOLUME_PREFIX}_config:/config
    env_file:
      - .env
    network_mode: "host"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  ${VOLUME_PREFIX}_data:
  ${VOLUME_PREFIX}_config:
EOF

    echo -e "${GREEN}✅ docker-compose.yml created${NC}"

    # Create Caddyfile
    cat > "$APP_DIR/Caddyfile" << 'EOF'
{
    https_port {$SELF_STEAL_PORT}
    default_bind 127.0.0.1
    servers {
        listener_wrappers {
            proxy_protocol {
                allow 127.0.0.1/32
            }
            tls
        }
    }
    auto_https disable_redirects
    log {
        output file /var/log/caddy/access.log {
            roll_size 10MB
            roll_keep 5
            roll_keep_for 720h
            roll_compression gzip
        }
        level ERROR
        format json 
    }
}

http://{$SELF_STEAL_DOMAIN} {
    bind 0.0.0.0
    redir https://{$SELF_STEAL_DOMAIN}{uri} permanent
    log {
        output file /var/log/caddy/redirect.log {
            roll_size 5MB
            roll_keep 3
            roll_keep_for 168h
        }
    }
}

https://{$SELF_STEAL_DOMAIN} {
    root * /var/www/html
    try_files {path} /index.html
    file_server
    log {
        output file /var/log/caddy/access.log {
            roll_size 10MB
            roll_keep 5
            roll_keep_for 720h
            roll_compression gzip
        }
        level ERROR
    }
}

:{$SELF_STEAL_PORT} {
    tls internal
    respond 204
    log off
}

:80 {
    bind 0.0.0.0
    respond 204
    log off
}
EOF

    echo -e "${GREEN}✅ Caddyfile created${NC}"

    # Create default HTML content
    create_default_html

    # Install management script
    install_management_script

    # Start services
    echo
    echo -e "${WHITE}🚀 Starting Caddy Services${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 30))${NC}"
    
    cd "$APP_DIR"
    if docker compose up -d; then
        echo -e "${GREEN}✅ Caddy services started successfully${NC}"
    else
        echo -e "${RED}❌ Failed to start Caddy services${NC}"
        return 1
    fi

    # Installation complete
    echo
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
    echo -e "${WHITE}🎉 Installation Completed Successfully!${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
    echo
    
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "Domain:" "$domain"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "HTTPS Port:" "$port"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "Installation Path:" "$APP_DIR"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "HTML Content:" "$HTML_DIR"
    printf "   ${WHITE}%-20s${NC} ${GRAY}%s${NC}\n" "Management Command:" "$APP_NAME"
    
    echo
    echo -e "${WHITE}📋 Next Steps:${NC}"
    echo -e "${GRAY}   • Configure your Xray Reality with:${NC}"
    echo -e "${GRAY}     - serverNames: [\"$domain\"]${NC}"
    echo -e "${GRAY}     - dest: \"127.0.0.1:$port\"${NC}"
    echo -e "${GRAY}   • Customize HTML content in: $HTML_DIR${NC}"
    echo -e "${GRAY}   • Check status: sudo $APP_NAME status${NC}"
    echo -e "${GRAY}   • View logs: sudo $APP_NAME logs${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
}


# Добавляем после функции create_default_html()

# Template management functions
show_template_options() {
    echo -e "${WHITE}🎨 Website Template Options${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 35))${NC}"
    echo
    echo -e "${WHITE}Select template type:${NC}"
    echo -e "   ${WHITE}1)${NC} ${CYAN}💼 Corporate Business${NC}"
    echo -e "   ${WHITE}2)${NC} ${CYAN}🏢 Technology Company${NC}"
    echo -e "   ${WHITE}3)${NC} ${CYAN}🌟 Modern Portfolio${NC}"
    echo -e "   ${WHITE}4)${NC} ${CYAN}🔧 Service Platform${NC}"
    echo -e "   ${WHITE}5)${NC} ${CYAN}📊 Data Analytics${NC}"
    echo -e "   ${WHITE}6)${NC} ${CYAN}🎲 Random Generated${NC}"
    echo -e "   ${WHITE}7)${NC} ${GRAY}📄 View Current Template${NC}"
    echo -e "   ${WHITE}8)${NC} ${GRAY}📝 Keep Current Template${NC}"
    echo
    echo -e "   ${GRAY}0)${NC} ${GRAY}⬅️  Cancel${NC}"
    echo
}

show_current_template_info() {
    echo -e "${WHITE}📄 Current Template Information${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 35))${NC}"
    echo
    
    if [ ! -d "$HTML_DIR" ] || [ ! "$(ls -A "$HTML_DIR" 2>/dev/null)" ]; then
        echo -e "${GRAY}   No template installed${NC}"
        return
    fi
    
    # Проверить наличие основных файлов
    if [ -f "$HTML_DIR/index.html" ]; then
        local title=$(grep -o '<title>[^<]*</title>' "$HTML_DIR/index.html" 2>/dev/null | sed 's/<title>\|<\/title>//g' | head -1)
        local meta_comment=$(grep -o '<!-- [a-f0-9]\{16\} -->' "$HTML_DIR/index.html" 2>/dev/null | head -1)
        local file_count=$(find "$HTML_DIR" -type f | wc -l)
        local total_size=$(du -sh "$HTML_DIR" 2>/dev/null | cut -f1)
        
        echo -e "${WHITE}   Title:${NC} ${GRAY}${title:-"Unknown"}${NC}"
        echo -e "${WHITE}   Files:${NC} ${GRAY}$file_count${NC}"
        echo -e "${WHITE}   Size:${NC} ${GRAY}$total_size${NC}"
        echo -e "${WHITE}   Path:${NC} ${GRAY}$HTML_DIR${NC}"
        
        if [ -n "$meta_comment" ]; then
            echo -e "${WHITE}   ID:${NC} ${GRAY}$meta_comment${NC}"
        fi
        
        # Показать последнее изменение
        local last_modified=$(stat -c %y "$HTML_DIR/index.html" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$last_modified" ]; then
            echo -e "${WHITE}   Modified:${NC} ${GRAY}$last_modified${NC}"
        fi
    else
        echo -e "${GRAY}   Custom or unknown template${NC}"
        echo -e "${WHITE}   Path:${NC} ${GRAY}$HTML_DIR${NC}"
    fi
    echo
}

generate_builtin_template() {
    local template_type="$1"
    
    echo -e "${WHITE}🎨 Generating Built-in Template${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
    echo
    
    # Generate random data
    local random_data
    generate_random_data random_data
    
    # Get domain from config
    local domain="localhost"
    if [ -f "$APP_DIR/.env" ]; then
        domain=$(grep "SELF_STEAL_DOMAIN=" "$APP_DIR/.env" | cut -d'=' -f2)
    fi
    
    # Create backup if content exists
    if [ -d "$HTML_DIR" ] && [ "$(ls -A "$HTML_DIR" 2>/dev/null)" ]; then
        local backup_dir="/tmp/caddy-html-backup-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        if cp -a "$HTML_DIR"/* "$backup_dir/" 2>/dev/null; then
            echo -e "${GRAY}💾 Backup created: $backup_dir${NC}"
            echo -e "${GRAY}   Use 'cp -a $backup_dir/* $HTML_DIR/' to restore${NC}"
        else
            echo -e "${YELLOW}⚠️  Could not create backup (continuing anyway)${NC}"
        fi
    fi
    
    # Clear and create directory
    mkdir -p "$HTML_DIR"
    rm -rf "$HTML_DIR"/*
    
    case "$template_type" in
        "corporate"|"1")
            echo -e "${CYAN}💼 Generating Corporate Business template${NC}"
            generate_corporate_template "$domain" random_data
            ;;
        "tech"|"2")
            echo -e "${CYAN}🏢 Generating Technology Company template${NC}"
            generate_tech_template "$domain" random_data
            ;;
        "portfolio"|"3")
            echo -e "${CYAN}🌟 Generating Modern Portfolio template${NC}"
            generate_portfolio_template "$domain" random_data
            ;;
        "service"|"4")
            echo -e "${CYAN}🔧 Generating Service Platform template${NC}"
            generate_service_template "$domain" random_data
            ;;
        "analytics"|"5")
            echo -e "${CYAN}📊 Generating Data Analytics template${NC}"
            generate_analytics_template "$domain" random_data
            ;;
        "random"|"6"|*)
            local templates=("corporate" "tech" "portfolio" "service" "analytics")
            local random_template=${templates[$RANDOM % ${#templates[@]}]}
            echo -e "${CYAN}🎲 Generating Random template: $random_template${NC}"
            generate_builtin_template "$random_template"
            return
            ;;
    esac
    
    # Set proper permissions
    chown -R www-data:www-data "$HTML_DIR" 2>/dev/null || true
    chmod -R 644 "$HTML_DIR" 2>/dev/null || true
    find "$HTML_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
    
    echo -e "${GREEN}✅ Template generated successfully${NC}"
    echo -e "${GRAY}   Type: $template_type${NC}"
    echo -e "${GRAY}   Location: $HTML_DIR${NC}"
    echo -e "${GRAY}   Customized with random identifiers${NC}"
    
    return 0
}

# Corporate Business Template
generate_corporate_template() {
    local domain="$1"
    local -n data_ref=$2
    
    cat > "$HTML_DIR/index.html" << EOF
<!DOCTYPE html>
<html lang="en" class="${data_ref[class]}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="${data_ref[meta_name]}" content="${data_ref[meta_id]}">
    <title>${data_ref[title]} - Corporate Solutions</title>
    <!-- ${data_ref[comment]} -->
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <header class="header">
        <nav class="navbar">
            <div class="nav-brand">${data_ref[title]}</div>
            <ul class="nav-menu">
                <li><a href="#home">Home</a></li>
                <li><a href="#about">About</a></li>
                <li><a href="#services">Services</a></li>
                <li><a href="#contact">Contact</a></li>
            </ul>
        </nav>
    </header>

    <main>
        <section id="home" class="hero">
            <div class="hero-content">
                <h1>Excellence in Business Solutions</h1>
                <p>Leading the industry with innovative approaches and proven results</p>
                <div class="hero-stats">
                    <div class="stat">
                        <span class="stat-number">500+</span>
                        <span class="stat-label">Clients</span>
                    </div>
                    <div class="stat">
                        <span class="stat-number">15+</span>
                        <span class="stat-label">Years</span>
                    </div>
                    <div class="stat">
                        <span class="stat-number">98%</span>
                        <span class="stat-label">Success</span>
                    </div>
                </div>
            </div>
        </section>

        <section id="about" class="about">
            <div class="container">
                <h2>About Our Company</h2>
                <div class="about-grid">
                    <div class="about-text">
                        <p>We are a leading provider of comprehensive business solutions, dedicated to helping organizations achieve their strategic objectives through innovative technology and expert consultation.</p>
                        <div class="features">
                            <div class="feature">
                                <div class="feature-icon">🎯</div>
                                <h3>Strategic Focus</h3>
                                <p>Targeted solutions for maximum impact</p>
                            </div>
                            <div class="feature">
                                <div class="feature-icon">⚡</div>
                                <h3>Fast Delivery</h3>
                                <p>Rapid implementation and deployment</p>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </section>

        <section id="services" class="services">
            <div class="container">
                <h2>Our Services</h2>
                <div class="services-grid">
                    <div class="service-card">
                        <div class="service-icon">💼</div>
                        <h3>Business Consulting</h3>
                        <p>Strategic planning and operational optimization</p>
                    </div>
                    <div class="service-card">
                        <div class="service-icon">🔧</div>
                        <h3>Technical Solutions</h3>
                        <p>Advanced technology implementation</p>
                    </div>
                    <div class="service-card">
                        <div class="service-icon">📈</div>
                        <h3>Growth Strategy</h3>
                        <p>Scalable business development plans</p>
                    </div>
                </div>
            </div>
        </section>
    </main>

    <footer class="footer">
        <div class="container">
            <div class="footer-content">
                <div class="footer-section">
                    <h4>${data_ref[title]}</h4>
                    <p>Professional business solutions for modern enterprises</p>
                </div>
                <div class="footer-section">
                    <h4>Contact</h4>
                    <p>Domain: $domain</p>
                    <p>Status: Online</p>
                </div>
            </div>
            <div class="footer-bottom">
                <p>&copy; 2024 ${data_ref[footer]}. All rights reserved.</p>
            </div>
        </div>
    </footer>
</body>
</html>
EOF

    generate_corporate_css "${data_ref[class]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}" "${data_ref[comment]}"
    generate_common_files "$domain" "${data_ref[title]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}"
}

# Technology Company Template
generate_tech_template() {
    local domain="$1"
    local -n data_ref=$2
    
    cat > "$HTML_DIR/index.html" << EOF
<!DOCTYPE html>
<html lang="en" class="${data_ref[class]}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="${data_ref[meta_name]}" content="${data_ref[meta_id]}">
    <title>${data_ref[title]} - Technology Innovation</title>
    <!-- ${data_ref[comment]} -->
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <div class="tech-grid-bg"></div>
    
    <header class="header">
        <nav class="navbar">
            <div class="nav-brand">
                <span class="brand-icon">⚡</span>
                ${data_ref[title]}
            </div>
            <ul class="nav-menu">
                <li><a href="#home">Platform</a></li>
                <li><a href="#features">Features</a></li>
                <li><a href="#api">API</a></li>
                <li><a href="#docs">Docs</a></li>
            </ul>
        </nav>
    </header>

    <main>
        <section id="home" class="hero-tech">
            <div class="hero-content">
                <div class="tech-badge">Advanced Technology</div>
                <h1>Next-Generation Platform</h1>
                <p>Powerful, scalable, and secure technology solutions for modern applications</p>
                <div class="tech-features">
                    <div class="tech-feature">
                        <span class="feature-icon">🚀</span>
                        <span>High Performance</span>
                    </div>
                    <div class="tech-feature">
                        <span class="feature-icon">🔒</span>
                        <span>Enterprise Security</span>
                    </div>
                    <div class="tech-feature">
                        <span class="feature-icon">⚡</span>
                        <span>Real-time Processing</span>
                    </div>
                </div>
            </div>
        </section>

        <section id="features" class="features-section">
            <div class="container">
                <h2>Platform Capabilities</h2>
                <div class="features-grid">
                    <div class="feature-card">
                        <div class="card-header">
                            <span class="card-icon">🔧</span>
                            <h3>Developer Tools</h3>
                        </div>
                        <p>Comprehensive SDK and API documentation</p>
                        <div class="feature-stats">
                            <span>99.9% Uptime</span>
                        </div>
                    </div>
                    <div class="feature-card">
                        <div class="card-header">
                            <span class="card-icon">📊</span>
                            <h3>Analytics</h3>
                        </div>
                        <p>Real-time monitoring and performance insights</p>
                        <div class="feature-stats">
                            <span>Real-time Data</span>
                        </div>
                    </div>
                    <div class="feature-card">
                        <div class="card-header">
                            <span class="card-icon">🌐</span>
                            <h3>Global CDN</h3>
                        </div>
                        <p>Worldwide content delivery network</p>
                        <div class="feature-stats">
                            <span>150+ Locations</span>
                        </div>
                    </div>
                </div>
            </div>
        </section>

        <section id="api" class="api-section">
            <div class="container">
                <h2>API Integration</h2>
                <div class="api-demo">
                    <div class="code-block">
                        <div class="code-header">
                            <span>REST API</span>
                            <span class="status-indicator"></span>
                        </div>
                        <pre><code>{
  "status": "active",
  "version": "2.0",
  "endpoints": {
    "data": "/api/v2/data",
    "auth": "/api/v2/auth",
    "status": "/api/v2/status"
  }
}</code></pre>
                    </div>
                </div>
            </div>
        </section>
    </main>

    <footer class="footer">
        <div class="container">
            <div class="footer-grid">
                <div class="footer-section">
                    <h4>${data_ref[title]}</h4>
                    <p>Advanced technology platform</p>
                </div>
                <div class="footer-section">
                    <h4>System Status</h4>
                    <div class="status-grid">
                        <div class="status-item">
                            <span class="status-dot active"></span>
                            <span>API: Online</span>
                        </div>
                        <div class="status-item">
                            <span class="status-dot active"></span>
                            <span>CDN: Active</span>
                        </div>
                    </div>
                </div>
            </div>
            <div class="footer-bottom">
                <p>${data_ref[footer]} | $domain</p>
            </div>
        </div>
    </footer>
</body>
</html>
EOF

    generate_tech_css "${data_ref[class]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}" "${data_ref[comment]}"
    generate_common_files "$domain" "${data_ref[title]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}"
}

# Service Platform Template
generate_service_template() {
    local domain="$1"
    local -n data_ref=$2
    
    cat > "$HTML_DIR/index.html" << EOF
<!DOCTYPE html>
<html lang="en" class="${data_ref[class]}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="${data_ref[meta_name]}" content="${data_ref[meta_id]}">
    <title>${data_ref[title]} - Service Platform</title>
    <!-- ${data_ref[comment]} -->
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <header class="header">
        <nav class="navbar">
            <div class="nav-brand">
                <span class="service-icon">🔧</span>
                ${data_ref[title]}
            </div>
            <div class="nav-status">
                <span class="status-dot"></span>
                <span>All Systems Operational</span>
            </div>
        </nav>
    </header>

    <main>
        <section class="hero-service">
            <div class="service-dashboard">
                <h1>Service Management Platform</h1>
                <p>Comprehensive service monitoring and management solution</p>
                
                <div class="dashboard-grid">
                    <div class="dashboard-card">
                        <div class="card-icon">📊</div>
                        <div class="card-content">
                            <h3>System Health</h3>
                            <div class="metric">98.7%</div>
                            <span class="metric-label">Uptime</span>
                        </div>
                    </div>
                    <div class="dashboard-card">
                        <div class="card-icon">⚡</div>
                        <div class="card-content">
                            <h3>Performance</h3>
                            <div class="metric">45ms</div>
                            <span class="metric-label">Response Time</span>
                        </div>
                    </div>
                    <div class="dashboard-card">
                        <div class="card-icon">🔒</div>
                        <div class="card-content">
                            <h3>Security</h3>
                            <div class="metric">Active</div>
                            <span class="metric-label">Protection</span>
                        </div>
                    </div>
                </div>
            </div>
        </section>

        <section class="services-overview">
            <div class="container">
                <h2>Service Components</h2>
                <div class="components-list">
                    <div class="component">
                        <div class="component-status active"></div>
                        <div class="component-info">
                            <h3>Web Service</h3>
                            <p>HTTP/HTTPS request handling</p>
                        </div>
                        <div class="component-metrics">
                            <span>Online</span>
                        </div>
                    </div>
                    <div class="component">
                        <div class="component-status active"></div>
                        <div class="component-info">
                            <h3>Load Balancer</h3>
                            <p>Traffic distribution and routing</p>
                        </div>
                        <div class="component-metrics">
                            <span>Healthy</span>
                        </div>
                    </div>
                    <div class="component">
                        <div class="component-status active"></div>
                        <div class="component-info">
                            <h3>Security Layer</h3>
                            <p>DDoS protection and filtering</p>
                        </div>
                        <div class="component-metrics">
                            <span>Protected</span>
                        </div>
                    </div>
                </div>
            </div>
        </section>
    </main>

    <footer class="footer">
        <div class="container">
            <div class="footer-info">
                <h4>${data_ref[title]} Service Platform</h4>
                <div class="service-details">
                    <div class="detail-item">
                        <span class="detail-label">Domain:</span>
                        <span>$domain</span>
                    </div>
                    <div class="detail-item">
                        <span class="detail-label">Status:</span>
                        <span class="status-active">Operational</span>
                    </div>
                    <div class="detail-item">
                        <span class="detail-label">Version:</span>
                        <span>2.0.1</span>
                    </div>
                </div>
            </div>
            <div class="footer-bottom">
                <p>${data_ref[footer]}</p>
            </div>
        </div>
    </footer>
</body>
</html>
EOF

    generate_service_css "${data_ref[class]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}" "${data_ref[comment]}"
    generate_common_files "$domain" "${data_ref[title]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}"
}

# CSS Generators for each template type
generate_corporate_css() {
    local class_name="$1"
    local primary_color="$2"
    local accent_color="$3"
    local comment="$4"
    
    cat > "$HTML_DIR/style.css" << EOF
/* Corporate Business Template - $comment */
:root {
    --primary: $primary_color;
    --accent: $accent_color;
    --text-dark: #2c3e50;
    --text-light: #7f8c8d;
    --bg-light: #f8f9fa;
    --border: #e9ecef;
}

.$class_name {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    line-height: 1.6;
    color: var(--text-dark);
}

* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

.header {
    background: white;
    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 1000;
}

.navbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem 2rem;
    max-width: 1200px;
    margin: 0 auto;
}

.nav-brand {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--primary);
}

.nav-menu {
    display: flex;
    list-style: none;
    gap: 2rem;
}

.nav-menu a {
    text-decoration: none;
    color: var(--text-dark);
    font-weight: 500;
    transition: color 0.3s ease;
}

.nav-menu a:hover {
    color: var(--primary);
}

main {
    margin-top: 80px;
}

.hero {
    background: linear-gradient(135deg, var(--primary) 0%, var(--accent) 100%);
    color: white;
    padding: 5rem 2rem;
    text-align: center;
}

.hero h1 {
    font-size: 3rem;
    margin-bottom: 1rem;
    font-weight: 700;
}

.hero p {
    font-size: 1.2rem;
    margin-bottom: 3rem;
    opacity: 0.9;
}

.hero-stats {
    display: flex;
    justify-content: center;
    gap: 3rem;
    flex-wrap: wrap;
}

.stat {
    text-align: center;
}

.stat-number {
    display: block;
    font-size: 2.5rem;
    font-weight: 700;
    margin-bottom: 0.5rem;
}

.stat-label {
    font-size: 0.9rem;
    opacity: 0.8;
}

.container {
    max-width: 1200px;
    margin: 0 auto;
    padding: 0 2rem;
}

.about, .services {
    padding: 5rem 0;
}

.about h2, .services h2 {
    text-align: center;
    font-size: 2.5rem;
    margin-bottom: 3rem;
    color: var(--text-dark);
}

.features {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    gap: 2rem;
    margin-top: 3rem;
}

.feature {
    text-align: center;
    padding: 2rem;
    background: white;
    border-radius: 10px;
    box-shadow: 0 5px 15px rgba(0,0,0,0.1);
    transition: transform 0.3s ease;
}

.feature:hover {
    transform: translateY(-5px);
}

.feature-icon {
    font-size: 3rem;
    margin-bottom: 1rem;
}

.services {
    background: var(--bg-light);
}

.services-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 2rem;
}

.service-card {
    background: white;
    padding: 2rem;
    border-radius: 10px;
    box-shadow: 0 5px 15px rgba(0,0,0,0.08);
    text-align: center;
    transition: all 0.3s ease;
}

.service-card:hover {
    transform: translateY(-5px);
    box-shadow: 0 10px 25px rgba(0,0,0,0.15);
}

.service-icon {
    font-size: 3rem;
    margin-bottom: 1rem;
}

.footer {
    background: var(--text-dark);
    color: white;
    padding: 3rem 0 1rem;
}

.footer-content {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    gap: 2rem;
    margin-bottom: 2rem;
}

.footer-bottom {
    text-align: center;
    padding-top: 2rem;
    border-top: 1px solid rgba(255,255,255,0.1);
    opacity: 0.7;
}

@media (max-width: 768px) {
    .hero h1 {
        font-size: 2rem;
    }
    
    .hero-stats {
        gap: 1.5rem;
    }
    
    .navbar {
        padding: 1rem;
    }
    
    .nav-menu {
        gap: 1rem;
    }
}
EOF
}

generate_tech_css() {
    local class_name="$1"
    local primary_color="$2"
    local accent_color="$3"
    local comment="$4"
    
    cat > "$HTML_DIR/style.css" << EOF
/* Technology Template - $comment */
:root {
    --primary: $primary_color;
    --accent: $accent_color;
    --dark: #1a1a1a;
    --gray: #2d2d2d;
    --light-gray: #f5f5f5;
    --border: #333;
}

.$class_name {
    font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace;
    background: var(--dark);
    color: white;
    min-height: 100vh;
}

* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

.tech-grid-bg {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-image: 
        linear-gradient(rgba(255,255,255,0.03) 1px, transparent 1px),
        linear-gradient(90deg, rgba(255,255,255,0.03) 1px, transparent 1px);
    background-size: 20px 20px;
    z-index: -1;
}

.header {
    background: rgba(0,0,0,0.9);
    backdrop-filter: blur(10px);
    border-bottom: 1px solid var(--border);
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 1000;
}

.navbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem 2rem;
    max-width: 1200px;
    margin: 0 auto;
}

.nav-brand {
    display: flex;
    align-items: center;
    font-size: 1.2rem;
    font-weight: 600;
    color: var(--primary);
}

.brand-icon {
    margin-right: 0.5rem;
    font-size: 1.5rem;
}

.nav-menu {
    display: flex;
    list-style: none;
    gap: 2rem;
}

.nav-menu a {
    text-decoration: none;
    color: #ccc;
    font-weight: 500;
    transition: color 0.3s ease;
    padding: 0.5rem 1rem;
    border-radius: 5px;
}

.nav-menu a:hover {
    color: var(--primary);
    background: rgba(255,255,255,0.05);
}

main {
    margin-top: 80px;
}

.hero-tech {
    padding: 5rem 2rem;
    text-align: center;
    background: linear-gradient(135deg, var(--dark) 0%, var(--gray) 100%);
}

.tech-badge {
    display: inline-block;
    background: var(--primary);
    color: white;
    padding: 0.5rem 1rem;
    border-radius: 20px;
    font-size: 0.8rem;
    font-weight: 600;
    margin-bottom: 2rem;
    text-transform: uppercase;
    letter-spacing: 1px;
}

.hero-tech h1 {
    font-size: 3.5rem;
    margin-bottom: 1rem;
    background: linear-gradient(45deg, var(--primary), var(--accent));
    background-clip: text;
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
}

.tech-features {
    display: flex;
    justify-content: center;
    gap: 2rem;
    margin-top: 3rem;
    flex-wrap: wrap;
}

.tech-feature {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 1rem 1.5rem;
    background: rgba(255,255,255,0.05);
    border-radius: 8px;
    border: 1px solid var(--border);
}

.container {
    max-width: 1200px;
    margin: 0 auto;
    padding: 0 2rem;
}

.features-section {
    padding: 5rem 0;
    background: var(--gray);
}

.features-section h2 {
    text-align: center;
    font-size: 2.5rem;
    margin-bottom: 3rem;
}

.features-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 2rem;
}

.feature-card {
    background: var(--dark);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 2rem;
    transition: all 0.3s ease;
}

.feature-card:hover {
    border-color: var(--primary);
    transform: translateY(-5px);
}

.card-header {
    display: flex;
    align-items: center;
    gap: 1rem;
    margin-bottom: 1rem;
}

.card-icon {
    font-size: 2rem;
}

.feature-stats {
    margin-top: 1rem;
    padding-top: 1rem;
    border-top: 1px solid var(--border);
    font-size: 0.9rem;
    color: var(--primary);
}

.api-section {
    padding: 5rem 0;
}

.api-section h2 {
    text-align: center;
    font-size: 2.5rem;
    margin-bottom: 3rem;
}

.code-block {
    background: #000;
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
}

.code-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem;
    background: var(--gray);
    border-bottom: 1px solid var(--border);
}

.status-indicator {
    width: 10px;
    height: 10px;
    background: #4CAF50;
    border-radius: 50%;
    animation: pulse 2s infinite;
}

pre {
    padding: 2rem;
    overflow-x: auto;
}

code {
    color: #f8f8f2;
    font-family: 'SF Mono', Monaco, monospace;
}

.footer {
    background: #000;
    padding: 3rem 0 1rem;
    border-top: 1px solid var(--border);
}

.footer-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    gap: 2rem;
    margin-bottom: 2rem;
}

.status-grid {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.status-item {
    display: flex;
    align-items: center;
    gap: 0.5rem;
}

.status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #4CAF50;
}

.status-dot.active {
    animation: pulse 2s infinite;
}

@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
}

@media (max-width: 768px) {
    .hero-tech h1 {
        font-size: 2.5rem;
    }
    
    .tech-features {
        gap: 1rem;
    }
    
    .tech-feature {
        padding: 0.75rem 1rem;
    }
}
EOF
}

generate_service_css() {
    local class_name="$1"
    local primary_color="$2"
    local accent_color="$3"
    local comment="$4"
    
    cat > "$HTML_DIR/style.css" << EOF
/* Service Platform Template - $comment */
:root {
    --primary: $primary_color;
    --accent: $accent_color;
    --success: #28a745;
    --warning: #ffc107;
    --danger: #dc3545;
    --bg: #f8f9fa;
    --card-bg: white;
    --text: #343a40;
    --border: #dee2e6;
}

.$class_name {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
}

* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

.header {
    background: var(--card-bg);
    border-bottom: 2px solid var(--border);
    box-shadow: 0 2px 4px rgba(0,0,0,0.05);
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 1000;
}

.navbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem 2rem;
    max-width: 1200px;
    margin: 0 auto;
}

.nav-brand {
    display: flex;
    align-items: center;
    font-size: 1.3rem;
    font-weight: 600;
    color: var(--primary);
}

.service-icon {
    margin-right: 0.5rem;
    font-size: 1.5rem;
}

.nav-status {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.9rem;
    color: var(--success);
}

.status-dot {
    width: 8px;
    height: 8px;
    background: var(--success);
    border-radius: 50%;
    animation: pulse 2s infinite;
}

main {
    margin-top: 80px;
}

.hero-service {
    padding: 4rem 2rem;
    background: var(--card-bg);
}

.service-dashboard {
    max-width: 1200px;
    margin: 0 auto;
    text-align: center;
}

.service-dashboard h1 {
    font-size: 2.5rem;
    margin-bottom: 1rem;
    color: var(--text);
}

.service-dashboard p {
    font-size: 1.1rem;
    color: #6c757d;
    margin-bottom: 3rem;
}

.dashboard-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    gap: 2rem;
    margin-top: 3rem;
}

.dashboard-card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 2rem;
    box-shadow: 0 4px 6px rgba(0,0,0,0.05);
    transition: all 0.3s ease;
}

.dashboard-card:hover {
    transform: translateY(-2px);
    box-shadow: 0 8px 15px rgba(0,0,0,0.1);
}

.card-icon {
    font-size: 2.5rem;
    margin-bottom: 1rem;
}

.card-content h3 {
    font-size: 1.1rem;
    margin-bottom: 1rem;
    color: #6c757d;
}

.metric {
    font-size: 2.5rem;
    font-weight: 700;
    color: var(--primary);
    margin-bottom: 0.5rem;
}

.metric-label {
    font-size: 0.9rem;
    color: #6c757d;
}

.services-overview {
    padding: 4rem 0;
}

.container {
    max-width: 1200px;
    margin: 0 auto;
    padding: 0 2rem;
}

.services-overview h2 {
    text-align: center;
    font-size: 2rem;
    margin-bottom: 3rem;
    color: var(--text);
}

.components-list {
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.component {
    display: flex;
    align-items: center;
    padding: 1.5rem;
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 8px;
    transition: all 0.3s ease;
}

.component:hover {
    border-color: var(--primary);
    box-shadow: 0 4px 8px rgba(0,0,0,0.1);
}

.component-status {
    width: 12px;
    height: 12px;
    border-radius: 50%;
    margin-right: 1rem;
    flex-shrink: 0;
}

.component-status.active {
    background: var(--success);
    animation: pulse 2s infinite;
}

.component-info {
    flex: 1;
}

.component-info h3 {
    font-size: 1.1rem;
    margin-bottom: 0.25rem;
    color: var(--text);
}

.component-info p {
    color: #6c757d;
    font-size: 0.9rem;
}

.component-metrics {
    color: var(--success);
    font-weight: 600;
    font-size: 0.9rem;
}

.footer {
    background: var(--text);
    color: white;
    padding: 3rem 0 1rem;
}

.footer-info h4 {
    margin-bottom: 1rem;
}

.service-details {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.detail-item {
    display: flex;
    justify-content: space-between;
    padding: 0.5rem 0;
}

.detail-label {
    font-weight: 600;
    opacity: 0.8;
}

.status-active {
    color: var(--success);
    font-weight: 600;
}

.footer-bottom {
    text-align: center;
    padding-top: 2rem;
    border-top: 1px solid rgba(255,255,255,0.1);
    opacity: 0.7;
    margin-top: 2rem;
}

@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.6; }
}

@media (max-width: 768px) {
    .navbar {
        flex-direction: column;
        gap: 1rem;
        padding: 1rem;
    }
    
    .dashboard-grid {
        grid-template-columns: 1fr;
    }
    
    .component {
        flex-direction: column;
        text-align: center;
        gap: 1rem;
    }
    
    .detail-item {
        flex-direction: column;
        gap: 0.25rem;
    }
}
EOF
}

# Generate common files (404, robots.txt, etc)
generate_common_files() {
    local domain="$1"
    local title="$2"
    local primary_color="$3"
    local accent_color="$4"
    
    # 404 page
    cat > "$HTML_DIR/404.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 - Page Not Found</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, $primary_color 0%, $accent_color 100%);
            color: white;
            margin: 0;
            padding: 40px;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            text-align: center;
        }
        .container {
            max-width: 500px;
        }
        h1 {
            font-size: 5rem;
            margin: 0 0 1rem 0;
            opacity: 0.9;
            font-weight: 700;
        }
        p {
            font-size: 1.2rem;
            margin: 1rem 0 2rem 0;
            opacity: 0.8;
        }
        a {
            color: white;
            text-decoration: none;
            border: 2px solid white;
            padding: 12px 24px;
            border-radius: 25px;
            transition: all 0.3s ease;
            display: inline-block;
            font-weight: 500;
        }
        a:hover {
            background: white;
            color: $primary_color;
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(0,0,0,0.2);
        }
        .error-icon {
            font-size: 4rem;
            margin-bottom: 1rem;
            opacity: 0.7;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="error-icon">🔍</div>
        <h1>404</h1>
        <p>The page you're looking for could not be found.</p>
        <a href="/">← Return Home</a>
    </div>
</body>
</html>
EOF

    # robots.txt
    cat > "$HTML_DIR/robots.txt" << EOF
User-agent: *
Allow: /

Sitemap: https://$domain/sitemap.xml
EOF

    # Basic sitemap.xml
    cat > "$HTML_DIR/sitemap.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    <url>
        <loc>https://$domain/</loc>
        <lastmod>$(date +%Y-%m-%d)</lastmod>
        <priority>1.0</priority>
    </url>
</urlset>
EOF
}




# Generate random customization data
generate_random_data() {
    local -n data_ref=$1
    
    # Check if openssl is available
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  openssl not found, using alternative method${NC}"
        # Fallback на /dev/urandom
        data_ref[meta_id]=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null || echo "$(date +%s)$(($RANDOM * $RANDOM))")
        data_ref[comment]=$(head -c 8 /dev/urandom | xxd -p 2>/dev/null || echo "$(date +%s)")
        data_ref[class_suffix]=$(head -c 4 /dev/urandom | xxd -p 2>/dev/null || echo "$RANDOM")
        data_ref[title_suffix]=$(head -c 4 /dev/urandom | xxd -p 2>/dev/null || echo "$RANDOM")
        data_ref[id_suffix]=$(head -c 4 /dev/urandom | xxd -p 2>/dev/null || echo "$RANDOM")
        
        # Continue with the rest of the function...
        local meta_names=("viewport-id" "session-id" "track-id" "render-id" "page-id" "config-id" "app-id" "user-id")
        data_ref[meta_name]=${meta_names[$RANDOM % ${#meta_names[@]}]}
        
        local class_prefixes=("app" "ui" "main" "content" "page" "site" "web" "view")
        local random_class_prefix=${class_prefixes[$RANDOM % ${#class_prefixes[@]}]}
        data_ref[class]="$random_class_prefix-${data_ref[class_suffix]}"
        
        local title_prefixes=("Portal" "Platform" "Site" "Hub" "Center" "Service" "System" "Network")
        local title_prefix=${title_prefixes[$RANDOM % ${#title_prefixes[@]}]}
        data_ref[title]="${title_prefix}_${data_ref[title_suffix]}"
        
        local company_prefixes=("Tech" "Digital" "Smart" "Pro" "Elite" "Prime" "Global" "Advanced")
        local company_suffix=${company_prefixes[$RANDOM % ${#company_prefixes[@]}]}
        data_ref[footer]="Powered by ${company_suffix}Solutions_${data_ref[title_suffix]}"
        
        local colors=("#2c3e50" "#3498db" "#9b59b6" "#e74c3c" "#f39c12" "#27ae60" "#34495e" "#16a085")
        data_ref[primary_color]=${colors[$RANDOM % ${#colors[@]}]}
        data_ref[accent_color]=${colors[$RANDOM % ${#colors[@]}]}
        
        return
    fi
    
    # Generate random values using openssl
    data_ref[meta_id]=$(openssl rand -hex 16)
    data_ref[comment]=$(openssl rand -hex 8)
    data_ref[class_suffix]=$(openssl rand -hex 4)
    data_ref[title_suffix]=$(openssl rand -hex 4)
    data_ref[id_suffix]=$(openssl rand -hex 4)
    
    # Random meta name
    local meta_names=("viewport-id" "session-id" "track-id" "render-id" "page-id" "config-id" "app-id" "user-id")
    data_ref[meta_name]=${meta_names[$RANDOM % ${#meta_names[@]}]}
    
    # Random class prefix
    local class_prefixes=("app" "ui" "main" "content" "page" "site" "web" "view")
    local random_class_prefix=${class_prefixes[$RANDOM % ${#class_prefixes[@]}]}
    data_ref[class]="$random_class_prefix-${data_ref[class_suffix]}"
    
    # Random titles and text
    local title_prefixes=("Portal" "Platform" "Site" "Hub" "Center" "Service" "System" "Network")
    local title_prefix=${title_prefixes[$RANDOM % ${#title_prefixes[@]}]}
    data_ref[title]="${title_prefix}_${data_ref[title_suffix]}"
    
    local company_prefixes=("Tech" "Digital" "Smart" "Pro" "Elite" "Prime" "Global" "Advanced")
    local company_suffix=${company_prefixes[$RANDOM % ${#company_prefixes[@]}]}
    data_ref[footer]="Powered by ${company_suffix}Solutions_${data_ref[title_suffix]}"
    
    # Random colors for enhanced customization
    local colors=("#2c3e50" "#3498db" "#9b59b6" "#e74c3c" "#f39c12" "#27ae60" "#34495e" "#16a085")
    data_ref[primary_color]=${colors[$RANDOM % ${#colors[@]}]}
    data_ref[accent_color]=${colors[$RANDOM % ${#colors[@]}]}
}


# Template management command
template_command() {
    check_running_as_root
    if ! docker --version >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker is not available${NC}"
        return 1
    fi

    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}❌ Caddy is not installed. Run 'sudo $APP_NAME install' first.${NC}"
        return 1
    fi
    

    local running_services=$(cd "$APP_DIR" && docker compose ps -q 2>/dev/null | wc -l || echo "0")
    if [ "$running_services" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Caddy is currently running${NC}"
        echo -e "${GRAY}   Template changes will be applied immediately${NC}"
        echo
        read -p "Continue with template generation? [Y/n]: " -r continue_template
        if [[ $continue_template =~ ^[Nn]$ ]]; then
            return 0
        fi
    fi
    
    
    while true; do
        clear
        show_template_options
        
        read -p "Select template option [0-8]: " choice
        
        case "$choice" in
            1)
                echo
                if generate_builtin_template "corporate"; then
                    echo -e "${GREEN}🎉 Corporate template generated successfully!${NC}"
                    echo
                    local running_services=$(cd "$APP_DIR" && docker compose ps -q 2>/dev/null | wc -l || echo "0")
                    if [ "$running_services" -gt 0 ]; then
                        read -p "Restart Caddy to apply changes? [Y/n]: " -r restart_caddy
                        if [[ ! $restart_caddy =~ ^[Nn]$ ]]; then
                            echo -e "${YELLOW}🔄 Restarting Caddy...${NC}"
                            cd "$APP_DIR" && docker compose restart
                            echo -e "${GREEN}✅ Caddy restarted${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}❌ Failed to generate corporate template${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                echo
                if generate_builtin_template "tech"; then
                    echo -e "${GREEN}🎉 Technology template generated successfully!${NC}"
                    echo
                    local running_services=$(cd "$APP_DIR" && docker compose ps -q 2>/dev/null | wc -l || echo "0")
                    if [ "$running_services" -gt 0 ]; then
                        read -p "Restart Caddy to apply changes? [Y/n]: " -r restart_caddy
                        if [[ ! $restart_caddy =~ ^[Nn]$ ]]; then
                            echo -e "${YELLOW}🔄 Restarting Caddy...${NC}"
                            cd "$APP_DIR" && docker compose restart
                            echo -e "${GREEN}✅ Caddy restarted${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}❌ Failed to generate technology template${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            3)
                echo
                if generate_builtin_template "portfolio"; then
                    echo -e "${GREEN}🎉 Portfolio template generated successfully!${NC}"
                    echo
                    local running_services=$(cd "$APP_DIR" && docker compose ps -q 2>/dev/null | wc -l || echo "0")
                    if [ "$running_services" -gt 0 ]; then
                        read -p "Restart Caddy to apply changes? [Y/n]: " -r restart_caddy
                        if [[ ! $restart_caddy =~ ^[Nn]$ ]]; then
                            echo -e "${YELLOW}🔄 Restarting Caddy...${NC}"
                            cd "$APP_DIR" && docker compose restart
                            echo -e "${GREEN}✅ Caddy restarted${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}❌ Failed to generate portfolio template${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            4)
                echo
                if generate_builtin_template "service"; then
                    echo -e "${GREEN}🎉 Service template generated successfully!${NC}"
                    echo
                    local running_services=$(cd "$APP_DIR" && docker compose ps -q 2>/dev/null | wc -l || echo "0")
                    if [ "$running_services" -gt 0 ]; then
                        read -p "Restart Caddy to apply changes? [Y/n]: " -r restart_caddy
                        if [[ ! $restart_caddy =~ ^[Nn]$ ]]; then
                            echo -e "${YELLOW}🔄 Restarting Caddy...${NC}"
                            cd "$APP_DIR" && docker compose restart
                            echo -e "${GREEN}✅ Caddy restarted${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}❌ Failed to generate service template${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            5)
                echo
                if generate_builtin_template "analytics"; then
                    echo -e "${GREEN}🎉 Analytics template generated successfully!${NC}"
                    echo
                    local running_services=$(cd "$APP_DIR" && docker compose ps -q 2>/dev/null | wc -l || echo "0")
                    if [ "$running_services" -gt 0 ]; then
                        read -p "Restart Caddy to apply changes? [Y/n]: " -r restart_caddy
                        if [[ ! $restart_caddy =~ ^[Nn]$ ]]; then
                            echo -e "${YELLOW}🔄 Restarting Caddy...${NC}"
                            cd "$APP_DIR" && docker compose restart
                            echo -e "${GREEN}✅ Caddy restarted${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}❌ Failed to generate analytics template${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            6)
                echo
                if generate_builtin_template "random"; then
                    echo -e "${GREEN}🎉 Random template generated successfully!${NC}"
                    echo
                    local running_services=$(cd "$APP_DIR" && docker compose ps -q 2>/dev/null | wc -l || echo "0")
                    if [ "$running_services" -gt 0 ]; then
                        read -p "Restart Caddy to apply changes? [Y/n]: " -r restart_caddy
                        if [[ ! $restart_caddy =~ ^[Nn]$ ]]; then
                            echo -e "${YELLOW}🔄 Restarting Caddy...${NC}"
                            cd "$APP_DIR" && docker compose restart
                            echo -e "${GREEN}✅ Caddy restarted${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}❌ Failed to generate random template${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            7)
                echo
                show_current_template_info
                read -p "Press Enter to continue..."
                ;;
            8)
                echo -e "${GRAY}Current template preserved${NC}"
                read -p "Press Enter to continue..."
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}❌ Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}




# Create default HTML content
create_default_html() {
    echo -e "${WHITE}🌐 Creating Default Website${NC}"
    
    cat > "$HTML_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            margin: 0;
            padding: 40px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.3);
            text-align: center;
            max-width: 500px;
        }
        h1 {
            color: #333;
            margin-bottom: 20px;
        }
        p {
            color: #666;
            line-height: 1.6;
        }
        .status {
            display: inline-block;
            background: #4CAF50;
            color: white;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 14px;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🌐 Website Online</h1>
        <p>This is a default page served by Caddy.<br>
        The service is running correctly and ready to serve your content.</p>
        <div class="status">✅ Service Active</div>
    </div>
</body>
</html>
EOF

    # Create 404 page
    cat > "$HTML_DIR/404.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 - Page Not Found</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            margin: 0;
            padding: 40px;
            background: #f5f5f5;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 5px 15px rgba(0,0,0,0.1);
            text-align: center;
            max-width: 500px;
        }
        h1 {
            color: #e74c3c;
            font-size: 3em;
            margin-bottom: 20px;
        }
        p {
            color: #666;
            line-height: 1.6;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>404</h1>
        <p>The page you're looking for could not be found.</p>
    </div>
</body>
</html>
EOF

    echo -e "${GREEN}✅ Default website created${NC}"
}

install_management_script() {
    echo -e "${WHITE}🔧 Installing Management Script${NC}"
    
    # Определить путь к скрипту
    local script_path
    if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "@" ]; then
        script_path="$0"
    else
        # Попытаться найти скрипт в /tmp или скачать заново
        local temp_script="/tmp/selfsteal-install.sh"
        if curl -fsSL "$UPDATE_URL" -o "$temp_script" 2>/dev/null; then
            script_path="$temp_script"
            echo -e "${GRAY}📥 Downloaded script from remote source${NC}"
        else
            echo -e "${YELLOW}⚠️  Could not install management script automatically${NC}"
            echo -e "${GRAY}   You can download it manually from: $UPDATE_URL${NC}"
            return 1
        fi
    fi
    
    # Установить скрипт
    if [ -f "$script_path" ]; then
        cp "$script_path" "/usr/local/bin/$APP_NAME"
        chmod +x "/usr/local/bin/$APP_NAME"
        echo -e "${GREEN}✅ Management script installed: /usr/local/bin/$APP_NAME${NC}"
        
        # Очистить временный файл если использовался
        if [ "$script_path" = "/tmp/selfsteal-install.sh" ]; then
            rm -f "$script_path"
        fi
    else
        echo -e "${RED}❌ Failed to install management script${NC}"
        return 1
    fi
}
# Service management functions
up_command() {
    check_running_as_root
    
    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        echo -e "${RED}❌ Caddy is not installed. Run 'sudo $APP_NAME install' first.${NC}"
        return 1
    fi
    
    echo -e "${WHITE}🚀 Starting Caddy Services${NC}"
    cd "$APP_DIR"
    
    if docker compose up -d; then
        echo -e "${GREEN}✅ Caddy services started successfully${NC}"
    else
        echo -e "${RED}❌ Failed to start Caddy services${NC}"
        return 1
    fi
}

down_command() {
    check_running_as_root
    
    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        echo -e "${YELLOW}⚠️  Caddy is not installed${NC}"
        return 0
    fi
    
    echo -e "${WHITE}🛑 Stopping Caddy Services${NC}"
    cd "$APP_DIR"
    
    if docker compose down; then
        echo -e "${GREEN}✅ Caddy services stopped successfully${NC}"
    else
        echo -e "${RED}❌ Failed to stop Caddy services${NC}"
        return 1
    fi
}

restart_command() {
    check_running_as_root
    
    echo -e "${WHITE}🔄 Restarting Caddy Services${NC}"
    down_command
    sleep 2
    up_command
}

status_command() {
    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        echo -e "${RED}❌ Caddy is not installed${NC}"
        return 1
    fi
    
    echo -e "${WHITE}📊 Caddy Service Status${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 30))${NC}"
    echo
    
    cd "$APP_DIR"
    
    # Check if services are running
    local running_services=$(docker compose ps -q 2>/dev/null | wc -l)
    local total_services=1
    
    if [ "$running_services" -eq "$total_services" ]; then
        echo -e "${GREEN}✅ All services are running ($running_services/$total_services)${NC}"
    elif [ "$running_services" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Some services are running ($running_services/$total_services)${NC}"
    else
        echo -e "${RED}❌ No services are running${NC}"
    fi
    
    echo
    echo -e "${WHITE}📋 Container Status:${NC}"
    docker compose ps
    
    # Show configuration summary
    if [ -f "$APP_DIR/.env" ]; then
        echo
        echo -e "${WHITE}⚙️  Configuration:${NC}"
        local domain=$(grep "SELF_STEAL_DOMAIN=" "$APP_DIR/.env" | cut -d'=' -f2)
        local port=$(grep "SELF_STEAL_PORT=" "$APP_DIR/.env" | cut -d'=' -f2)
        
        printf "   ${WHITE}%-15s${NC} ${GRAY}%s${NC}\n" "Domain:" "$domain"
        printf "   ${WHITE}%-15s${NC} ${GRAY}%s${NC}\n" "HTTPS Port:" "$port"
        printf "   ${WHITE}%-15s${NC} ${GRAY}%s${NC}\n" "HTML Path:" "$HTML_DIR"
    fi
    printf "   ${WHITE}%-15s${NC} ${GRAY}%s${NC}\n" "Script Version:" "v$SCRIPT_VERSION"
}

logs_command() {
    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        echo -e "${RED}❌ Caddy is not installed${NC}"
        return 1
    fi
    
    echo -e "${WHITE}📝 Caddy Logs${NC}"
    echo -e "${GRAY}Press Ctrl+C to exit${NC}"
    echo
    
    cd "$APP_DIR"
    docker compose logs -f
}


# Clean logs function
clean_logs_command() {
    check_running_as_root
    
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}❌ Caddy is not installed${NC}"
        return 1
    fi
    
    echo -e "${WHITE}🧹 Cleaning Logs${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 25))${NC}"
    echo
    
    # Show current log sizes
    echo -e "${WHITE}📊 Current log sizes:${NC}"
    
    # Docker logs
    local docker_logs_size
    docker_logs_size=$(docker logs $CONTAINER_NAME 2>&1 | wc -c 2>/dev/null || echo "0")
    docker_logs_size=$((docker_logs_size / 1024))
    echo -e "${GRAY}   Docker logs: ${WHITE}${docker_logs_size}KB${NC}"
    
    # Caddy access logs
    local caddy_logs_path="$APP_DIR/caddy_data/_logs"
    if [ -d "$caddy_logs_path" ]; then
        local caddy_logs_size
        caddy_logs_size=$(du -sk "$caddy_logs_path" 2>/dev/null | cut -f1 || echo "0")
        echo -e "${GRAY}   Caddy logs: ${WHITE}${caddy_logs_size}KB${NC}"
    fi
    
    echo
    read -p "Clean all logs? [y/N]: " -r clean_choice
    
    if [[ $clean_choice =~ ^[Yy]$ ]]; then
        echo -e "${WHITE}🧹 Cleaning logs...${NC}"
        
        # Clean Docker logs by recreating container
        if docker ps -q -f name=$CONTAINER_NAME >/dev/null 2>&1; then
            echo -e "${GRAY}   Stopping Caddy...${NC}"
            cd "$APP_DIR" && docker compose stop
            
            echo -e "${GRAY}   Removing container to clear logs...${NC}"
            docker rm $CONTAINER_NAME 2>/dev/null || true
            
            echo -e "${GRAY}   Starting Caddy...${NC}"
            cd "$APP_DIR" && docker compose up -d
        fi
        
        # Clean Caddy internal logs
        if [ -d "$caddy_logs_path" ]; then
            echo -e "${GRAY}   Cleaning Caddy access logs...${NC}"
            rm -rf "$caddy_logs_path"/* 2>/dev/null || true
        fi
        
        echo -e "${GREEN}✅ Logs cleaned successfully${NC}"
    else
        echo -e "${GRAY}Log cleanup cancelled${NC}"
    fi
}

# Show log sizes function
logs_size_command() {
    check_running_as_root
    
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}❌ Caddy is not installed${NC}"
        return 1
    fi
    
    echo -e "${WHITE}📊 Log Sizes${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 25))${NC}"
    echo
    
    # Docker logs
    local docker_logs_size
    if docker ps -q -f name=$CONTAINER_NAME >/dev/null 2>&1; then
        docker_logs_size=$(docker logs $CONTAINER_NAME 2>&1 | wc -c 2>/dev/null || echo "0")
        docker_logs_size=$((docker_logs_size / 1024))
        echo -e "${WHITE}📋 Docker logs:${NC} ${GRAY}${docker_logs_size}KB${NC}"
    else
        echo -e "${WHITE}📋 Docker logs:${NC} ${GRAY}Container not running${NC}"
    fi
    
    # Caddy access logs
    local caddy_data_dir
    caddy_data_dir=$(cd "$APP_DIR" && docker volume inspect "${APP_DIR##*/}_${VOLUME_PREFIX}_data" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
    
    if [ -n "$caddy_data_dir" ] && [ -d "$caddy_data_dir" ]; then
        local access_log="$caddy_data_dir/access.log"
        if [ -f "$access_log" ]; then
            local access_log_size
            access_log_size=$(du -k "$access_log" 2>/dev/null | cut -f1 || echo "0")
            echo -e "${WHITE}📄 Access log:${NC} ${GRAY}${access_log_size}KB${NC}"
        else
            echo -e "${WHITE}📄 Access log:${NC} ${GRAY}Not found${NC}"
        fi
        
        # Check for rotated logs
        local rotated_logs
        rotated_logs=$(find "$caddy_data_dir" -name "access.log.*" 2>/dev/null | wc -l || echo "0")
        if [ "$rotated_logs" -gt 0 ]; then
            local rotated_size
            rotated_size=$(find "$caddy_data_dir" -name "access.log.*" -exec du -k {} \; 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
            echo -e "${WHITE}🔄 Rotated logs:${NC} ${GRAY}${rotated_size}KB (${rotated_logs} files)${NC}"
        fi
    else
        echo -e "${WHITE}📄 Caddy logs:${NC} ${GRAY}Volume not accessible${NC}"
    fi
    
    # Logs directory
    if [ -d "$APP_DIR/logs" ]; then
        local logs_dir_size
        logs_dir_size=$(du -sk "$APP_DIR/logs" 2>/dev/null | cut -f1 || echo "0")
        echo -e "${WHITE}📁 Logs directory:${NC} ${GRAY}${logs_dir_size}KB${NC}"
    fi
    
    echo
    echo -e "${GRAY}💡 Tip: Use 'sudo $APP_NAME clean-logs' to clean all logs${NC}"
    echo
}

stop_services() {
    if [ -f "$APP_DIR/docker-compose.yml" ]; then
        cd "$APP_DIR"
        docker compose down 2>/dev/null || true
    fi
}

uninstall_command() {
    check_running_as_root
    
    echo -e "${WHITE}🗑️  Caddy Uninstallation${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 30))${NC}"
    echo
    
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${YELLOW}⚠️  Caddy is not installed${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}⚠️  This will completely remove Caddy and all data!${NC}"
    echo
    read -p "Are you sure you want to continue? [y/N]: " -r confirm
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${GRAY}Uninstallation cancelled${NC}"
        return 0
    fi
    
    echo
    echo -e "${WHITE}🛑 Stopping services...${NC}"
    stop_services
    
    echo -e "${WHITE}🗑️  Removing files...${NC}"
    rm -rf "$APP_DIR"
    
    echo -e "${WHITE}🗑️  Removing management script...${NC}"
    rm -f "/usr/local/bin/$APP_NAME"
    
    echo -e "${GREEN}✅ Caddy uninstalled successfully${NC}"
    echo
    echo -e "${GRAY}Note: HTML content in $HTML_DIR was preserved${NC}"
}

edit_command() {
    check_running_as_root
    
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}❌ Caddy is not installed${NC}"
        return 1
    fi
    
    echo -e "${WHITE}📝 Edit Configuration Files${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 30))${NC}"
    echo
    
    echo -e "${WHITE}Select file to edit:${NC}"
    echo -e "   ${WHITE}1)${NC} ${GRAY}.env file (domain and port settings)${NC}"
    echo -e "   ${WHITE}2)${NC} ${GRAY}Caddyfile (Caddy configuration)${NC}"
    echo -e "   ${WHITE}3)${NC} ${GRAY}docker-compose.yml (Docker configuration)${NC}"
    echo -e "   ${WHITE}0)${NC} ${GRAY}Cancel${NC}"
    echo
    
    read -p "Select option [0-3]: " choice
    
    case "$choice" in
        1)
            ${EDITOR:-nano} "$APP_DIR/.env"
            echo -e "${YELLOW}⚠️  Restart Caddy to apply changes: sudo $APP_NAME restart${NC}"
            ;;
        2)
            ${EDITOR:-nano} "$APP_DIR/Caddyfile"
            echo -e "${YELLOW}⚠️  Restart Caddy to apply changes: sudo $APP_NAME restart${NC}"
            ;;
        3)
            ${EDITOR:-nano} "$APP_DIR/docker-compose.yml"
            echo -e "${YELLOW}⚠️  Restart Caddy to apply changes: sudo $APP_NAME restart${NC}"
            ;;
        0)
            echo -e "${GRAY}Cancelled${NC}"
            ;;
        *)
            echo -e "${RED}❌ Invalid option${NC}"
            ;;
    esac
}


# Modern Portfolio Template
generate_portfolio_template() {
    local domain="$1"
    local -n data_ref=$2
    
    cat > "$HTML_DIR/index.html" << EOF
<!DOCTYPE html>
<html lang="en" class="${data_ref[class]}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="${data_ref[meta_name]}" content="${data_ref[meta_id]}">
    <title>${data_ref[title]} - Creative Portfolio</title>
    <!-- ${data_ref[comment]} -->
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <header class="header">
        <nav class="navbar">
            <div class="nav-brand">
                <span class="portfolio-icon">✨</span>
                ${data_ref[title]}
            </div>
            <ul class="nav-menu">
                <li><a href="#home">Home</a></li>
                <li><a href="#portfolio">Portfolio</a></li>
                <li><a href="#about">About</a></li>
                <li><a href="#contact">Contact</a></li>
            </ul>
        </nav>
    </header>

    <main>
        <section id="home" class="hero-portfolio">
            <div class="hero-content">
                <div class="hero-text">
                    <h1>Creative Professional</h1>
                    <p>Crafting exceptional digital experiences with passion and precision</p>
                    <div class="hero-badges">
                        <span class="badge">Design</span>
                        <span class="badge">Development</span>
                        <span class="badge">Innovation</span>
                    </div>
                </div>
                <div class="hero-visual">
                    <div class="floating-card">
                        <div class="card-icon">🎨</div>
                        <h3>Creative Design</h3>
                    </div>
                </div>
            </div>
        </section>

        <section id="portfolio" class="portfolio-section">
            <div class="container">
                <h2>Featured Work</h2>
                <div class="portfolio-grid">
                    <div class="portfolio-item">
                        <div class="portfolio-image">
                            <div class="portfolio-overlay">
                                <h3>Web Application</h3>
                                <p>Full-stack development</p>
                            </div>
                        </div>
                    </div>
                    <div class="portfolio-item">
                        <div class="portfolio-image">
                            <div class="portfolio-overlay">
                                <h3>Mobile App</h3>
                                <p>iOS & Android development</p>
                            </div>
                        </div>
                    </div>
                    <div class="portfolio-item">
                        <div class="portfolio-image">
                            <div class="portfolio-overlay">
                                <h3>Brand Identity</h3>
                                <p>Visual design & branding</p>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </section>

        <section id="about" class="about-section">
            <div class="container">
                <div class="about-content">
                    <div class="about-text">
                        <h2>About Me</h2>
                        <p>I'm a passionate creator who brings ideas to life through thoughtful design and clean code. With years of experience in digital craftsmanship, I help brands and individuals tell their stories in compelling ways.</p>
                        <div class="skills">
                            <div class="skill-item">
                                <span class="skill-icon">💻</span>
                                <span>Development</span>
                            </div>
                            <div class="skill-item">
                                <span class="skill-icon">🎨</span>
                                <span>Design</span>
                            </div>
                            <div class="skill-item">
                                <span class="skill-icon">📱</span>
                                <span>Mobile</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </section>
    </main>

    <footer class="footer">
        <div class="container">
            <div class="footer-content">
                <h4>${data_ref[title]}</h4>
                <p>Creative professional portfolio</p>
                <div class="footer-links">
                    <span>Domain: $domain</span>
                    <span>Status: Online</span>
                </div>
            </div>
            <div class="footer-bottom">
                <p>${data_ref[footer]}</p>
            </div>
        </div>
    </footer>
</body>
</html>
EOF

    generate_portfolio_css "${data_ref[class]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}" "${data_ref[comment]}"
    generate_common_files "$domain" "${data_ref[title]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}"
}

# Data Analytics Template
generate_analytics_template() {
    local domain="$1"
    local -n data_ref=$2
    
    cat > "$HTML_DIR/index.html" << EOF
<!DOCTYPE html>
<html lang="en" class="${data_ref[class]}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="${data_ref[meta_name]}" content="${data_ref[meta_id]}">
    <title>${data_ref[title]} - Analytics Dashboard</title>
    <!-- ${data_ref[comment]} -->
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <div class="analytics-bg"></div>
    
    <header class="header">
        <nav class="navbar">
            <div class="nav-brand">
                <span class="analytics-icon">📊</span>
                ${data_ref[title]}
            </div>
            <div class="nav-actions">
                <span class="data-indicator">
                    <span class="indicator-dot"></span>
                    Live Data
                </span>
            </div>
        </nav>
    </header>

    <main>
        <section class="dashboard">
            <div class="dashboard-header">
                <h1>Analytics Dashboard</h1>
                <p>Real-time data insights and performance metrics</p>
            </div>
            
            <div class="metrics-grid">
                <div class="metric-card">
                    <div class="metric-header">
                        <span class="metric-icon">👥</span>
                        <h3>Active Users</h3>
                    </div>
                    <div class="metric-value">2,847</div>
                    <div class="metric-change positive">+12.5%</div>
                </div>
                
                <div class="metric-card">
                    <div class="metric-header">
                        <span class="metric-icon">📈</span>
                        <h3>Revenue</h3>
                    </div>
                    <div class="metric-value">$89,320</div>
                    <div class="metric-change positive">+8.3%</div>
                </div>
                
                <div class="metric-card">
                    <div class="metric-header">
                        <span class="metric-icon">⚡</span>
                        <h3>Performance</h3>
                    </div>
                    <div class="metric-value">98.7%</div>
                    <div class="metric-change neutral">+0.2%</div>
                </div>
                
                <div class="metric-card">
                    <div class="metric-header">
                        <span class="metric-icon">🎯</span>
                        <h3>Conversion</h3>
                    </div>
                    <div class="metric-value">4.23%</div>
                    <div class="metric-change positive">+1.1%</div>
                </div>
            </div>
            
            <div class="charts-section">
                <div class="chart-container">
                    <h3>Traffic Overview</h3>
                    <div class="chart-placeholder">
                        <div class="chart-bars">
                            <div class="bar" style="height: 60%"></div>
                            <div class="bar" style="height: 80%"></div>
                            <div class="bar" style="height: 45%"></div>
                            <div class="bar" style="height: 90%"></div>
                            <div class="bar" style="height: 70%"></div>
                            <div class="bar" style="height: 85%"></div>
                            <div class="bar" style="height: 95%"></div>
                        </div>
                    </div>
                </div>
                
                <div class="stats-panel">
                    <h3>System Health</h3>
                    <div class="health-items">
                        <div class="health-item">
                            <span class="health-status active"></span>
                            <span>API Services</span>
                            <span class="health-value">Online</span>
                        </div>
                        <div class="health-item">
                            <span class="health-status active"></span>
                            <span>Database</span>
                            <span class="health-value">Healthy</span>
                        </div>
                        <div class="health-item">
                            <span class="health-status active"></span>
                            <span>Cache Layer</span>
                            <span class="health-value">Optimal</span>
                        </div>
                    </div>
                </div>
            </div>
        </section>
    </main>

    <footer class="footer">
        <div class="container">
            <div class="footer-content">
                <h4>${data_ref[title]} Analytics</h4>
                <div class="footer-stats">
                    <div class="footer-stat">
                        <span class="stat-label">Domain:</span>
                        <span>$domain</span>
                    </div>
                    <div class="footer-stat">
                        <span class="stat-label">Last Update:</span>
                        <span>$(date '+%H:%M')</span>
                    </div>
                </div>
            </div>
            <div class="footer-bottom">
                <p>${data_ref[footer]}</p>
            </div>
        </div>
    </footer>
</body>
</html>
EOF

    generate_analytics_css "${data_ref[class]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}" "${data_ref[comment]}"
    generate_common_files "$domain" "${data_ref[title]}" "${data_ref[primary_color]}" "${data_ref[accent_color]}"
}

generate_portfolio_css() {
    local class_name="$1"
    local primary_color="$2"
    local accent_color="$3"
    local comment="$4"
    
    cat > "$HTML_DIR/style.css" << EOF
/* Portfolio Template - $comment */
:root {
    --primary: $primary_color;
    --accent: $accent_color;
    --gradient: linear-gradient(135deg, var(--primary) 0%, var(--accent) 100%);
    --bg: #fafafa;
    --card-bg: white;
    --text: #2c2c2c;
    --text-light: #666;
    --shadow: 0 10px 40px rgba(0,0,0,0.1);
}

.$class_name {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.6;
}

* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

.header {
    background: var(--card-bg);
    box-shadow: 0 2px 20px rgba(0,0,0,0.05);
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 1000;
}

.navbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem 2rem;
    max-width: 1200px;
    margin: 0 auto;
}

.nav-brand {
    display: flex;
    align-items: center;
    font-size: 1.5rem;
    font-weight: 700;
    background: var(--gradient);
    background-clip: text;
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
}

.portfolio-icon {
    margin-right: 0.5rem;
    font-size: 1.8rem;
}

.nav-menu {
    display: flex;
    list-style: none;
    gap: 2rem;
}

.nav-menu a {
    text-decoration: none;
    color: var(--text);
    font-weight: 500;
    padding: 0.5rem 1rem;
    border-radius: 8px;
    transition: all 0.3s ease;
}

.nav-menu a:hover {
    background: var(--primary);
    color: white;
}

main {
    margin-top: 80px;
}

.hero-portfolio {
    padding: 5rem 2rem;
    background: var(--card-bg);
    position: relative;
    overflow: hidden;
}

.hero-content {
    max-width: 1200px;
    margin: 0 auto;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 4rem;
    align-items: center;
}

.hero-text h1 {
    font-size: 3.5rem;
    font-weight: 800;
    background: var(--gradient);
    background-clip: text;
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    margin-bottom: 1rem;
}

.hero-text p {
    font-size: 1.2rem;
    color: var(--text-light);
    margin-bottom: 2rem;
}

.hero-badges {
    display: flex;
    gap: 1rem;
    flex-wrap: wrap;
}

.badge {
    padding: 0.5rem 1rem;
    background: var(--gradient);
    color: white;
    border-radius: 25px;
    font-size: 0.9rem;
    font-weight: 600;
}

.floating-card {
    background: var(--card-bg);
    padding: 2rem;
    border-radius: 20px;
    box-shadow: var(--shadow);
    text-align: center;
    animation: float 6s ease-in-out infinite;
}

@keyframes float {
    0%, 100% { transform: translateY(0px); }
    50% { transform: translateY(-20px); }
}

.card-icon {
    font-size: 3rem;
    margin-bottom: 1rem;
}

.container {
    max-width: 1200px;
    margin: 0 auto;
    padding: 0 2rem;
}

.portfolio-section {
    padding: 5rem 0;
}

.portfolio-section h2 {
    text-align: center;
    font-size: 2.5rem;
    margin-bottom: 3rem;
    color: var(--text);
}

.portfolio-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
    gap: 2rem;
}

.portfolio-item {
    border-radius: 15px;
    overflow: hidden;
    box-shadow: var(--shadow);
    transition: transform 0.3s ease;
}

.portfolio-item:hover {
    transform: translateY(-10px);
}

.portfolio-image {
    height: 250px;
    background: var(--gradient);
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
}

.portfolio-overlay {
    text-align: center;
    color: white;
}

.portfolio-overlay h3 {
    font-size: 1.5rem;
    margin-bottom: 0.5rem;
}

.about-section {
    padding: 5rem 0;
    background: var(--card-bg);
}

.about-section h2 {
    font-size: 2.5rem;
    margin-bottom: 2rem;
    color: var(--text);
}

.skills {
    display: flex;
    gap: 2rem;
    margin-top: 2rem;
}

.skill-item {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 1rem 1.5rem;
    background: var(--bg);
    border-radius: 10px;
    border: 2px solid transparent;
    transition: border-color 0.3s ease;
}

.skill-item:hover {
    border-color: var(--primary);
}

.skill-icon {
    font-size: 1.5rem;
}

.footer {
    background: var(--text);
    color: white;
    padding: 3rem 0 1rem;
}

.footer-content {
    text-align: center;
    margin-bottom: 2rem;
}

.footer-links {
    display: flex;
    justify-content: center;
    gap: 2rem;
    margin-top: 1rem;
    font-size: 0.9rem;
    opacity: 0.8;
}

.footer-bottom {
    text-align: center;
    padding-top: 2rem;
    border-top: 1px solid rgba(255,255,255,0.1);
    opacity: 0.7;
}

@media (max-width: 768px) {
    .hero-content {
        grid-template-columns: 1fr;
        text-align: center;
    }
    
    .hero-text h1 {
        font-size: 2.5rem;
    }
    
    .skills {
        flex-direction: column;
    }
    
    .footer-links {
        flex-direction: column;
        gap: 1rem;
    }
}
EOF
}

generate_analytics_css() {
    local class_name="$1"
    local primary_color="$2"
    local accent_color="$3"
    local comment="$4"
    
    cat > "$HTML_DIR/style.css" << EOF
/* Analytics Dashboard Template - $comment */
:root {
    --primary: $primary_color;
    --accent: $accent_color;
    --bg: #f8fafc;
    --dark: #1a202c;
    --card-bg: white;
    --text: #2d3748;
    --text-light: #718096;
    --border: #e2e8f0;
    --success: #48bb78;
    --warning: #ed8936;
    --shadow: 0 4px 6px rgba(0, 0, 0, 0.05);
    --shadow-lg: 0 10px 15px rgba(0, 0, 0, 0.1);
}

.$class_name {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
}

* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

.analytics-bg {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: 
        radial-gradient(circle at 25% 25%, rgba(99, 102, 241, 0.05) 0%, transparent 50%),
        radial-gradient(circle at 75% 75%, rgba(236, 72, 153, 0.05) 0%, transparent 50%);
    z-index: -1;
}

.header {
    background: var(--card-bg);
    box-shadow: var(--shadow);
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 1000;
    border-bottom: 1px solid var(--border);
}

.navbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem 2rem;
    max-width: 1400px;
    margin: 0 auto;
}

.nav-brand {
    display: flex;
    align-items: center;
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--primary);
}

.analytics-icon {
    margin-right: 0.5rem;
    font-size: 1.8rem;
}

.data-indicator {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    color: var(--success);
    font-size: 0.9rem;
    font-weight: 600;
}

.indicator-dot {
    width: 8px;
    height: 8px;
    background: var(--success);
    border-radius: 50%;
    animation: pulse 2s infinite;
}

main {
    margin-top: 80px;
    padding: 2rem;
}

.dashboard {
    max-width: 1400px;
    margin: 0 auto;
}

.dashboard-header {
    text-align: center;
    margin-bottom: 3rem;
}

.dashboard-header h1 {
    font-size: 2.5rem;
    font-weight: 800;
    color: var(--text);
    margin-bottom: 0.5rem;
}

.dashboard-header p {
    color: var(--text-light);
    font-size: 1.1rem;
}

.metrics-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    gap: 1.5rem;
    margin-bottom: 3rem;
}

.metric-card {
    background: var(--card-bg);
    border-radius: 12px;
    padding: 2rem;
    box-shadow: var(--shadow);
    border: 1px solid var(--border);
    transition: all 0.3s ease;
}

.metric-card:hover {
    box-shadow: var(--shadow-lg);
    transform: translateY(-2px);
}

.metric-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 1rem;
}

.metric-icon {
    font-size: 1.5rem;
}

.metric-header h3 {
    font-size: 0.9rem;
    font-weight: 600;
    color: var(--text-light);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.metric-value {
    font-size: 2.5rem;
    font-weight: 800;
    color: var(--text);
    margin-bottom: 0.5rem;
}

.metric-change {
    font-size: 0.9rem;
    font-weight: 600;
    padding: 0.25rem 0.5rem;
    border-radius: 6px;
    display: inline-block;
}

.metric-change.positive {
    background: rgba(72, 187, 120, 0.1);
    color: var(--success);
}

.metric-change.neutral {
    background: rgba(237, 137, 54, 0.1);
    color: var(--warning);
}

.charts-section {
    display: grid;
    grid-template-columns: 2fr 1fr;
    gap: 2rem;
}

.chart-container {
    background: var(--card-bg);
    border-radius: 12px;
    padding: 2rem;
    box-shadow: var(--shadow);
    border: 1px solid var(--border);
}

.chart-container h3 {
    font-size: 1.2rem;
    margin-bottom: 2rem;
    color: var(--text);
}

.chart-placeholder {
    height: 200px;
    background: linear-gradient(135deg, var(--primary) 0%, var(--accent) 100%);
    border-radius: 8px;
    padding: 1rem;
    display: flex;
    align-items: end;
    justify-content: center;
}

.chart-bars {
    display: flex;
    align-items: end;
    gap: 8px;
    height: 100%;
    width: 100%;
    max-width: 300px;
}

.bar {
    background: rgba(255,255,255,0.8);
    border-radius: 4px 4px 0 0;
    flex: 1;
    min-height: 20px;
    animation: growUp 1s ease-out;
}

@keyframes growUp {
    from { height: 0; }
}

.stats-panel {
    background: var(--card-bg);
    border-radius: 12px;
    padding: 2rem;
    box-shadow: var(--shadow);
    border: 1px solid var(--border);
    height: fit-content;
}

.stats-panel h3 {
    font-size: 1.2rem;
    margin-bottom: 1.5rem;
    color: var(--text);
}

.health-items {
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.health-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1rem;
    background: var(--bg);
    border-radius: 8px;
    transition: background 0.3s ease;
}

.health-item:hover {
    background: rgba(99, 102, 241, 0.05);
}

.health-status {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    margin-right: 1rem;
}

.health-status.active {
    background: var(--success);
    animation: pulse 2s infinite;
}

.health-value {
    font-weight: 600;
    color: var(--success);
}

.footer {
    background: var(--dark);
    color: white;
    padding: 2rem;
    margin-top: 3rem;
}

.container {
    max-width: 1400px;
    margin: 0 auto;
}

.footer-content {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 1rem;
}

.footer-stats {
    display: flex;
    gap: 2rem;
}

.footer-stat {
    display: flex;
    gap: 0.5rem;
    font-size: 0.9rem;
}

.stat-label {
    opacity: 0.7;
}

.footer-bottom {
    text-align: center;
    padding-top: 1rem;
    border-top: 1px solid rgba(255,255,255,0.1);
    opacity: 0.7;
}

@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
}

@media (max-width: 768px) {
    .charts-section {
        grid-template-columns: 1fr;
    }
    
    .footer-content {
        flex-direction: column;
        gap: 1rem;
        text-align: center;
    }
    
    .footer-stats {
        flex-direction: column;
        gap: 0.5rem;
    }
}
EOF
}


show_help() {
    echo -e "${WHITE}Caddy for Reality Selfsteal Management Script v$SCRIPT_VERSION${NC}"
    echo
    echo -e "${WHITE}Usage:${NC}"
    echo -e "  ${CYAN}$APP_NAME${NC} [${GRAY}command${NC}]"
    echo
    echo -e "${WHITE}Commands:${NC}"
    printf "   ${CYAN}%-12s${NC} %s\n" "install" "🚀 Install Caddy for Reality masking"
    printf "   ${CYAN}%-12s${NC} %s\n" "up" "▶️  Start Caddy services"
    printf "   ${CYAN}%-12s${NC} %s\n" "down" "⏹️  Stop Caddy services"
    printf "   ${CYAN}%-12s${NC} %s\n" "restart" "🔄 Restart Caddy services"
    printf "   ${CYAN}%-12s${NC} %s\n" "status" "📊 Show service status"
    printf "   ${CYAN}%-12s${NC} %s\n" "logs" "📝 Show service logs"
    printf "   ${CYAN}%-12s${NC} %s\n" "logs-size" "📊 Show log sizes"
    printf "   ${CYAN}%-12s${NC} %s\n" "clean-logs" "🧹 Clean all logs"
    printf "   ${CYAN}%-12s${NC} %s\n" "edit" "✏️  Edit configuration files"
    printf "   ${CYAN}%-12s${NC} %s\n" "uninstall" "🗑️  Remove Caddy installation"
    printf "   ${CYAN}%-12s${NC} %s\n" "template" "🎨 Manage website templates"
    printf "   ${CYAN}%-12s${NC} %s\n" "menu" "📋 Show interactive menu"
    printf "   ${CYAN}%-12s${NC} %s\n" "update" "🔄 Check for script updates"
    echo
    echo -e "${WHITE}Examples:${NC}"
    echo -e "  ${GRAY}sudo $APP_NAME install${NC}"
    echo -e "  ${GRAY}sudo $APP_NAME status${NC}"
    echo -e "  ${GRAY}sudo $APP_NAME logs${NC}"
    echo
    echo -e "${WHITE}For more information, visit:${NC}"
    echo -e "  ${BLUE}https://github.com/remnawave/${NC}"
}

check_for_updates() {
    echo -e "${WHITE}🔍 Checking for updates...${NC}"
    
    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  curl not available, cannot check for updates${NC}"
        return 1
    fi
    
    # Get latest version from GitHub script
    echo -e "${WHITE}📝 Fetching latest script version...${NC}"
    local remote_script_version
    remote_script_version=$(curl -s "$UPDATE_URL" 2>/dev/null | grep "^SCRIPT_VERSION=" | cut -d'"' -f2)
    
    if [ -z "$remote_script_version" ]; then
        echo -e "${YELLOW}⚠️  Unable to fetch latest version${NC}"
        return 1
    fi
    
    echo -e "${WHITE}📝 Current version: ${GRAY}v$SCRIPT_VERSION${NC}"
    echo -e "${WHITE}📦 Latest version:  ${GRAY}v$remote_script_version${NC}"
    echo
    
    # Compare versions
    if [ "$SCRIPT_VERSION" = "$remote_script_version" ]; then
        echo -e "${GREEN}✅ You are running the latest version${NC}"
        return 0
    else
        echo -e "${YELLOW}🔄 A new version is available!${NC}"
        echo
        
        # Try to get changelog/release info if available
        echo -e "${WHITE}What's new in v$remote_script_version:${NC}"
        echo -e "${GRAY}• Bug fixes and improvements${NC}"
        echo -e "${GRAY}• Enhanced stability${NC}"
        echo -e "${GRAY}• Updated features${NC}"
        
        echo
        read -p "Would you like to update now? [Y/n]: " -r update_choice
        
        if [[ ! $update_choice =~ ^[Nn]$ ]]; then
            update_script
        else
            echo -e "${GRAY}Update skipped${NC}"
        fi
    fi
}

# Update script function
update_script() {
    echo -e "${WHITE}🔄 Updating script...${NC}"
    
    # Create backup
    local backup_file="/tmp/caddy-selfsteal-backup-$(date +%Y%m%d_%H%M%S).sh"
    if cp "$0" "$backup_file" 2>/dev/null; then
        echo -e "${GRAY}💾 Backup created: $backup_file${NC}"
    fi
    
    # Download new version
    local temp_file="/tmp/caddy-selfsteal-update-$$.sh"
    
    if curl -fsSL "$UPDATE_URL" -o "$temp_file" 2>/dev/null; then
        # Verify downloaded file
        if [ -s "$temp_file" ] && head -1 "$temp_file" | grep -q "#!/"; then
            # Get new version from downloaded script
            local new_version=$(grep "^SCRIPT_VERSION=" "$temp_file" | cut -d'"' -f2)
            
            # Check if running as root for system-wide update
            if [ "$EUID" -eq 0 ]; then
                # Update system installation
                if [ -f "/usr/local/bin/$APP_NAME" ]; then
                    cp "$temp_file" "/usr/local/bin/$APP_NAME"
                    chmod +x "/usr/local/bin/$APP_NAME"
                    echo -e "${GREEN}✅ System script updated successfully${NC}"
                fi
                
                # Update current script if different location
                if [ "$0" != "/usr/local/bin/$APP_NAME" ]; then
                    cp "$temp_file" "$0"
                    chmod +x "$0"
                    echo -e "${GREEN}✅ Current script updated successfully${NC}"
                fi
            else
                # User-level update
                cp "$temp_file" "$0"
                chmod +x "$0"
                echo -e "${GREEN}✅ Script updated successfully${NC}"
                echo -e "${YELLOW}💡 Run with sudo to update system-wide installation${NC}"
            fi
            
            rm -f "$temp_file"
            
            echo
            echo -e "${WHITE}🎉 Update completed!${NC}"
            echo -e "${WHITE}📝 Updated to version: ${GRAY}v$new_version${NC}"
            echo -e "${GRAY}Please restart the script to use the new version${NC}"
            echo
            
            read -p "Restart script now? [Y/n]: " -r restart_choice
            if [[ ! $restart_choice =~ ^[Nn]$ ]]; then
                echo -e "${GRAY}Restarting...${NC}"
                exec "$0" "$@"
            fi
        else
            echo -e "${RED}❌ Downloaded file appears to be corrupted${NC}"
            rm -f "$temp_file"
            return 1
        fi
    else
        echo -e "${RED}❌ Failed to download update${NC}"
        rm -f "$temp_file"
        return 1
    fi
}

# Auto-update check (silent)
check_for_updates_silent() {
    # Simple silent check for updates
    if command -v curl >/dev/null 2>&1; then
        local remote_script_version
        remote_script_version=$(timeout 5 curl -s "$UPDATE_URL" 2>/dev/null | grep "^SCRIPT_VERSION=" | cut -d'"' -f2 2>/dev/null)
        
        if [ -n "$remote_script_version" ] && [ "$SCRIPT_VERSION" != "$remote_script_version" ]; then
            echo -e "${YELLOW}💡 Update available: v$remote_script_version (current: v$SCRIPT_VERSION)${NC}"
            echo -e "${GRAY}   Run 'sudo $APP_NAME update' to update${NC}"
            echo
        fi
    fi 2>/dev/null || true  # Suppress any errors completely
}

# Manual update command
update_command() {
    check_running_as_root
    check_for_updates
}

main_menu() {
    # Auto-check for updates on first run
    check_for_updates_silent
    
    while true; do
        clear
        echo -e "${WHITE}🔗 Caddy for Reality Selfsteal${NC}"
        echo -e "${GRAY}Management System v$SCRIPT_VERSION${NC}"
        echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
        echo

        # Show current status
        if [ -f "$APP_DIR/docker-compose.yml" ]; then
            local running_services=$(cd "$APP_DIR" && docker compose ps -q 2>/dev/null | wc -l || echo "0")
            if [ "$running_services" -gt 0 ]; then
                echo -e "${GREEN}✅ Status: Running${NC}"
            else
                echo -e "${RED}❌ Status: Stopped${NC}"
            fi
            
            if [ -f "$APP_DIR/.env" ]; then
                local domain=$(grep "SELF_STEAL_DOMAIN=" "$APP_DIR/.env" | cut -d'=' -f2)
                local port=$(grep "SELF_STEAL_PORT=" "$APP_DIR/.env" | cut -d'=' -f2)
                printf "   ${WHITE}%-10s${NC} ${GRAY}%s${NC}\n" "Domain:" "$domain"
                printf "   ${WHITE}%-10s${NC} ${GRAY}%s${NC}\n" "Port:" "$port"
            fi
        else
            echo -e "${GRAY}📦 Status: Not Installed${NC}"
        fi
        
        echo
        echo -e "${WHITE}📋 Available Operations:${NC}"
        echo
        
        echo -e "${WHITE}🔧 Service Management:${NC}"
        echo -e "   ${WHITE}1)${NC} 🚀 Install Caddy"
        echo -e "   ${WHITE}2)${NC} ▶️  Start services"
        echo -e "   ${WHITE}3)${NC} ⏹️  Stop services"
        echo -e "   ${WHITE}4)${NC} 🔄 Restart services"
        echo -e "   ${WHITE}5)${NC} 📊 Service status"
        echo
        echo -e "${WHITE}🎨 Website Management:${NC}"
        echo -e "   ${WHITE}6)${NC} 🎨 Website templates"
        echo
        echo -e "${WHITE}📝 Configuration & Logs:${NC}"
        echo -e "   ${WHITE}7)${NC} 📝 View logs"
        echo -e "   ${WHITE}8)${NC} 📊 Log sizes"
        echo -e "   ${WHITE}9)${NC} 🧹 Clean logs"
        echo -e "   ${WHITE}10)${NC} ✏️  Edit configuration"
        echo
        echo -e "${WHITE}🗑️  Maintenance:${NC}"
        echo -e "   ${WHITE}11)${NC} 🗑️  Uninstall Caddy"
        echo -e "   ${WHITE}12)${NC} 🔄 Check for updates"
        echo
        echo -e "   ${GRAY}0)${NC} ⬅️  Exit"
        echo

        read -p "$(echo -e "${WHITE}Select option [0-12]:${NC} ")" choice

        case "$choice" in
            1) install_command; read -p "Press Enter to continue..." ;;
            2) up_command; read -p "Press Enter to continue..." ;;
            3) down_command; read -p "Press Enter to continue..." ;;
            4) restart_command; read -p "Press Enter to continue..." ;;
            5) status_command; read -p "Press Enter to continue..." ;;
            6) template_command ;;
            7) logs_command; read -p "Press Enter to continue..." ;;
            8) logs_size_command; read -p "Press Enter to continue..." ;;
            9) clean_logs_command; read -p "Press Enter to continue..." ;;
            10) edit_command; read -p "Press Enter to continue..." ;;
            11) uninstall_command; read -p "Press Enter to continue..." ;;
            12) update_command; read -p "Press Enter to continue..." ;;
            0) clear; exit 0 ;;
            *) 
                echo -e "${RED}❌ Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Main execution
case "$COMMAND" in
    install) install_command ;;
    up) up_command ;;
    down) down_command ;;
    restart) restart_command ;;
    status) status_command ;;
    logs) logs_command ;;
    logs-size) logs_size_command ;;
    clean-logs) clean_logs_command ;;
    edit) edit_command ;;
    uninstall) uninstall_command ;;
    template) template_command ;;
    menu) main_menu ;;
    update) update_command ;;
    check-update) update_command ;;
    help) show_help ;;
    --version|-v) echo "Caddy Selfsteal Management Script v$SCRIPT_VERSION" ;;
    --help|-h) show_help ;;
    "") main_menu ;;
    *) 
        echo -e "${RED}❌ Unknown command: $COMMAND${NC}"
        echo "Use '$APP_NAME --help' for usage information."
        exit 1
        ;;
esac

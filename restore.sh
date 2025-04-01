#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Welcome to Remnawave Backup Restore Script${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${BLUE}This script will restore your Remnawave backup.${NC}"
echo

prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    echo -ne "${prompt} [${default}]: "
    read input
    eval "$var_name=\"${input:-$default}\""
}

echo -e "${YELLOW}📍 Specify the directory where to restore the backup:${NC}"
echo -e "${BLUE}  1) /root/remnawave${NC}"
echo -e "${BLUE}  2) /opt/remnawave${NC}"
echo -e "${BLUE}  3) Enter manually${NC}"
echo -ne "Choose an option (1-3) [2]: "
read choice
choice=${choice:-2}

case $choice in
    1) RESTORE_PATH="/root/remnawave" ;;
    2) RESTORE_PATH="/opt/remnawave" ;;
    3) prompt_input "${YELLOW}Enter the path manually${NC}" RESTORE_PATH "" ;;
    *) RESTORE_PATH="/opt/remnawave" ;;
esac

mkdir -p "$RESTORE_PATH" || { echo -e "${RED}✖ Error: Could not create directory $RESTORE_PATH${NC}"; exit 1; }

echo -e "${YELLOW}📦 Specify the path to the backup archive (.tar.gz):${NC}"
echo -e "${BLUE}Example: /tmp/backup_20250401_112710.tar.gz${NC}"
prompt_input "${BLUE}Enter the path${NC}" BACKUP_ARCHIVE ""

echo -e "${BLUE}Checking archive path: $BACKUP_ARCHIVE${NC}"
if [ -z "$BACKUP_ARCHIVE" ] || [ ! -f "$BACKUP_ARCHIVE" ]; then
    echo -e "${RED}✖ Error: Backup archive not found at '$BACKUP_ARCHIVE'${NC}"
    exit 1
fi

echo -e "${YELLOW}🔧 Choose restore mode:${NC}"
echo -e "${BLUE}  1) Full restore (replace all files and database)${NC}"
echo -e "${BLUE}  2) Restore only database (keep existing files)${NC}"
echo -ne "Choose an option (1-2) [1]: "
read mode
mode=${mode:-1}

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Docker not found. Installing Docker...${NC}"
    curl -fsSL https://get.docker.com | sh
    if [ $? -ne 0 ]; then
        echo -e "${RED}✖ Error: Failed to install Docker${NC}"
        exit 1
    fi
    systemctl start docker
    systemctl enable docker
fi

if ! docker compose version >/dev/null 2>&1; then
    echo -e "${RED}✖ Error: Docker Compose V2 (docker compose) is required but not found.${NC}"
    echo -e "${BLUE}Please ensure you have a recent version of Docker installed.${NC}"
    exit 1
fi

if [ "$mode" = "1" ]; then
    echo -e "${BLUE}Extracting backup archive to $RESTORE_PATH...${NC}"
    tar -xzvf "$BACKUP_ARCHIVE" -C "$RESTORE_PATH"
    if [ $? -ne 0 ]; then
        echo -e "${RED}✖ Error: Failed to extract archive${NC}"
        exit 1
    fi
fi

if [ -f "$RESTORE_PATH/docker-compose.yml" ]; then
    cd "$RESTORE_PATH" || { echo -e "${RED}✖ Error: Could not change to $RESTORE_PATH${NC}"; exit 1; }
    if [ "$mode" = "2" ]; then
        tar -xzf "$BACKUP_ARCHIVE" -C "$RESTORE_PATH" ./db_backup.sql --strip-components=1
        if [ $? -ne 0 ]; then
            echo -e "${RED}✖ Error: Failed to extract db_backup.sql from archive${NC}"
            exit 1
        fi
    fi

    if [ -f "$RESTORE_PATH/.env" ]; then
        echo -e "${GREEN}✔ Found .env file, loading database credentials...${NC}"
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            key=$(echo "$key" | tr -d '[:space:]')
            value=$(echo "$value" | tr -d '[:space:]')
            export "$key=$value"
        done < "$RESTORE_PATH/.env"
    else
        echo -e "${YELLOW}⚠ No .env file found in $RESTORE_PATH${NC}"
    fi

    if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_DB" ]; then
        echo -e "${YELLOW}⚠ Database credentials not found in .env or environment.${NC}"
        prompt_input "${BLUE}Enter PostgreSQL username${NC}" POSTGRES_USER "postgres"
        prompt_input "${BLUE}Enter PostgreSQL database name${NC}" POSTGRES_DB "remnawave"
    fi

    echo -e "${BLUE}Starting all containers to initialize databases...${NC}"
    docker compose up -d
    if [ $? -ne 0 ]; then
        echo -e "${RED}✖ Error: Failed to start containers${NC}"
        exit 1
    fi

    echo -e "${BLUE}Waiting for containers to fully start (20 seconds)...${NC}"
    sleep 20

    echo -e "${BLUE}Stopping all containers...${NC}"
    docker compose down
    if [ $? -ne 0 ]; then
        echo -e "${RED}✖ Error: Failed to stop containers${NC}"
        exit 1
    fi

    if [ -f "$RESTORE_PATH/db_backup.sql" ]; then
        echo -e "${YELLOW}⚠ Warning: This will replace all data in the database '$POSTGRES_DB' as user '$POSTGRES_USER'.${NC}"
        echo -ne "${BLUE}Do you want to proceed? (y/N): ${NC}"
        read confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "${RED}✖ Restore aborted by user${NC}"
            exit 1
        fi

        echo -e "${BLUE}Starting database container...${NC}"
        docker compose up -d remnawave-db
        if [ $? -ne 0 ]; then
            echo -e "${RED}✖ Error: Failed to start remnawave-db${NC}"
            exit 1
        fi

        echo -e "${BLUE}Waiting for database container to be ready (10 seconds)...${NC}"
        sleep 10

        echo -e "${BLUE}Dropping and recreating database '$POSTGRES_DB'...${NC}"
        docker exec remnawave-db psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS $POSTGRES_DB;"
        if [ $? -ne 0 ]; then
            echo -e "${RED}✖ Error: Failed to drop database${NC}"
            docker compose logs remnawave-db
            exit 1
        fi
        docker exec remnawave-db psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE $POSTGRES_DB;"
        if [ $? -ne 0 ]; then
            echo -e "${RED}✖ Error: Failed to create database${NC}"
            docker compose logs remnawave-db
            exit 1
        fi

        echo -e "${BLUE}Restoring database dump...${NC}"
        docker exec -i remnawave-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$RESTORE_PATH/db_backup.sql"
        if [ $? -ne 0 ]; then
            echo -e "${RED}✖ Error: Failed to restore database${NC}"
            docker compose logs remnawave-db
            exit 1
        fi
        echo -e "${GREEN}✔ Database restored successfully${NC}"

        echo -e "${BLUE}Stopping database container...${NC}"
        docker compose down
        if [ $? -ne 0 ]; then
            echo -e "${RED}✖ Error: Failed to stop remnawave-db${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}⚠ No db_backup.sql found, skipping database restore${NC}"
    fi

    echo -e "${BLUE}Starting all containers...${NC}"
    docker compose up -d
    if [ $? -ne 0 ]; then
        echo -e "${RED}✖ Error: Failed to start containers${NC}"
        exit 1
    fi
else
    echo -e "${RED}✖ Error: docker-compose.yml not found. Required for database restore.${NC}"
    exit 1
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Backup restored successfully at: $RESTORE_PATH${NC}"
echo -e "${GREEN}   Containers are running.${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${BLUE}Check container status with: ${YELLOW}docker compose ps${NC}"

#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Welcome to Remnawave Backup Installer        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo -e "${BLUE}This script will create a ${YELLOW}backup.sh${BLUE} file with your settings.${NC}"
echo

prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    read -p "$prompt [$default]: " input
    eval "$var_name=\"${input:-$default}\""
}

echo -e "${YELLOW}📍 Specify the path to docker-compose.yml for Remnawave:${NC}"
echo -e "${BLUE}  1) /root/remnawave${NC}"
echo -e "${BLUE}  2) /opt/remnawave${NC}"
echo -e "${BLUE}  3) Enter manually${NC}"
echo -e "${GREEN}Note:${NC} Info from .env and other files will be read from this path."
read -p "Choose an option (1-3) [2]: " choice
choice=${choice:-2}

case $choice in
    1) COMPOSE_PATH="/root/remnawave" ;;
    2) COMPOSE_PATH="/opt/remnawave" ;;
    3) prompt_input "${YELLOW}Enter the path manually${NC}" COMPOSE_PATH "" ;;
    *) COMPOSE_PATH="/opt/remnawave" ;;
esac

if [ ! -f "$COMPOSE_PATH/docker-compose.yml" ]; then
    echo -e "${RED}✖ Error: docker-compose.yml not found at $COMPOSE_PATH${NC}"
    exit 1
fi

if [ -f "$COMPOSE_PATH/.env" ]; then
    echo -e "${GREEN}✔ .env file found at $COMPOSE_PATH. Using it for DB connection.${NC}"
    USE_ENV=true
else
    echo -e "${YELLOW}⚠ .env file not found at $COMPOSE_PATH.${NC}"
    echo -e "${BLUE}You’ll need to enter DB connection details manually.${NC}"
    USE_ENV=false
    prompt_input "${YELLOW}Enter POSTGRES_USER${NC}" POSTGRES_USER "postgres"
    prompt_input "${YELLOW}Enter POSTGRES_DB${NC}" POSTGRES_DB "postgres"
fi

echo -e "${YELLOW}📡 Telegram Settings:${NC}"
prompt_input "${BLUE}Enter Telegram Bot Token (from @BotFather)${NC}" TELEGRAM_BOT_TOKEN ""
prompt_input "${BLUE}Enter Telegram Chat/Channel ID (e.g., -1001234567890)${NC}" TELEGRAM_CHAT_ID ""

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo -e "${RED}✖ Error: Telegram Bot Token and Chat ID are required!${NC}"
    exit 1
fi

BACKUP_SCRIPT="$COMPOSE_PATH/backup.sh"
cat << EOF > "$BACKUP_SCRIPT"
#!/bin/bash
cd "$COMPOSE_PATH" || { echo "Error: Could not change to $COMPOSE_PATH"; exit 1; }
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
fi
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
BACKUP_DIR="/tmp/backup_\$(date +%Y%m%d_%H%M%S)"
BACKUP_DATE="\$(date '+%Y-%m-%d %H:%M:%S UTC')"
ARCHIVE_NAME="\$BACKUP_DIR.tar.gz"
MAX_SIZE_MB=49
mkdir -p "\$BACKUP_DIR"
EOF

if [ "$USE_ENV" = true ]; then
    cat << EOF >> "$BACKUP_SCRIPT"
docker exec remnawave-db pg_dump -U "\$POSTGRES_USER" -d "\$POSTGRES_DB" > "\$BACKUP_DIR/db_backup.sql"
EOF
else
    cat << EOF >> "$BACKUP_SCRIPT"
docker exec remnawave-db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" > "\$BACKUP_DIR/db_backup.sql"
EOF
fi

cat << 'EOF' >> "$BACKUP_SCRIPT"
if [ $? -ne 0 ]; then
    echo "Error: Failed to create database backup"
    exit 1
fi
cp docker-compose.yml "$BACKUP_DIR/" || { echo "Error: Failed to copy docker-compose.yml"; exit 1; }
[ -f .env ] && cp .env "$BACKUP_DIR/" || echo "File .env not found, skipping"
[ -f app-config.json ] && cp app-config.json "$BACKUP_DIR/" || echo "File app-config.json not found, skipping"
CONTENTS=""
[ -f "$BACKUP_DIR/db_backup.sql" ] && CONTENTS="$CONTENTS📋 db_backup.sql\n"
[ -f "$BACKUP_DIR/docker-compose.yml" ] && CONTENTS="$CONTENTS📄 docker-compose.yml\n"
[ -f "$BACKUP_DIR/.env" ] && CONTENTS="$CONTENTS🔑 .env\n"
[ -f "$BACKUP_DIR/app-config.json" ] && CONTENTS="$CONTENTS⚙️ app-config.json\n"
escape_markdown() {
    local text="$1"
    echo "$text" | sed 's/[[\.*_(){}|#+-]/\\&/g'
}
MESSAGE=$(cat << 'MSG'
🔔 *Remnawave Backup*
📅 Date: $(escape_markdown "$BACKUP_DATE")
📦 Archive contents:
$(escape_markdown "$CONTENTS")
MSG
)
tar -czvf "$ARCHIVE_NAME" -C "$BACKUP_DIR" .
if [ $? -ne 0 ]; then
    echo "Error: Failed to create archive"
    exit 1
fi
ARCHIVE_SIZE=$(du -m "$ARCHIVE_NAME" | cut -f1)
if [ "$ARCHIVE_SIZE" -gt "$MAX_SIZE_MB" ]; then
    echo "Archive size ($ARCHIVE_SIZE MB) exceeds $MAX_SIZE_MB MB, splitting into parts..."
    split -b 49m "$ARCHIVE_NAME" "$BACKUP_DIR/part_"
    PARTS=("$BACKUP_DIR"/part_*)
    PART_COUNT=${#PARTS[@]}
    for i in "${!PARTS[@]}"; do
        PART_FILE="${PARTS[$i]}"
        PART_NUM=$((i + 1))
        PART_MESSAGE=$(cat << 'PART_MSG'
🔔 *Remnawave Backup (Part $PART_NUM of $PART_COUNT)*
📅 Date: $(escape_markdown "$BACKUP_DATE")
📦 Archive contents:
$(escape_markdown "$CONTENTS")
PART_MSG
)
        curl -F chat_id="$TELEGRAM_CHAT_ID" \
             -F document=@"$PART_FILE" \
             -F caption="$PART_MESSAGE" \
             -F parse_mode="MarkdownV2" \
             "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -o telegram_response.json
        if [ $? -ne 0 ] || grep -q '"ok":false' telegram_response.json; then
            echo "Error sending part $PART_NUM:"
            cat telegram_response.json
            exit 1
        fi
        echo "Part $PART_NUM of $PART_COUNT sent successfully"
    done
else
    curl -F chat_id="$TELEGRAM_CHAT_ID" \
         -F document=@"$ARCHIVE_NAME" \
         -F caption="$MESSAGE" \
         -F parse_mode="MarkdownV2" \
         "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -o telegram_response.json
    if [ $? -ne 0 ]; then
        echo "Error sending archive to Telegram"
        cat telegram_response.json
        exit 1
    fi
    if grep -q '"ok":false' telegram_response.json; then
        echo "Telegram returned an error:"
        cat telegram_response.json
    else
        echo "Archive successfully sent to Telegram"
    fi
fi
rm -rf "$BACKUP_DIR"
rm "$ARCHIVE_NAME"
rm telegram_response.json
EOF

chmod +x "$BACKUP_SCRIPT"

echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║ Backup script created successfully at: $BACKUP_SCRIPT ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo -e "${BLUE}To run it, use: ${YELLOW}$BACKUP_SCRIPT${NC}"
echo -e "${BLUE}To add to crontab, run '${YELLOW}crontab -e${BLUE}' and add, e.g.:${NC}"
echo -e "${YELLOW}0 2 * * * $BACKUP_SCRIPT${NC}"

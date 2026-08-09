#!/bin/bash

# Configuration
BACKUP_DIR="/mnt/16tb/3010-backup/home/njohn/nextcloud_aio/manual-install/backups" # Change this to your safe backup location
DB_USER="nextcloud"                       # Change to your Postgres username
DB_NAME="nextcloud_database"                       # Change to your Postgres database name
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
CURRENT_BACKUP="$BACKUP_DIR/$TIMESTAMP"
PROJECT_NAME="nextcloud_aio"

# Setup directories
mkdir -p "$CURRENT_BACKUP"
cd "$(dirname "$0")" # Switch to the docker-compose project directory

echo "🔄 Step 1: Enabling Nextcloud Maintenance Mode..."
docker exec --user www-data  manual-install-nextcloud-aio-nextcloud-1 php occ maintenance:mode --on

echo "🗄️ Step 2: Exporting Postgres Database..."
docker exec -t manual-install-nextcloud-aio-database-1 pg_dump -U "$DB_USER" "$DB_NAME" > "$CURRENT_BACKUP/nextcloud-database.sql"

echo "🔓 Step 3: Disabling Maintenance Mode (Minimises Downtime)..."
docker exec --user www-data app php occ maintenance:mode --off

echo "📦 Step 4: Backing up Docker Volumes..."

# Back up the container's volume

docker run --rm \
  -v "${PROJECT_NAME}_apache:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  ubuntu tar -cpzf /backup/apache-data.tar.gz -C /data .

docker run --rm \
  -v "${PROJECT_NAME}_database:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  ubuntu tar -cpzf /backup/database-data.tar.gz -C /data .

docker run --rm \
  -v "${PROJECT_NAME}_database_dump:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  ubuntu tar -cpzf /backup/database-dump-data.tar.gz -C /data .

docker run --rm \
  -v "${PROJECT_NAME}_nextcloud:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  ubuntu tar -cpzf /backup/nextcloud-data.tar.gz -C /data .

docker run --rm \
  -v "${PROJECT_NAME}_redis:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  ubuntu tar -cpzf /backup/apache-redis.tar.gz -C /data .

echo "✅ Backup Complete! Saved to: $CURRENT_BACKUP"


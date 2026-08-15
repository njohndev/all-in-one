#!/bin/bash
set -euo pipefail

# Configuration
# Change BACKUP_DIR to your safe backup location (must be writable).
BACKUP_DIR="${BACKUP_DIR:-/mnt/backups/nextcloud_aio}"
DB_USER="${DB_USER:-nextcloud}"                       # Change to your Postgres username
DB_NAME="${DB_NAME:-nextcloud_database}"              # Change to your Postgres database name
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
CURRENT_BACKUP="$BACKUP_DIR/$TIMESTAMP"
PROJECT_NAME="nextcloud_aio"
NEXTCLOUD_CONTAINER="manual-install-nextcloud-aio-nextcloud-1"
DATABASE_CONTAINER="manual-install-nextcloud-aio-database-1"
# Pin the helper image used for volume archiving to avoid supply-chain drift.
BACKUP_HELPER_IMAGE="${BACKUP_HELPER_IMAGE:-ubuntu:24.04}"

# Always try to bring Nextcloud out of maintenance mode, even if a later step fails.
restore_maintenance_mode() {
  docker exec --user www-data "$NEXTCLOUD_CONTAINER" php occ maintenance:mode --off || true
}
trap restore_maintenance_mode EXIT

# Setup directories
mkdir -p "$CURRENT_BACKUP"
cd "$(dirname "$0")" # Switch to the docker-compose project directory

echo "🔄 Step 1: Enabling Nextcloud Maintenance Mode..."
docker exec --user www-data "$NEXTCLOUD_CONTAINER" php occ maintenance:mode --on

echo "🗄️ Step 2: Exporting Postgres Database..."
docker exec -t "$DATABASE_CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" > "$CURRENT_BACKUP/nextcloud-database.sql"

echo "🔓 Step 3: Disabling Maintenance Mode (Minimises Downtime)..."
restore_maintenance_mode

echo "📦 Step 4: Backing up Docker Volumes..."

# Back up the container's volume

docker run --rm \
  -v "${PROJECT_NAME}_apache:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  "$BACKUP_HELPER_IMAGE" tar -cpzf /backup/apache-data.tar.gz -C /data .

docker run --rm \
  -v "${PROJECT_NAME}_database:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  "$BACKUP_HELPER_IMAGE" tar -cpzf /backup/database-data.tar.gz -C /data .

docker run --rm \
  -v "${PROJECT_NAME}_database_dump:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  "$BACKUP_HELPER_IMAGE" tar -cpzf /backup/database-dump-data.tar.gz -C /data .

docker run --rm \
  -v "${PROJECT_NAME}_nextcloud:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  "$BACKUP_HELPER_IMAGE" tar -cpzf /backup/nextcloud-data.tar.gz -C /data .

docker run --rm \
  -v "${PROJECT_NAME}_redis:/data" \
  -v "$CURRENT_BACKUP:/backup" \
  "$BACKUP_HELPER_IMAGE" tar -cpzf /backup/apache-redis.tar.gz -C /data .

echo "✅ Backup Complete! Saved to: $CURRENT_BACKUP"


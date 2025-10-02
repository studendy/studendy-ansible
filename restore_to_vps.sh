#!/usr/bin/env bash
set -Eeuo pipefail

# Local helper to upload a backup bundle to a new VPS and run remote provisioning+restore in one go.

# Usage example:
#   ./restore_to_vps.sh \
#     --host 203.0.113.10 \
#     --user root \
#     --backup /path/to/studendy_20251001_123000.tar.gz \
#     --domain studendy.com \
#     --email admin@studendy.com \
#     --app-dir /var/www/html/studendy \
#     --php 8.2

HOST=""
USER="root"
BACKUP=""
DOMAIN=""
ADMIN_EMAIL=""
APP_DIR="/var/www/html/studendy"
PHP_VERSION="8.2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --user) USER="$2"; shift 2;;
    --backup) BACKUP="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --email) ADMIN_EMAIL="$2"; shift 2;;
    --app-dir) APP_DIR="$2"; shift 2;;
    --php) PHP_VERSION="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "$HOST" || -z "$BACKUP" || -z "$DOMAIN" || -z "$ADMIN_EMAIL" ]]; then
  echo "Missing required args. See usage in file header."; exit 1;
fi

if [ ! -f "$BACKUP" ]; then
  echo "Backup file not found: $BACKUP"; exit 1;
fi

REMOTE=/root
BACKUP_BASENAME="$(basename "$BACKUP")"

echo "Uploading provisioning script and backup to ${USER}@${HOST}..."
scp -o StrictHostKeyChecking=accept-new provision_studendy.sh "${USER}@${HOST}:${REMOTE}/"
scp -o StrictHostKeyChecking=accept-new "$BACKUP" "${USER}@${HOST}:${REMOTE}/"

echo "Running remote provisioning + restore... (this can take a while)"
ssh -o StrictHostKeyChecking=accept-new "${USER}@${HOST}" \
  "chmod +x ${REMOTE}/provision_studendy.sh && DOMAIN='${DOMAIN}' ADMIN_EMAIL='${ADMIN_EMAIL}' APP_DIR='${APP_DIR}' PHP_VERSION='${PHP_VERSION}' BACKUP_BUNDLE='${REMOTE}/${BACKUP_BASENAME}' RESTORE_MODE=1 ${REMOTE}/provision_studendy.sh"

echo "Done. Visit https://${DOMAIN} after DNS points to the server."


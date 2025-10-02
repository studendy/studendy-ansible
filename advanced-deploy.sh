#!/bin/bash
set -Eeuo pipefail
umask 022

APP_PATH="/var/www/html/studendy"
BACKUP_PATH="/var/www/html/backups"
DATE="$(date +%Y%m%d_%H%M%S)"
HEALTH_URL="https://studendy.com/"
BRANCH="main"

# Optional DB backup config (override via env). If not set, try reading from .env
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-}"

echo "🚀 Starting production deployment..."
echo "📅 Date: $(date)"
echo "📍 Path: ${APP_PATH}"

# Preflight
echo "🔍 Running preflight checks..."
for cmd in git composer npm php curl rsync; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "❌ $cmd not found"; exit 1; }
done
[ -d "${APP_PATH}" ] || { echo "❌ APP_PATH not found"; exit 1; }
mkdir -p "${BACKUP_PATH}"

git config --global --add safe.directory "${APP_PATH}" >/dev/null 2>&1 || true
echo "✅ Preflight checks passed"

rollback() {
    echo "❌ Deployment failed! Rolling back..."
    php "${APP_PATH}/artisan" up 2>/dev/null || true

    if [ -d "${BACKUP_PATH}/studendy_${DATE}" ]; then
        echo "📦 Restoring application files from backup..."
        mkdir -p "${APP_PATH}"
        rsync -a --delete \
            --exclude='node_modules' \
            --exclude='db.sql' \
            --exclude='nginx' \
            --exclude='php-fpm' \
            "${BACKUP_PATH}/studendy_${DATE}/" "${APP_PATH}/"

        if [ ! -d "${APP_PATH}/vendor" ]; then
            echo "📚 Restoring vendor..."
            COMPOSER_ALLOW_SUPERUSER=1 composer --working-dir="${APP_PATH}" install \
                --no-dev --prefer-dist --no-ansi --no-progress --no-interaction --optimize-autoloader || true
        fi

        systemctl reload nginx || true
        systemctl reload php8.2-fpm || true
        php "${APP_PATH}/artisan" queue:restart 2>/dev/null || true
        echo "✅ Rollback completed"
    fi
    exit 1
}
trap rollback ERR

# Deployment steps (tidak ada sudo)
cd "${APP_PATH}"
php artisan down --render="errors::503" --retry=60

rsync -a --delete --exclude='node_modules' \
    "${APP_PATH}/" "${BACKUP_PATH}/studendy_${DATE}/"

# Attempt to hydrate DB config from Laravel .env if not provided by env
if [ -f "${APP_PATH}/.env" ]; then
    [ -z "${DB_NAME}" ] && DB_NAME="$(grep -E '^DB_DATABASE=' "${APP_PATH}/.env" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
    [ -z "${DB_USER}" ] && DB_USER="$(grep -E '^DB_USERNAME=' "${APP_PATH}/.env" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
    [ -z "${DB_PASS}" ] && DB_PASS="$(grep -E '^DB_PASSWORD=' "${APP_PATH}/.env" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
    [ -z "${DB_HOST}" ] && DB_HOST="$(grep -E '^DB_HOST=' "${APP_PATH}/.env" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
    [ -z "${DB_PORT}" ] && DB_PORT="$(grep -E '^DB_PORT=' "${APP_PATH}/.env" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
fi

# Step 2b: Backup database (optional)
if command -v mysqldump >/dev/null 2>&1; then
    echo "🗄️ Dumping database..."
    DB_DUMP_PATH="${BACKUP_PATH}/studendy_${DATE}/db.sql"
    MYSQL_HOST_OPTS=()
    [ -n "${DB_HOST}" ] && MYSQL_HOST_OPTS+=( -h "${DB_HOST}" )
    [ -n "${DB_PORT}" ] && MYSQL_HOST_OPTS+=( -P "${DB_PORT}" )
    MYSQL_AUTH_OPTS=( -u "${DB_USER:-root}" )
    [ -n "${DB_PASS}" ] && MYSQL_AUTH_OPTS+=( --password="${DB_PASS}" )
    if [ -n "${DB_NAME}" ]; then
        mysqldump "${MYSQL_HOST_OPTS[@]}" "${MYSQL_AUTH_OPTS[@]}" "${DB_NAME}" > "${DB_DUMP_PATH}" || echo "⚠️ Database backup failed"
    else
        echo "ℹ️ DB_NAME not set and not found in .env, skipping DB backup"
    fi
    [ -s "${DB_DUMP_PATH}" ] && echo "✅ Database backup created" || echo "⚠️ Empty or missing DB dump"
else
    echo "ℹ️ mysqldump not found, skipping database backup"
fi

# Step 2c: Backup nginx and php-fpm configs
echo "🛠️ Backing up nginx & php-fpm configs..."
mkdir -p "${BACKUP_PATH}/studendy_${DATE}/nginx" "${BACKUP_PATH}/studendy_${DATE}/php-fpm"
rsync -a /etc/nginx/sites-enabled/ "${BACKUP_PATH}/studendy_${DATE}/nginx/" 2>/dev/null || echo "ℹ️ Skipped nginx configs (permission or path)"
rsync -a /etc/php/8.2/fpm/pool.d/ "${BACKUP_PATH}/studendy_${DATE}/php-fpm/" 2>/dev/null || echo "ℹ️ Skipped php-fpm configs (permission or path)"

# Step 2d: Create compressed archive for easy migration
if command -v tar >/dev/null 2>&1; then
    echo "🗜️ Creating backup archive..."
    (cd "${BACKUP_PATH}" && tar -czf "studendy_${DATE}.tar.gz" "studendy_${DATE}") && echo "✅ Archive created at ${BACKUP_PATH}/studendy_${DATE}.tar.gz"
else
    echo "ℹ️ tar not found, skipping archive creation"
fi

git fetch origin "${BRANCH}"
git reset --hard "origin/${BRANCH}"

COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev --prefer-dist --no-ansi --no-progress --no-interaction --optimize-autoloader

npm ci --silent --no-progress
npm run build --silent

php artisan migrate --force --no-interaction

php artisan optimize:clear
php artisan optimize

chown -R www-data:www-data storage bootstrap/cache
find storage bootstrap/cache -type d -exec chmod 775 {} +
find storage bootstrap/cache -type f -exec chmod 664 {} +

systemctl daemon-reload
php artisan queue:restart || true
systemctl reload php8.2-fpm
systemctl reload nginx
php artisan up

ok=0
for i in {1..5}; do
    if curl -fsS -o /dev/null "${HEALTH_URL}"; then 
        ok=1; break
    fi
    sleep 3
done
[ "$ok" -eq 1 ] || rollback

cd "${BACKUP_PATH}"
ls -dt studendy_* 2>/dev/null | tail -n +6 | xargs -r rm -rf

echo "🎉 Deployment completed successfully!"

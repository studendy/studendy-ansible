#!/bin/bash
set -Eeuo pipefail
umask 022

APP_PATH="/var/www/html/studendy"
BACKUP_PATH="/var/www/html/backups"
DATE="$(date +%Y%m%d_%H%M%S)"
HEALTH_URL="https://studendy.com/"
BRANCH="main"

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
        cd / || true
        rm -rf "${APP_PATH}"
        mv "${BACKUP_PATH}/studendy_${DATE}" "${APP_PATH}"

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

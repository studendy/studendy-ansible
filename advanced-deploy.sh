#!/bin/bash

# Zero-downtime deploy script for Laravel (symlink releases)
#
# Folder layout (update your web server root to current/public):
#   /var/www/html/studendy
#     ├─ current -> releases/<timestamp>
#     ├─ releases/
#     └─ shared/ (contains .env, storage, etc.)

set -Eeuo pipefail
umask 022

# === Config ===
APP_BASE="/var/www/html/studendy"
RELEASES_DIR="${APP_BASE}/releases"
SHARED_DIR="${APP_BASE}/shared"
CURRENT_LINK="${APP_BASE}/current"

BRANCH="main"
DATE="$(date +%Y%m%d_%H%M%S)"
HEALTH_URL="https://studendy.com/"   # post-switch health URL
KEEP_RELEASES=5
PHP_FPM_SERVICE="php8.2-fpm"
MIGRATE_BEFORE_SWITCH=1               # requires expand/contract migrations

echo "🚀 Zero-downtime deployment starting"
echo "📅 Date: $(date)"
echo "📍 Base: ${APP_BASE}"

# === Preflight ===
echo "🔍 Running preflight checks..."
for cmd in git composer php rsync; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ $cmd not found"; exit 1; }
done
# npm is optional (only if package-lock.json exists)
command -v npm >/dev/null 2>&1 || echo "ℹ️ npm not found, skipping frontend build"

mkdir -p "${RELEASES_DIR}" "${SHARED_DIR}"

# Determine repository source (legacy current dir or current symlink)
REPO_DIR=""
if [ -L "${CURRENT_LINK}" ] && [ -d "${CURRENT_LINK}/.git" ]; then
  REPO_DIR="${CURRENT_LINK}"
elif [ -d "${APP_BASE}/.git" ]; then
  REPO_DIR="${APP_BASE}"
else
  echo "❌ Cannot find a git repository in ${CURRENT_LINK} or ${APP_BASE}"
  exit 1
fi

git config --global --add safe.directory "${REPO_DIR}" >/dev/null 2>&1 || true
echo "✅ Preflight checks passed"

# === Prepare new release ===
NEW_RELEASE="${RELEASES_DIR}/${DATE}"
echo "📦 Creating release: ${NEW_RELEASE}"
mkdir -p "${NEW_RELEASE}"

cleanup_on_error() {
  echo "🧹 Cleaning up failed release ${NEW_RELEASE}"
  rm -rf "${NEW_RELEASE}" || true
}

rollback() {
  local reason="$1"; shift || true
  echo "❌ Deployment failed: ${reason}"

  # If we already switched, relink to previous release
  if [ "${SWITCHED:-0}" -eq 1 ] && [ -n "${PREV_RELEASE:-}" ] && [ -d "${PREV_RELEASE}" ]; then
    echo "↩️  Rolling back to previous release: ${PREV_RELEASE}"
    ln -sfn "${PREV_RELEASE}" "${CURRENT_LINK}"
    systemctl reload "${PHP_FPM_SERVICE}" || true
    systemctl reload nginx || true
  else
    cleanup_on_error
  fi
  exit 1
}
trap 'rollback "unexpected error"' ERR

# Record previous release for rollback
if [ -L "${CURRENT_LINK}" ]; then
  PREV_RELEASE="$(readlink -f "${CURRENT_LINK}")"
else
  PREV_RELEASE=""
fi

echo "📤 Syncing source working tree to new release"
# Avoid recursion when REPO_DIR is the base that contains releases/shared/current
rsync -a --delete \
  --exclude='storage' \
  --exclude='node_modules' \
  --exclude='.env' \
  --exclude='releases' \
  --exclude='shared' \
  --exclude='current' \
  "${REPO_DIR}/" "${NEW_RELEASE}/"

echo "🔄 Updating git to origin/${BRANCH}"
git -C "${NEW_RELEASE}" fetch origin "${BRANCH}"
git -C "${NEW_RELEASE}" reset --hard "origin/${BRANCH}"
git config --global --add safe.directory "${NEW_RELEASE}" >/dev/null 2>&1 || true

# === Link shared resources ===
echo "🔗 Linking shared resources"
mkdir -p "${SHARED_DIR}/storage" "${NEW_RELEASE}/bootstrap/cache"

# .env
if [ ! -f "${SHARED_DIR}/.env" ]; then
  if [ -f "${REPO_DIR}/.env" ]; then
    cp "${REPO_DIR}/.env" "${SHARED_DIR}/.env"
  else
    echo "❌ ${SHARED_DIR}/.env not found and no template at ${REPO_DIR}/.env"
    cleanup_on_error; exit 1
  fi
fi
ln -sfn "${SHARED_DIR}/.env" "${NEW_RELEASE}/.env"

# storage directory: move on first setup, then symlink
if [ ! -d "${SHARED_DIR}/storage" ] && [ -d "${NEW_RELEASE}/storage" ]; then
  mv "${NEW_RELEASE}/storage" "${SHARED_DIR}/storage"
fi
rm -rf "${NEW_RELEASE}/storage"
ln -sfn "${SHARED_DIR}/storage" "${NEW_RELEASE}/storage"

# Ensure required Laravel storage subdirectories exist for artisan/composer scripts
mkdir -p \
  "${SHARED_DIR}/storage/framework" \
  "${SHARED_DIR}/storage/framework/cache" \
  "${SHARED_DIR}/storage/framework/sessions" \
  "${SHARED_DIR}/storage/framework/views" \
  "${SHARED_DIR}/storage/logs"

# === Install dependencies ===
echo "📚 Installing Composer dependencies (prod)"
COMPOSER_ALLOW_SUPERUSER=1 composer --working-dir="${NEW_RELEASE}" install \
  --no-dev --prefer-dist --no-ansi --no-progress --no-interaction --optimize-autoloader

if [ -f "${NEW_RELEASE}/package-lock.json" ] && command -v npm >/dev/null 2>&1; then
  echo "🧰 Installing Node deps and building assets"
  (cd "${NEW_RELEASE}" && npm ci --silent --no-progress && npm run build --silent)
else
  echo "ℹ️ Skipping frontend build (no package-lock.json or npm missing)"
fi

# Ensure storage link for public files
php "${NEW_RELEASE}/artisan" storage:link >/dev/null 2>&1 || true

# === Optimize & (optionally) migrate before switch ===
echo "⚙️  Optimizing caches"
php "${NEW_RELEASE}/artisan" optimize:clear
php "${NEW_RELEASE}/artisan" optimize

if [ "${MIGRATE_BEFORE_SWITCH}" -eq 1 ]; then
  echo "🗄️  Running DB migrations (expand-only)"
  php "${NEW_RELEASE}/artisan" migrate --force --no-interaction
fi

# Lightweight CLI health check for the new release
echo "🩺 Verifying new release (CLI check)"
php "${NEW_RELEASE}/artisan" about >/dev/null

# === Switch current symlink atomically ===
echo "🔁 Switching current symlink"
SWITCHED=0
ln -sfn "${NEW_RELEASE}" "${CURRENT_LINK}"
SWITCHED=1

echo "🔄 Reloading services"
systemctl daemon-reload || true
php "${CURRENT_LINK}/artisan" queue:restart || true
systemctl reload "${PHP_FPM_SERVICE}" || true
systemctl reload nginx || true

# Post-switch health check over HTTP
echo "🌐 Performing HTTP health check"
ok=0
for i in {1..5}; do
  if curl -fsS -o /dev/null "${HEALTH_URL}"; then ok=1; break; fi
  sleep 3
done
[ "$ok" -eq 1 ] || rollback "health check failed"

# === Cleanup old releases ===
echo "🧹 Pruning old releases (keep ${KEEP_RELEASES})"
cd "${RELEASES_DIR}"
# shellcheck disable=SC2012
for rel in $(ls -dt */ 2>/dev/null | sed 's#/##' | grep -v "$(basename "${NEW_RELEASE}")" | tail -n +$((KEEP_RELEASES))); do
  rm -rf "${RELEASES_DIR}/${rel}"
done

echo "🎉 Deployment completed successfully!"

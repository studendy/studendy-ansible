#!/usr/bin/env bash
set -Eeuo pipefail

# Studendy one-shot server bootstrap + deploy script (Ubuntu/Debian)
# Run as root on a fresh VPS. Adjust variables below as needed.

########################################
#            CONFIGURATION              #
########################################
DOMAIN="yourdomain.com"                 # e.g. studendy.com
ADMIN_EMAIL="admin@yourdomain.com"      # email for Let's Encrypt
REPO_URL="https://github.com/studendy/Studendy.com.git"
BRANCH="main"

APP_DIR="/var/www/studendy"
PHP_VERSION="8.2"                        # 8.2 recommended

# Database
DB_NAME="studendy_production"
DB_USER="studendy"
DB_PASS="secure_password"

# Optional: path to backup bundle (tar.gz or extracted dir) to auto-import DB settings
# Example: BACKUP_BUNDLE=/root/studendy_20251001_123000.tar.gz
BACKUP_BUNDLE=""

# Optional: Node.js major version
NODE_MAJOR="18"

########################################
#           HELPER FUNCTIONS           #
########################################
log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[OK]\033[0m  $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR] $*\033[0m" >&2; }

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    err "Please run as root (use sudo)."; exit 1; fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

########################################
#              PRECHECKS               #
########################################
require_root
log "Bootstrapping Studendy server for domain: ${DOMAIN}"

if ! grep -Ei 'ubuntu|debian' /etc/os-release >/dev/null 2>&1; then
  warn "This script targets Ubuntu/Debian. Proceeding anyway."
fi

########################################
#         SYSTEM PREPARATION           #
########################################
log "Updating system and installing base packages"
apt update -y
DEBIAN_FRONTEND=noninteractive apt upgrade -y
DEBIAN_FRONTEND=noninteractive apt install -y \
  ca-certificates curl gnupg lsb-release software-properties-common \
  nginx mysql-server redis-server supervisor \
  git unzip rsync ufw fail2ban

# PHP + extensions
log "Installing PHP ${PHP_VERSION} and extensions"
DEBIAN_FRONTEND=noninteractive apt install -y \
  php${PHP_VERSION} php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-redis \
  php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip \
  php${PHP_VERSION}-gd php${PHP_VERSION}-intl php${PHP_VERSION}-bcmath php${PHP_VERSION}-opcache || {
    warn "PHP ${PHP_VERSION} packages not found in default repos. You may need to add a PPA (e.g., Ondrej) and rerun."; exit 1; }

# Composer
if ! cmd_exists composer; then
  log "Installing Composer"
  curl -sS https://getcomposer.org/installer | php
  mv composer.phar /usr/local/bin/composer
fi

# Node.js
if ! cmd_exists node; then
  log "Installing Node.js ${NODE_MAJOR}.x"
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -
  DEBIAN_FRONTEND=noninteractive apt install -y nodejs
fi

ok "Base software installed"

########################################
#     READ DB CREDENTIALS FROM BACKUP  #
########################################
extract_backup_if_needed() {
  local src="$1"
  local dest="$2"
  mkdir -p "$dest"
  if [[ "$src" == *.tar.gz ]] || [[ "$src" == *.tgz ]]; then
    log "Extracting backup bundle: $src"
    tar -xzf "$src" -C "$dest"
  else
    log "Copying backup directory into temp"
    rsync -a "$src/" "$dest/"
  fi
}

read_env_from_dir() {
  local dir="$1"
  local env_file="${dir}/.env"
  if [ -f "$env_file" ]; then
    log "Reading DB settings from backup .env"
    local v
    v=$(grep -E '^DB_DATABASE=' "$env_file" | tail -1 | cut -d= -f2- | tr -d '"') && [ -n "$v" ] && DB_NAME="$v"
    v=$(grep -E '^DB_USERNAME=' "$env_file" | tail -1 | cut -d= -f2- | tr -d '"') && [ -n "$v" ] && DB_USER="$v"
    v=$(grep -E '^DB_PASSWORD=' "$env_file" | tail -1 | cut -d= -f2- | tr -d '"') && [ -n "$v" ] && DB_PASS="$v"
  else
    warn ".env not found in backup; using default DB settings"
  fi
}

if [ -n "$BACKUP_BUNDLE" ]; then
  TMP_BUNDLE_DIR="/root/studendy_restore_$(date +%s)"
  extract_backup_if_needed "$BACKUP_BUNDLE" "$TMP_BUNDLE_DIR"
  # try direct root, else if bundle has single subdir, descend into it
  if [ ! -f "$TMP_BUNDLE_DIR/.env" ]; then
    subdir=$(find "$TMP_BUNDLE_DIR" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)
    [ -n "$subdir" ] && TMP_BUNDLE_DIR="$subdir"
  fi
  read_env_from_dir "$TMP_BUNDLE_DIR"
fi

########################################
#           DATABASE SETUP             #
########################################
log "Configuring MySQL database and user"
# Create DB and user (works with auth_socket root on Ubuntu)
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
ok "Database ${DB_NAME} and user ${DB_USER} ready"

########################################
#          APPLICATION CODE            #
########################################
log "Preparing application directory at ${APP_DIR}"
mkdir -p "${APP_DIR}"

if [ -d "${APP_DIR}/.git" ]; then
  log "Repository exists. Pulling latest ${BRANCH}"
  git -C "${APP_DIR}" fetch origin "${BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"
else
  log "Cloning repository"
  git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${APP_DIR}"
fi

log "Installing PHP dependencies"
COMPOSER_ALLOW_SUPERUSER=1 composer --working-dir="${APP_DIR}" install \
  --no-dev --prefer-dist --no-ansi --no-progress --no-interaction --optimize-autoloader

if [ -f "${APP_DIR}/package.json" ]; then
  log "Installing Node dependencies and building assets"
  (cd "${APP_DIR}" && npm ci && npm run build)
else
  warn "No package.json found; skipping frontend build"
fi

# Permissions
log "Setting permissions for Laravel"
mkdir -p "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"
chown -R www-data:www-data "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"
find "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache" -type d -exec chmod 775 {} +
find "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache" -type f -exec chmod 664 {} +

# Environment
log "Configuring environment (.env)"
if [ ! -f "${APP_DIR}/.env" ]; then
  cp "${APP_DIR}/.env.example" "${APP_DIR}/.env" || touch "${APP_DIR}/.env"
fi
sed -i "s#^APP_ENV=.*#APP_ENV=production#" "${APP_DIR}/.env" || true
sed -i "s#^APP_DEBUG=.*#APP_DEBUG=false#" "${APP_DIR}/.env" || true
sed -i "s#^APP_URL=.*#APP_URL=https://${DOMAIN}#" "${APP_DIR}/.env" || true
sed -i "s#^DB_CONNECTION=.*#DB_CONNECTION=mysql#" "${APP_DIR}/.env" || true
sed -i "s#^DB_HOST=.*#DB_HOST=127.0.0.1#" "${APP_DIR}/.env" || true
sed -i "s#^DB_PORT=.*#DB_PORT=3306#" "${APP_DIR}/.env" || true
sed -i "s#^DB_DATABASE=.*#DB_DATABASE=${DB_NAME}#" "${APP_DIR}/.env" || true
sed -i "s#^DB_USERNAME=.*#DB_USERNAME=${DB_USER}#" "${APP_DIR}/.env" || true
sed -i "s#^DB_PASSWORD=.*#DB_PASSWORD=${DB_PASS}#" "${APP_DIR}/.env" || true

php "${APP_DIR}/artisan" key:generate --force || true
php "${APP_DIR}/artisan" storage:link || true

log "Running database migrations and optimizing"
php "${APP_DIR}/artisan" migrate --force
php "${APP_DIR}/artisan" config:cache
php "${APP_DIR}/artisan" route:cache
php "${APP_DIR}/artisan" view:cache || true
php "${APP_DIR}/artisan" optimize

########################################
#         NGINX CONFIGURATION          #
########################################
log "Configuring Nginx vhost for ${DOMAIN}"
cat >/etc/nginx/sites-available/studendy <<NGINX
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${APP_DIR}/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    # Static file caching
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
NGINX

ln -sf /etc/nginx/sites-available/studendy /etc/nginx/sites-enabled/studendy
rm -f /etc/nginx/sites-enabled/default || true
nginx -t
systemctl reload nginx
ok "Nginx configured"

########################################
#             SUPERVISOR               #
########################################
log "Configuring Supervisor for Laravel queue workers"
cat >/etc/supervisor/conf.d/studendy-worker.conf <<SUP
[program:studendy-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${APP_DIR}/artisan queue:work redis --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=2
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/worker.log
stopwaitsecs=3600
SUP

supervisorctl reread
supervisorctl update
supervisorctl start studendy-worker:* || true
ok "Supervisor configured"

########################################
#                SSL                   #
########################################
if cmd_exists certbot; then
  warn "Certbot already installed; attempting certificate issuance"
else
  log "Installing Certbot for Let's Encrypt"
  DEBIAN_FRONTEND=noninteractive apt install -y certbot python3-certbot-nginx
fi

if [ -n "${DOMAIN}" ] && [ -n "${ADMIN_EMAIL}" ]; then
  log "Requesting SSL certificate for ${DOMAIN}"
  certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --non-interactive || warn "Certbot failed; ensure DNS points to this server"
  systemctl reload nginx || true
else
  warn "Skipping SSL issuance (DOMAIN or ADMIN_EMAIL not set)"
fi

########################################
#             LOG ROTATION             #
########################################
log "Setting logrotate policy for Laravel logs"
cat >/etc/logrotate.d/studendy <<ROT
${APP_DIR}/storage/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    notifempty
    create 0644 www-data www-data
    postrotate
        /bin/kill -USR1 $(cat /var/run/nginx.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
ROT

########################################
#              BACKUPS                 #
########################################
log "Installing daily backup script and cron"
cat >/usr/local/bin/backup-studendy.sh <<'BKP'
#!/usr/bin/env bash
set -Eeuo pipefail
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/backups/studendy"
APP_DIR="/var/www/studendy"
DB_NAME="studendy_production"
DB_USER="studendy"
DB_PASS="secure_password"
mkdir -p "$BACKUP_DIR"

mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$BACKUP_DIR/db_$DATE.sql.gz" || true
tar -czf "$BACKUP_DIR/app_$DATE.tar.gz" -C /var/www studendy --exclude=node_modules --exclude=vendor || true
find "$BACKUP_DIR" -name "*.gz" -mtime +7 -delete || true
echo "Backup completed: $DATE"
BKP

chmod +x /usr/local/bin/backup-studendy.sh
(crontab -l 2>/dev/null | grep -v "/usr/local/bin/backup-studendy.sh"; echo "0 2 * * * /usr/local/bin/backup-studendy.sh") | crontab -

########################################
#        FIREWALL & HARDENING          #
########################################
log "Configuring UFW firewall"
ufw --force reset || true
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 'Nginx Full'
ufw --force enable

log "Configuring Fail2Ban (basic)"
cat >/etc/fail2ban/jail.local <<JAIL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[nginx-http-auth]
enabled = true

[nginx-limit-req]
enabled = true
JAIL

systemctl enable fail2ban
systemctl restart fail2ban

########################################
#           DEPLOY SHORTCUT            #
########################################
log "Creating simple deploy helper script"
cat >/usr/local/bin/deploy-studendy.sh <<DEP
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="${APP_DIR}"
PHP_VERSION="${PHP_VERSION}"
cd "\${APP_DIR}"
echo "Starting deployment..."
git fetch origin ${BRANCH}
git reset --hard origin/${BRANCH}
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-ansi --no-progress --no-interaction
if [ -f package.json ]; then npm ci && npm run build; fi
php artisan migrate --force
php artisan optimize:clear && php artisan optimize
supervisorctl restart studendy-worker:* || true
systemctl reload php${PHP_VERSION}-fpm || true
systemctl reload nginx || true
echo "Deployment completed successfully!"
DEP
chmod +x /usr/local/bin/deploy-studendy.sh

########################################
#                DONE                  #
########################################
ok "All set!"
echo "- App directory: ${APP_DIR}"
echo "- Domain: ${DOMAIN} (update DNS A/AAAA to this server)"
echo "- To deploy later: sudo deploy-studendy.sh"
echo "- To check services: systemctl status nginx php${PHP_VERSION}-fpm mysql redis-server"

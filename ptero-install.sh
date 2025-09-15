#!/bin/bash
set -euo pipefail

# -------------------------------
# Pterodactyl Panel Full Installer
# -------------------------------

# Database credentials
DB_NAME="panel"
DB_USER="pterodactyl"
DB_PASS="Lakshya@890"

# Admin credentials
ADMIN_USERNAME="admin"
ADMIN_PASSWORD="Lakshya@890"
ADMIN_EMAIL="lakshyakatv@gmail.com"
ADMIN_FULLNAME="admin admin"

# Ask for domain
read -rp "Enter your panel domain (e.g., panel.example.com): " FQDN

echo ">>> Updating system..."
apt update && apt upgrade -y

echo ">>> Installing prerequisites..."
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release unzip git redis-server

echo ">>> Adding PHP repository..."
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

echo ">>> Adding Redis repository..."
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list

echo ">>> Updating repositories..."
apt update

echo ">>> Installing dependencies..."
apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

echo ">>> Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

echo ">>> Enabling and starting Redis..."
systemctl enable --now redis-server

echo ">>> Setting up MariaDB user + database..."
systemctl enable --now mariadb

mysql -u root <<MYSQL_EOF
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_EOF

echo ">>> Creating panel directory..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

echo ">>> Downloading Pterodactyl Panel..."
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

echo ">>> Copying environment file..."
cp .env.example .env

echo ">>> Installing PHP dependencies with Composer..."
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

echo ">>> Generating application key..."
php artisan key:generate --force

# -------------------------------
# Pre-fill .env automatically
# -------------------------------
sed -i "s|APP_URL=.*|APP_URL=https://${FQDN}|" .env
sed -i "s/DB_CONNECTION=.*$/DB_CONNECTION=mysql/" .env
sed -i "s/DB_HOST=.*$/DB_HOST=127.0.0.1/" .env
sed -i "s/DB_PORT=.*$/DB_PORT=3306/" .env
sed -i "s/DB_DATABASE=.*$/DB_DATABASE=${DB_NAME}/" .env
sed -i "s/DB_USERNAME=.*$/DB_USERNAME=${DB_USER}/" .env
sed -i "s/DB_PASSWORD=.*$/DB_PASSWORD=${DB_PASS}/" .env

echo ">>> Running database migrations..."
php artisan migrate --seed --force

echo ">>> Creating first admin user..."
php artisan p:user:make \
    --email="${ADMIN_EMAIL}" \
    --username="${ADMIN_USERNAME}" \
    --password="${ADMIN_PASSWORD}" \
    --admin \
    --force

echo ">>> Setting correct permissions for Pterodactyl files..."
chown -R www-data:www-data /var/www/pterodactyl/*

echo ">>> Adding cron job for Pterodactyl scheduler..."
(crontab -l 2>/dev/null | grep -Fv "php /var/www/pterodactyl/artisan schedule:run"; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

echo ">>> Creating systemd service for Pterodactyl queue worker..."
cat > /etc/systemd/system/pteroq.service <<'EOF'
# Pterodactyl Queue Worker File
# ----------------------------------

[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo ">>> Enabling and starting Pterodactyl queue worker..."
systemctl daemon-reload
systemctl enable --now pteroq.service

echo ">>> Running external firewall script..."
bash <(curl -s https://raw.githubusercontent.com/LakshyaTheMinecrafter/skript.sh/main/firewalld.sh)

echo "==================================================="
echo "Please do the webserver configuration by yourself:"
echo "https://pterodactyl.io/panel/1.0/webserver_configuration.html"
echo "==================================================="

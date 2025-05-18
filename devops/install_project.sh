#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration Variables ---
# Project user and group
PROJECT_USER="vdsadmin"
# Web server group - User specified this, normally www-data for nginx/apache
# If PHP-FPM runs as vdsadmin, this is fine. Otherwise, www-data might be more appropriate for storage/bootstrap/cache group ownership.
WEB_SERVER_GROUP="vdsadmin"

# Project paths and domain
PROJECT_DOMAIN="cv.dfcdn.net"
PROJECT_BASE_PATH="/home/${PROJECT_USER}/www"
PROJECT_PATH="${PROJECT_BASE_PATH}/${PROJECT_DOMAIN}"
PUBLIC_PATH="${PROJECT_PATH}/public"

# Database configuration
DB_PREFIX="cv" # From subdomain
DB_NAME="db_${DB_PREFIX}"
DB_USER="dbuser_${DB_PREFIX}"
DB_ROOT_PASSWORD_CMD="cat ~/.all_settings | grep MySQL | awk {'print \$3'}" # Command to get MySQL root password
DB_USER_PASSWORD=$(openssl rand -hex 16)                                    # Generate a random password for the new DB user

# Software versions
PHP_VERSION="8.1"
NODE_VERSION_MAJOR="22" # We'll check for 22.x

# Email for Let's Encrypt (Certbot) - Replace with your actual email
LETSENCRYPT_EMAIL="your-email@example.com"

# Log file for this script
INIT_LOG_FILE="${HOME}/laravel_init_${PROJECT_DOMAIN}.log"
exec > >(tee -a "${INIT_LOG_FILE}") 2>&1

echo "--- Starting Laravel Project Initialization for ${PROJECT_DOMAIN} ---"
echo "--- Timestamp: $(date) ---"
echo "--- Log file: ${INIT_LOG_FILE} ---"

# --- Helper Functions ---
ensure_command_exists() {
    # Ensures a command exists, otherwise tries to install the package.
    # Usage: ensure_command_exists "command_name" "package_name_to_install"
    local cmd="$1"
    local pkg="$2"
    if ! command -v "$cmd" &>/dev/null; then
        echo "${cmd} could not be found. Attempting to install ${pkg}..."
        sudo apt-get update -y
        sudo apt-get install -y "$pkg"
        if ! command -v "$cmd" &>/dev/null; then
            echo "Failed to install ${pkg}. Please install it manually and re-run the script."
            exit 1
        fi
        echo "${pkg} installed successfully."
    else
        echo "${cmd} is already installed."
    fi
}

# --- 1. Prerequisite Software Installation ---
echo ""
echo "--- Step 1: Checking and Installing Prerequisites ---"

# Update package list
sudo apt-get update -y

# Essential tools
ensure_command_exists "git" "git"
ensure_command_exists "curl" "curl"
ensure_command_exists "wget" "wget"
ensure_command_exists "unzip" "unzip"
ensure_command_exists "nginx" "nginx"
ensure_command_exists "mysql" "mysql-server" # Checks for mysql client, implies server
ensure_command_exists "supervisor" "supervisor"

# Check Nginx status
if ! sudo systemctl is-active --quiet nginx; then
    echo "Nginx is not running. Attempting to start Nginx..."
    sudo systemctl start nginx
    sudo systemctl enable nginx
    if ! sudo systemctl is-active --quiet nginx; then
        echo "Failed to start Nginx. Please check Nginx configuration."
        exit 1
    fi
fi
echo "Nginx is running."

# Check MySQL status
if ! sudo systemctl is-active --quiet mysql; then
    echo "MySQL is not running. Attempting to start MySQL..."
    sudo systemctl start mysql
    sudo systemctl enable mysql
    if ! sudo systemctl is-active --quiet mysql; then
        echo "Failed to start MySQL. Please check MySQL configuration."
        exit 1
    fi
fi
echo "MySQL is running."

# PHP 8.1 and extensions
echo "Checking PHP version..."
CURRENT_PHP_VERSION=$(php -v 2>/dev/null | head -n 1 | cut -d " " -f 2 | cut -d "." -f 1,2)
if [ "$CURRENT_PHP_VERSION" != "$PHP_VERSION" ]; then
    echo "PHP ${PHP_VERSION} not found or incorrect version ($CURRENT_PHP_VERSION). Installing PHP ${PHP_VERSION}..."
    sudo apt-get install -y software-properties-common
    # Adding Ondřej Surý PPA for PHP
    if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        sudo add-apt-repository ppa:ondrej/php -y
    fi
    sudo apt-get update -y
    sudo apt-get install -y \
        php${PHP_VERSION} \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-dom \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-tokenizer \
        php${PHP_VERSION}-fileinfo \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-ctype \
        php${PHP_VERSION}-openssl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-redis # If using Redis
    # Optionally, set PHP 8.1 as default CLI (be careful if other apps depend on different versions)
    # sudo update-alternatives --set php /usr/bin/php8.1
    echo "PHP ${PHP_VERSION} and extensions installed."
else
    echo "PHP ${PHP_VERSION} is already installed."
fi
# Ensure php-cli used is the correct version for subsequent artisan commands
PHP_CLI_PATH=$(which php${PHP_VERSION})
if [ -z "$PHP_CLI_PATH" ]; then
    PHP_CLI_PATH=$(which php) # Fallback to default php
fi

# Composer
if ! command -v composer &>/dev/null; then
    echo "Composer not found. Installing Composer..."
    curl -sS https://getcomposer.org/installer -o composer-setup.php
    sudo $PHP_CLI_PATH composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm composer-setup.php
    echo "Composer installed successfully."
else
    echo "Composer is already installed."
    composer self-update --stable || echo "Composer self-update failed, continuing."
fi

# Node.js and npm
echo "Checking Node.js version..."
CURRENT_NODE_VERSION_MAJOR=""
if command -v node &>/dev/null; then
    CURRENT_NODE_VERSION_MAJOR=$(node -v | cut -d "v" -f 2 | cut -d "." -f 1)
fi

if [ "$CURRENT_NODE_VERSION_MAJOR" != "$NODE_VERSION_MAJOR" ]; then
    echo "Node.js v${NODE_VERSION_MAJOR}.x not found or incorrect version ($CURRENT_NODE_VERSION_MAJOR). Installing Node.js v${NODE_VERSION_MAJOR}.x..."
    # Using NodeSource setup script
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION_MAJOR}.x | sudo -E bash -
    sudo apt-get install -y nodejs
    echo "Node.js v${NODE_VERSION_MAJOR}.x and npm installed successfully."
else
    echo "Node.js v${NODE_VERSION_MAJOR}.x is already installed."
fi
ensure_command_exists "npm" "npm" # Should come with nodejs

# Certbot
ensure_command_exists "certbot" "certbot python3-certbot-nginx" # Using apt package for nginx plugin

# --- 2. Database Setup ---
echo ""
echo "--- Step 2: Setting up MySQL Database and User ---"
DB_ROOT_PASSWORD=$(eval "$DB_ROOT_PASSWORD_CMD")

if [ -z "$DB_ROOT_PASSWORD" ]; then
    echo "Could not retrieve MySQL root password. Please check the command in the script."
    read -s -p "Please enter MySQL root password manually: " DB_ROOT_PASSWORD_MANUAL
    DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD_MANUAL
    echo ""
    if [ -z "$DB_ROOT_PASSWORD" ]; then
        echo "MySQL root password not provided. Exiting."
        exit 1
    fi
fi

# Create database if it doesn't exist
echo "Creating database ${DB_NAME}..."
sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# Create user if it doesn't exist and grant privileges
echo "Creating user ${DB_USER} and granting privileges to ${DB_NAME}..."
sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_USER_PASSWORD}';"
sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"

echo "Database user ${DB_USER} created with password: ${DB_USER_PASSWORD}"
echo "IMPORTANT: Store this password securely. It will be added to the .env file."

# --- 3. Laravel Project Setup ---
echo ""
echo "--- Step 3: Setting up Laravel Project ---"

# Check if project directory exists and has content beyond 'public/test.txt'
if [ -d "${PROJECT_PATH}" ]; then
    # Count files/dirs inside PROJECT_PATH excluding 'public' dir itself, then count inside 'public' excluding 'test.txt'
    CONTENT_COUNT=$(find "${PROJECT_PATH}" -mindepth 1 -not -path "${PROJECT_PATH}/public" -print -quit | wc -l)
    PUBLIC_CONTENT_COUNT=$(find "${PROJECT_PATH}/public" -mindepth 1 -not -name "test.txt" -print -quit | wc -l)

    if [ "$CONTENT_COUNT" -gt 0 ] || [ "$PUBLIC_CONTENT_COUNT" -gt 0 ]; then
        echo "Project directory ${PROJECT_PATH} already exists and is not empty."
        echo "Please back up or remove it, then re-run the script if you want a fresh install."
        # For now, we will try to continue assuming it might be a partial setup
        # exit 1
    else
        echo "Project directory ${PROJECT_PATH} exists but seems empty or only contains placeholder. Proceeding."
    fi
else
    echo "Creating project base directory ${PROJECT_BASE_PATH} if it doesn't exist..."
    mkdir -p "${PROJECT_BASE_PATH}"
fi

if [ ! -f "${PROJECT_PATH}/artisan" ]; then
    echo "Laravel project not found at ${PROJECT_PATH}. Creating new project..."
    # Navigate to www directory to create project
    cd "${PROJECT_BASE_PATH}"
    # If cv.dfcdn.net exists and is empty, composer might complain. Remove it if it's just a placeholder.
    if [ -d "${PROJECT_DOMAIN}" ] && [ $(ls -A "${PROJECT_DOMAIN}" | wc -l) -eq 0 ]; then
        rm -rf "${PROJECT_DOMAIN}"
    elif [ -d "${PROJECT_DOMAIN}" ] && [ $(find "${PROJECT_DOMAIN}" -type f -name "test.txt" -path "*/public/test.txt" | wc -l) -eq 1 ] && [ $(find "${PROJECT_DOMAIN}" -mindepth 1 -not \( -path "${PROJECT_DOMAIN}/public" -o -path "${PROJECT_DOMAIN}/public/test.txt" \) | wc -l) -eq 0 ]; then
        echo "Found existing directory with only test.txt, removing before creating project."
        rm -rf "${PROJECT_DOMAIN}"
    fi
    composer create-project --prefer-dist laravel/laravel "${PROJECT_DOMAIN}"
    echo "Laravel project created."
else
    echo "Laravel project already exists at ${PROJECT_PATH}."
fi

cd "${PROJECT_PATH}"

# --- 4. Project Configuration (.env file) ---
echo ""
echo "--- Step 4: Configuring .env file ---"
if [ ! -f ".env" ]; then
    cp .env.example .env
    echo ".env file created."
fi

# Generate APP_KEY if not set or if .env was just created
if grep -q "APP_KEY=$" .env || ! grep -q "APP_KEY=" .env || [ "$(stat -c %Y .env.example)" -gt "$(stat -c %Y .env 2>/dev/null || echo 0)" ]; then
    echo "Generating APP_KEY..."
    $PHP_CLI_PATH artisan key:generate
fi

# Update .env settings
# Using sed; be careful with special characters in passwords if not using openssl rand -hex
update_env_var() {
    local key=$1
    local value=$2
    # Escape slashes and ampersands for sed
    local escaped_value=$(echo "$value" | sed -e 's/[\/&]/\\&/g')
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${escaped_value}|" .env
    else
        echo "${key}=${escaped_value}" >>.env
    fi
}

update_env_var "APP_NAME" "CV Platform DFCDN"
update_env_var "APP_ENV" "production" # Change to "local" or "development" for dev environments
update_env_var "APP_DEBUG" "false"    # Change to "true" for dev
update_env_var "APP_URL" "https://${PROJECT_DOMAIN}"

update_env_var "DB_CONNECTION" "mysql"
update_env_var "DB_HOST" "127.0.0.1"
update_env_var "DB_PORT" "3306"
update_env_var "DB_DATABASE" "${DB_NAME}"
update_env_var "DB_USERNAME" "${DB_USER}"
update_env_var "DB_PASSWORD" "${DB_USER_PASSWORD}"

update_env_var "QUEUE_CONNECTION" "redis"
update_env_var "SESSION_DRIVER" "redis"
update_env_var "CACHE_DRIVER" "redis"
# Add Redis connection details if not default (127.0.0.1:6379)
# update_env_var "REDIS_HOST" "127.0.0.1"
# update_env_var "REDIS_PASSWORD" "null"
# update_env_var "REDIS_PORT" "6379"

# Mail settings (placeholders - user needs to configure these)
update_env_var "MAIL_MAILER" "smtp"
update_env_var "MAIL_HOST" "mailpit" # Or your actual mail server
update_env_var "MAIL_PORT" "1025"
update_env_var "MAIL_USERNAME" "null"
update_env_var "MAIL_PASSWORD" "null"
update_env_var "MAIL_ENCRYPTION" "null"
update_env_var "MAIL_FROM_ADDRESS" "noreply@${PROJECT_DOMAIN}"
update_env_var "MAIL_FROM_NAME" "\${APP_NAME}"

# Custom .env variables from our plan
update_env_var "GEMINI_API_KEY" "your_gemini_api_key_here_replace_me" # Placeholder
update_env_var "ADMIN_PREFIX" "admin"

echo ".env file configured."

# --- 5. Install Dependencies & Build Assets ---
echo ""
echo "--- Step 5: Installing PHP & Frontend Dependencies ---"
composer install --optimize-autoloader --no-dev --prefer-dist
npm install
npm run build

# --- 6. Directory Permissions ---
echo ""
echo "--- Step 6: Setting Directory Permissions ---"
# Change ownership of the project directory to the project user and web server group
# This assumes PHP-FPM for this site will run as $PROJECT_USER or its group is $WEB_SERVER_GROUP
sudo chown -R "${PROJECT_USER}:${WEB_SERVER_GROUP}" "${PROJECT_PATH}"

# Set writable permissions for storage and bootstrap/cache directories
sudo chmod -R ug+w,o-w "${PROJECT_PATH}/storage"
sudo chmod -R ug+w,o-w "${PROJECT_PATH}/bootstrap/cache"
echo "Directory permissions set."

# --- 7. Laravel Application Setup ---
echo ""
echo "--- Step 7: Running Laravel Setup Commands ---"
$PHP_CLI_PATH artisan storage:link
$PHP_CLI_PATH artisan migrate --force
$PHP_CLI_PATH artisan db:seed --force # This will run all seeders defined in DatabaseSeeder

# Cache configurations for production
$PHP_CLI_PATH artisan config:cache
$PHP_CLI_PATH artisan route:cache
$PHP_CLI_PATH artisan view:cache
$PHP_CLI_PATH artisan event:cache # Laravel 9+

echo "Laravel application setup complete."

# --- 8. Nginx Configuration ---
echo ""
echo "--- Step 8: Ensuring Nginx Configuration ---"
# The user provided an Nginx config. This script will create a more standard one if not found,
# or ensure the PHP part is present.
NGINX_CONF_PATH="/etc/nginx/sites-available/${PROJECT_DOMAIN}.conf"

# Create a more complete Nginx config if it doesn't exist, or ensure PHP processing
# This incorporates user's SSL settings (managed by Certbot)
# IMPORTANT: This will overwrite if NGINX_CONF_PATH exists and isn't what we expect.
# A safer approach would be to check for key elements.
# For now, we'll create/overwrite with a standard Laravel config + Certbot lines.

# Back up existing config if it exists
if [ -f "$NGINX_CONF_PATH" ]; then
    sudo cp "$NGINX_CONF_PATH" "${NGINX_CONF_PATH}.bak_$(date +%F_%T)"
    echo "Backed up existing Nginx config to ${NGINX_CONF_PATH}.bak_$(date +%F_%T)"
fi

sudo tee "$NGINX_CONF_PATH" >/dev/null <<EOL
server {
    listen 80;
    listen [::]:80;
    server_name ${PROJECT_DOMAIN} www.${PROJECT_DOMAIN};
    root ${PUBLIC_PATH};

    # Redirect all HTTP traffic to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${PROJECT_DOMAIN} www.${PROJECT_DOMAIN};
    root ${PUBLIC_PATH};

    index index.php index.html index.htm;

    # SSL settings managed by Certbot (copied from user's provided config)
    ssl_certificate /etc/letsencrypt/live/${PROJECT_DOMAIN}/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/${PROJECT_DOMAIN}/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

    access_log /home/${PROJECT_USER}/logs/${PROJECT_DOMAIN}.access.log; # Using user's log path
    error_log /home/${PROJECT_USER}/logs/errors/${PROJECT_DOMAIN}.error.log; # Using user's log path

    # User's include for proxy.conf - assuming it's necessary and correctly configured
    # include /etc/nginx/proxy.conf; 
    # If proxy.conf is for passing to PHP-FPM, the location ~ \.php$ block below might conflict or be redundant.
    # For a standard Laravel setup, the block below is typical.

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        # Make sure this socket path matches your PHP-FPM configuration for PHP 8.1
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    # Security headers (optional but recommended)
    # add_header X-Frame-Options "SAMEORIGIN";
    # add_header X-XSS-Protection "1; mode=block";
    # add_header X-Content-Type-Options "nosniff";
}
EOL

# Ensure log directories exist (Nginx might not create them)
sudo mkdir -p "/home/${PROJECT_USER}/logs/errors"
sudo chown -R "${PROJECT_USER}:${WEB_SERVER_GROUP}" "/home/${PROJECT_USER}/logs" # Or www-data if nginx runs as www-data

# Enable site if not already enabled
if [ ! -L "/etc/nginx/sites-enabled/${PROJECT_DOMAIN}.conf" ]; then
    sudo ln -s "${NGINX_CONF_PATH}" "/etc/nginx/sites-enabled/"
fi

# Test Nginx configuration and reload
sudo nginx -t && sudo systemctl reload nginx
echo "Nginx configuration updated and reloaded."

# --- 9. Certbot (SSL Certificate) ---
echo ""
echo "--- Step 9: Checking SSL Certificate (Certbot) ---"
# Check if certificate files exist, if not, try to obtain them
CERT_DIR="/etc/letsencrypt/live/${PROJECT_DOMAIN}"
if [ ! -d "$CERT_DIR" ] || [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
    echo "SSL certificate not found for ${PROJECT_DOMAIN}. Attempting to obtain one using Certbot..."
    echo "Make sure your DNS records for ${PROJECT_DOMAIN} (and www.${PROJECT_DOMAIN} if used) point to this server's IP."
    # Pause for user to confirm DNS if script is interactive, otherwise proceed
    # read -p "Press [Enter] to continue after DNS is set up, or Ctrl+C to abort..."

    # Add www subdomain if it's in the server_name
    DOMAINS_CERTBOT="-d ${PROJECT_DOMAIN}"
    if grep -q "www.${PROJECT_DOMAIN}" "$NGINX_CONF_PATH"; then
        DOMAINS_CERTBOT="${DOMAINS_CERTBOT} -d www.${PROJECT_DOMAIN}"
    fi

    sudo certbot --nginx ${DOMAINS_CERTBOT} --non-interactive --agree-tos -m "${LETSENCRYPT_EMAIL}" --redirect
    echo "Certbot command executed. Check its output for success."
else
    echo "SSL certificate already exists for ${PROJECT_DOMAIN}."
    echo "Ensuring Certbot auto-renewal is set up..."
    sudo certbot renew --dry-run # Test renewal
fi

# --- 10. Supervisor for Horizon ---
echo ""
echo "--- Step 10: Setting up Supervisor for Horizon ---"
HORIZON_SUPERVISOR_CONF="/etc/supervisor/conf.d/horizon-${DB_PREFIX}.conf" # Use DB_PREFIX for uniqueness

sudo tee "$HORIZON_SUPERVISOR_CONF" >/dev/null <<EOL
[program:horizon-${DB_PREFIX}]
process_name=%(program_name)s_%(process_num)02d
command=${PHP_CLI_PATH} ${PROJECT_PATH}/artisan horizon
autostart=true
autorestart=true
user=${PROJECT_USER}
numprocs=1
redirect_stderr=true
stdout_logfile=${PROJECT_PATH}/storage/logs/horizon.log
stderr_logfile=${PROJECT_PATH}/storage/logs/horizon_error.log
stopwaitsecs=3600
stopsignal=QUIT
EOL

sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start "horizon-${DB_PREFIX}:*" || echo "Failed to start horizon-${DB_PREFIX} or already running."
echo "Supervisor configuration for Horizon created and started."

# --- 11. Cron Job for Laravel Scheduler ---
echo ""
echo "--- Step 11: Setting up Cron Job for Laravel Scheduler ---"
# Check if cron job already exists for this project
CRON_JOB_CMD="cd ${PROJECT_PATH} && ${PHP_CLI_PATH} artisan schedule:run >> /dev/null 2>&1"
if ! crontab -l -u "${PROJECT_USER}" | grep -qF -- "$CRON_JOB_CMD"; then
    (
        crontab -l -u "${PROJECT_USER}" 2>/dev/null
        echo "* * * * * ${CRON_JOB_CMD}"
    ) | crontab -u "${PROJECT_USER}" -
    echo "Cron job for Laravel Scheduler added for user ${PROJECT_USER}."
else
    echo "Cron job for Laravel Scheduler already exists for user ${PROJECT_USER}."
fi

# --- Final Steps ---
echo ""
echo "--- Laravel Project Initialization Complete for ${PROJECT_DOMAIN} ---"
echo ""
echo "IMPORTANT NEXT STEPS:"
echo "1. Review the .env file at ${PROJECT_PATH}/.env and ensure all settings are correct, especially:"
echo "   - MAIL_MAILER and related mail settings."
echo "   - GEMINI_API_KEY (currently a placeholder)."
echo "   - Any other third-party service API keys."
echo "2. The database user '${DB_USER}' was created with the password: ${DB_USER_PASSWORD}"
echo "   This password has been added to your .env file."
echo "3. Visit your site: https://${PROJECT_DOMAIN}"
echo "4. Check Horizon dashboard (if enabled in routes): https://${PROJECT_DOMAIN}/${CONFIG_ADMIN_PREFIX:-admin}/horizon"
echo "5. Check logs for any errors:"
echo "   - This script's log: ${INIT_LOG_FILE}"
echo "   - Laravel log: ${PROJECT_PATH}/storage/logs/laravel.log"
echo "   - Nginx error log: /home/${PROJECT_USER}/logs/errors/${PROJECT_DOMAIN}.error.log"
echo "   - Horizon log: ${PROJECT_PATH}/storage/logs/horizon.log"
echo "--- Script Finished: $(date) ---"

exit 0

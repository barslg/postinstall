#!/bin/bash
# postinstall.sh — Ubuntu 22.04.5 LTS server setup automation
# This script is designed to automate the post-installation setup of an Ubuntu server.
# It includes tasks such as updating the system, installing essential packages, configuring services,

# set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Set variables
LOG_FILE="/var/log/postinstall.log"
ALL_SETTINGS_FILE="/home/vdsadmin/.all_settings"
CLOUDFLARE_FILE_PATH="/etc/nginx/conf.d/cloudflare.conf"
LOG_FILE_PKG="/var/log/postinstall_pkg.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] — $1"
  echo '-------------------------------------------------------------' >> "$LOG_FILE"
}


DEFAULT_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
PMA_PATH="/var/www/html/myadmin"
NGINX_CONFIG='/etc/nginx/nginx.conf'

# Detect system resources
TOTAL_MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
CPU_CORES=$(nproc)
DISK_SIZE_GB=$(df --output=size -BG / | tail -1 | tr -dc '0-9')

# Calculate MySQL memory settings
INNODB_BUFFER_POOL_SIZE_MB=$(( TOTAL_MEM_MB * 75 / 100 ))
TMP_TABLE_SIZE_MB=512
if [ "$DISK_SIZE_GB" -lt 20 ]; then
  TMP_TABLE_SIZE_MB=128
fi

# Calculate PHP-FPM settings
PHP_PM_MAX_CHILDREN=$(( TOTAL_MEM_MB / 64 ))

# Detect default interface IP address
[ -z "$DEFAULT_IP" ] && DEFAULT_IP="127.0.0.1"



exec > >(tee -a "$LOG_FILE") 2>&1



pkg_install() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Installing $pkg..."
    apt install -y "$pkg" >> "$LOG_FILE_PKG" 2>&1 || apt install -y "$pkg" --fix-missing >> "$LOG_FILE_PKG" 2>&1
  else
    log "$pkg is already installed."
  fi
}

log "Postinstall started on $(hostname -f)"
log "Script executed by user: $(whoami)"
log "OS: $(lsb_release -d | cut -f2)"

### 1. Update and upgrade system ###
log "Updating system packages..."
apt update --fix-missing
apt upgrade -y || apt upgrade -y --fix-missing
apt dist-upgrade -y || true
apt autoremove -y || true

### 2. Install essential packages ###
ESSENTIAL_PACKAGES=(mc joe rpl net-tools curl jc whois wget rsync certbot git gnupg2 software-properties-common ufw fail2ban python3-certbot-nginx apache2-utils)
for pkg in "${ESSENTIAL_PACKAGES[@]}"; do
  pkg_install "$pkg"
done

### 3. Install PHP base and detect version ###
log "Installing base PHP..."
pkg_install "php-cli"

PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
log "Detected PHP version: $PHP_VERSION"

### 4. Install PHP modules, Nginx, MySQL, Memcached ###
log "Installing PHP modules and services..."
PHP_PACKAGES=(fpm common mysql zip mbstring curl xml opcache ssh2 memcache memcached)
for pkg in "${PHP_PACKAGES[@]}"; do
  pkg_install "php-${pkg}"
done
OTHER_PACKAGES=(nginx-full mysql-server mysql-client memcached)
for pkg in "${OTHER_PACKAGES[@]}"; do
  pkg_install "$pkg"
done


### 5. Create user vdsadmin if not exists ###
log "Creating user vdsadmin..."

# Create user if not exists
id -u vdsadmin &>/dev/null || useradd -m -s /bin/bash vdsadmin
if id -u www-data &>/dev/null; then
  usermod -a -G vdsadmin www-data
  log "www-data user added to vdsadmin group."
else
  log "www-data user does not exist, skipping group addition."
fi


# Create .ssh directory
mkdir -p /home/vdsadmin/.ssh
chmod 700 /home/vdsadmin/.ssh

# Handle authorized_keys
if [[ -f /home/ubuntu/.ssh/authorized_keys ]]; then
    cp /home/ubuntu/.ssh/authorized_keys /home/vdsadmin/.ssh/authorized_keys
else
    ssh-keygen -t rsa -b 4096 -N "" -f /home/vdsadmin/.ssh/id_rsa
    cat /home/vdsadmin/.ssh/id_rsa.pub > /home/vdsadmin/.ssh/authorized_keys
fi

chmod 600 /home/vdsadmin/.ssh/authorized_keys

# Add to sudoers
usermod -aG sudo vdsadmin
echo "vdsadmin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vdsadmin


### 6. Create directories ###
mkdir -p /home/vdsadmin/www /home/vdsadmin/logs/errors /home/vdsadmin/certs /home/vdsadmin/github_keys
chmod 755 /home/vdsadmin/www /home/vdsadmin/logs /home/vdsadmin/github_keys

### 7. Add sudo alias ###
echo "alias s='sudo su'" >> /home/vdsadmin/.bashrc

### 8. Install ionCube Loader ###
log "Installing ionCube Loader..."
wget -qO /tmp/ioncube.tar.gz https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
mkdir -p /opt/ioncube && tar -xzf /tmp/ioncube.tar.gz -C /opt/ioncube --strip-components=1
rm -f /tmp/ioncube.tar.gz
PHP_EXT_DIR=$(php -i | grep extension_dir | awk '{print $NF}')
LOADER_FILE="/opt/ioncube/ioncube_loader_lin_${PHP_VERSION}.so"
if [[ ! -f "$LOADER_FILE" ]]; then
  log "ionCube loader for PHP $PHP_VERSION not found at $LOADER_FILE. Skipping ionCube installation."
else
  cp "$LOADER_FILE" "$PHP_EXT_DIR"
  echo "zend_extension=$PHP_EXT_DIR/$(basename "$LOADER_FILE")" > "/etc/php/$PHP_VERSION/mods-available/ioncube.ini"
  ln -s "/etc/php/$PHP_VERSION/mods-available/ioncube.ini" "/etc/php/$PHP_VERSION/fpm/conf.d/00-ioncube.ini"
  ln -s "/etc/php/$PHP_VERSION/mods-available/ioncube.ini" "/etc/php/$PHP_VERSION/cli/conf.d/00-ioncube.ini"
fi

echo "opcache.enable=1
opcache.memory_consumption=256
" >> "/etc/php/$PHP_VERSION/mods-available/opcache.ini"

grep -q '^pm.max_children' /etc/php/$PHP_VERSION/fpm/pool.d/www.conf && \
  sed -i "s/^pm.max_children.*/pm.max_children = $PHP_PM_MAX_CHILDREN/" /etc/php/$PHP_VERSION/fpm/pool.d/www.conf || \
  echo "pm.max_children = $PHP_PM_MAX_CHILDREN" >> /etc/php/$PHP_VERSION/fpm/pool.d/www.conf



systemctl enable php$PHP_VERSION-fpm && systemctl restart php$PHP_VERSION-fpm






### 9. Nginx configuration ###
log "Configuring nginx..."

echo 'location ~ \.php$ {
  include snippets/fastcgi-php.conf;
  fastcgi_pass unix:/run/php/php'$PHP_VERSION'-fpm.sock;
  fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
}
location ~ /.well-known/acme-challenge/ {
  root /home/vdsadmin/certs;
  allow all;
}
location /myadmin {
  auth_basic "Restricted";
  auth_basic_user_file /home/vdsadmin/.htpasswd;
  root /var/www/html/myadmin;
  index index.php index.html;

location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php'$PHP_VERSION'-fpm.sock;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
  }
}
error_page 404 /404.html;
' > /etc/nginx/proxy.conf

echo 'include /etc/nginx/proxy.conf;
location / {
  try_files $uri $uri/ /index.php?$query_string;
}
' > /etc/nginx/proxy_laravel.conf


{
  echo -e "##### Cloudflare - IPv4\n"
  curl -s -L https://www.cloudflare.com/ips-v4 | awk '{print "set_real_ip_from " $0 ";"}'
  echo -e "\n##### Cloudflare - IPv6\n"
  curl -s -L https://www.cloudflare.com/ips-v6 | awk '{print "set_real_ip_from " $0 ";"}'
  echo -e "\nreal_ip_header CF-Connecting-IP;"
} > "$CLOUDFLARE_FILE_PATH"

# nginx config tuning
sed -i 's|include /etc/nginx/sites-enabled/\*;|include /etc/nginx/sites-enabled/*.conf;|' $NGINX_CONFIG
sed -i 's/#\s*multi_accept on;/multi_accept on;/' $NGINX_CONFIG
sed -i 's/#\s*server_tokens off;/server_tokens off;/' $NGINX_CONFIG
sed -i 's|#\s*server_names_hash_bucket_size.*|server_names_hash_bucket_size 64;|' $NGINX_CONFIG
sed -i 's|#\s*server_name_in_redirect.*|server_name_in_redirect off;|' $NGINX_CONFIG
sed -i 's|#\s*gzip_vary.*|gzip_vary on;|' $NGINX_CONFIG
sed -i 's|#\s*gzip_proxied.*|gzip_proxied any;|' $NGINX_CONFIG
sed -i 's|#\s*gzip_comp_level.*|gzip_comp_level 6;|' $NGINX_CONFIG
sed -i 's|#\s*gzip_buffers.*|gzip_buffers 16 8k;|' $NGINX_CONFIG
sed -i 's|#\s*gzip_http_version.*|gzip_http_version 1.1;|' $NGINX_CONFIG
sed -i 's|#\s*gzip_types.*|gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;|' $NGINX_CONFIG
sed -i '/^#mail {/,/^#}/d' $NGINX_CONFIG

# Generate .htpasswd user
HTPASSWD_USER="admin"
HTPASSWD_PASS=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c12)
echo "Nginx htaccess: $HTPASSWD_USER $HTPASSWD_PASS" >> $ALL_SETTINGS_FILE
htpasswd -bc /home/vdsadmin/.htpasswd "$HTPASSWD_USER" "$HTPASSWD_PASS"
chmod 640 /home/vdsadmin/.htpasswd


systemctl enable nginx && systemctl restart nginx

### 10. MySQL secure root ###
log "Securing MySQL root user..."
systemctl restart mysql
PASS=$(< /dev/urandom tr -dc A-Za-z0-9! | head -c12)
echo "MySQL pass: $PASS" >> $ALL_SETTINGS_FILE
chmod 600 $ALL_SETTINGS_FILE
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$PASS'; FLUSH PRIVILEGES;"

chown -R vdsadmin:vdsadmin /home/vdsadmin


# MySQL config tuning
log "Configuring MySQL..."

echo "[mysqld]
innodb_buffer_pool_size=${INNODB_BUFFER_POOL_SIZE_MB}M
innodb_log_file_size=512M
innodb_flush_log_at_trx_commit=2
innodb_flush_method=O_DIRECT
tmp_table_size=${TMP_TABLE_SIZE_MB}M
max_heap_table_size=${TMP_TABLE_SIZE_MB}M
open_files_limit=65535
table_open_cache=4096
performance_schema=OFF
" > /etc/mysql/conf.d/optimized.cnf

### 11. phpMyAdmin install ###
log "Installing phpMyAdmin..."
wget -qO /tmp/phpmyadmin.tar.gz https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz
tar -xzf /tmp/phpmyadmin.tar.gz -C /var/www/html/
rm -f /tmp/phpmyadmin.tar.gz
mv /var/www/html/phpMyAdmin* /var/www/html/myadmin

if [ ! -f "$PMA_PATH/config.inc.php" ]; then
    cp "$PMA_PATH/config.sample.inc.php" "$PMA_PATH/config.inc.php"
fi

BLOWFISH_SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
sed -i "/blowfish_secret/s/''/'$BLOWFISH_SECRET'/" "$PMA_PATH/config.inc.php"


chown -R www-data:www-data /var/www/html/myadmin

### 12. SSH, Firewall ###
log "Configuring SSH, UFW and MySQL bind..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw allow 'Nginx HTTP'
ufw allow 'Nginx HTTPS'
ufw --force enable
sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql

### 13. Rsync and Memcached ###
# add rsync config
log "Configuring rsync..."
echo 'syslog facility = local5
munge symlinks = no
use chroot = no
[home]
  path = /home/
  write only = false
  read only = false
  uid = root
  hosts allow = '$DEFAULT_IP'
' > /etc/rsyncd.conf

sed -i 's/^RSYNC_ENABLE=false/RSYNC_ENABLE=true/' /etc/default/rsync
ufw allow 873
systemctl enable rsync
systemctl restart rsync

systemctl enable memcached
systemctl restart memcached

### 14. Fail2ban ###
log "Installing and configuring fail2ban..."
echo '[Definition]
failregex = ^<HOST> -.*"(GET|POST).*(404)"
ignoreregex =' > /etc/fail2ban/filter.d/nginx-404.conf

echo '[sshd]
enabled = true
maxretry = 5
bantime = 600
findtime = 600

[nginx-404]
enabled = true
port = http,https
filter = nginx-404
logpath = /home/vdsadmin/logs/*.log /home/vdsadmin/logs/errors/*.log
maxretry = 10' > /etc/fail2ban/jail.d/custom.conf

systemctl enable fail2ban
systemctl restart fail2ban

### 15. Logrotate config ###
log "Setting up log rotation..."
echo '/home/vdsadmin/logs/*.log /home/vdsadmin/logs/errors/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
  create 640 vdsadmin adm
  sharedscripts
  postrotate
    systemctl reload nginx >/dev/null 2>&1 || true
  endscript
}' > /etc/logrotate.d/vdsadmin

log "Finalizing setup..."

mkdir /root/scripts/
wget https://raw.githubusercontent.com/barslg/postinstall/refs/heads/main/devops/addDomain.sh -O /root/scripts/addDomain.sh -o /dev/null
if [[ -f /root/scripts/addDomain.sh ]]; then
  chmod +x /root/scripts/addDomain.sh
  /root/scripts/addDomain.sh $(hostname -f) || log "addDomain.sh failed"
else
  log "/root/scripts/addDomain.sh not found, skipping chmod."
fi

# add certbot cron job
echo "0 0 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" >> /etc/cron.d/certbot

### 16 Linux kernel tuning
echo 'fs.file-max=2097152
net.core.somaxconn=65535
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.tcp_fin_timeout=15
' >> /etc/sysctl.conf


### 16. Finalize and reload services ###
systemctl reload nginx || log "nginx reload failed"
systemctl reload php$PHP_VERSION-fpm || log "PHP-FPM reload failed"
systemctl restart mysql || log "MySQL reload failed"
ufw reload || log "UFW reload failed"
log "Postinstall complete."
exit 0

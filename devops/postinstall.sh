#!/bin/bash
# postinstall.sh — Ubuntu 22.04.5 LTS server setup automation
# This script is designed to automate the post-installation setup of an Ubuntu server.
# It includes tasks such as updating the system, installing essential packages, configuring services,

# set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG_FILE="/var/log/postinstall.log"
ALL_SETTINGS_FILE="/home/vdsadmin/.all_settings"
CLOUDFLARE_FILE_PATH="/etc/nginx/conf.d/cloudflare.conf"
LOG_FILE_PKG="/var/log/postinstall_pkg.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') — $1"
}
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
ESSENTIAL_PACKAGES=(mc joe rpl net-tools curl jc whois wget rsync certbot git gnupg2 software-properties-common ufw)
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
chown -R vdsadmin:vdsadmin /home/vdsadmin/.ssh

# Add to sudoers
usermod -aG sudo vdsadmin
echo "vdsadmin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vdsadmin


### 6. Create directories ###
mkdir -p /home/vdsadmin/www /home/vdsadmin/logs/errors /home/vdsadmin/certs /home/vdsadmin/github_keys
chown -R vdsadmin:vdsadmin /home/vdsadmin
chmod 755 /home/vdsadmin/www /home/vdsadmin/logs /home/vdsadmin/github_keys

### 7. Add sudo alias ###
echo "alias s='sudo su'" >> /home/vdsadmin/.bashrc

### 8. Install ionCube Loader ###
log "Installing ionCube Loader..."
wget -qO /tmp/ioncube.tar.gz https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
mkdir -p /opt/ioncube && tar -xzf /tmp/ioncube.tar.gz -C /opt/ioncube --strip-components=1
PHP_EXT_DIR=$(php -i | grep extension_dir | awk '{print $NF}')
LOADER_FILE="/opt/ioncube/ioncube_loader_lin_${PHP_VERSION}.so"
if [[ ! -f "$LOADER_FILE" ]]; then
  log "ionCube loader for PHP $PHP_VERSION not found, falling back to ioncube_loader_lin_8.1.so"
  LOADER_FILE="/opt/ioncube/ioncube_loader_lin_8.1.so"
fi
cp "$LOADER_FILE" "$PHP_EXT_DIR"
echo "zend_extension=$PHP_EXT_DIR/$(basename "$LOADER_FILE")" > "/etc/php/$PHP_VERSION/fpm/conf.d/00-ioncube.ini"
echo "zend_extension=$PHP_EXT_DIR/$(basename "$LOADER_FILE")" > "/etc/php/$PHP_VERSION/cli/conf.d/00-ioncube.ini"
systemctl enable php$PHP_VERSION-fpm && systemctl restart php$PHP_VERSION-fpm

### 9. Nginx configuration ###
log "Configuring nginx..."

echo 'location ~ \.php\$ {
  include snippets/fastcgi-php.conf;
  fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
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
  include snippets/fastcgi-php.conf;
  fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
  fastcgi_param SCRIPT_FILENAME /var/www/html/myadmin\$fastcgi_script_name;
}
error_page 404 /404.html;
' > /etc/nginx/proxy.conf

echo 'include /etc/nginx/proxy.conf;
location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
}
' > /etc/nginx/proxy_laravel.conf


{
  echo -e "#Cloudflare - IPv4\n"
  curl -s -L https://www.cloudflare.com/ips-v4 | awk '{print "set_real_ip_from " $0 ";"}'
  echo -e "\n# - IPv6\n"
  curl -s -L https://www.cloudflare.com/ips-v6 | awk '{print "set_real_ip_from " $0 ";"}'
  echo ""
  echo "real_ip_header CF-Connecting-IP;"
} > "$CLOUDFLARE_FILE_PATH"


# Generate .htpasswd user
HTPASSWD_USER="admin"
HTPASSWD_PASS=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c12)
echo "Nginx htaccess: $HTPASSWD_USER $HTPASSWD_PASS" >> $ALL_SETTINGS_FILE
htpasswd -bc /home/vdsadmin/.htpasswd "$HTPASSWD_USER" "$HTPASSWD_PASS"
chmod 600 /home/vdsadmin/.htpasswd
chown vdsadmin:vdsadmin /home/vdsadmin/.htpasswd

systemctl enable nginx && systemctl restart nginx

### 10. MySQL secure root ###
log "Securing MySQL root user..."
systemctl restart mysql
PASS=$(< /dev/urandom tr -dc A-Za-z0-9! | head -c12)
echo "MySQL pass: $PASS" >> $ALL_SETTINGS_FILE
chmod 600 $ALL_SETTINGS_FILE
chown vdsadmin:vdsadmin $ALL_SETTINGS_FILE
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$PASS'; FLUSH PRIVILEGES;"

### 11. phpMyAdmin install ###
log "Installing phpMyAdmin..."
wget -qO /tmp/phpmyadmin.tar.gz https://files.phpmyadmin.net/phpMyAdmin/latest/phpMyAdmin-latest-all-languages.tar.gz
tar -xzf /tmp/phpmyadmin.tar.gz -C /var/www/html/
mv /var/www/html/phpMyAdmin* /var/www/html/myadmin
chown -R www-data:www-data /var/www/html/myadmin

### 12. SSH, Firewall ###
log "Configuring SSH, UFW and MySQL bind..."
ufw allow OpenSSH
ufw --force enable
sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql

### 13. Rsync and Memcached ###
systemctl enable memcached
systemctl restart memcached

### 14. Fail2ban ###
log "Installing and configuring fail2ban..."
apt install -y fail2ban
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
systemctl reload nginx || log "nginx reload failed"
systemctl reload php$PHP_VERSION-fpm || log "PHP-FPM reload failed"
systemctl reload mysql || log "MySQL reload failed"
log "Postinstall complete."
exit 0

#!/bin/bash
# postinstall.sh — automation of Ubuntu 22.04.5 LTS server deployment

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG_FILE="/var/log/postinstall.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') — $1"
}

log "Starting postinstall setup on $(hostname)"

### 1. System update ###
log "Updating the system..."
apt update && apt upgrade -y && apt dist-upgrade -y && apt autoremove -y

### 2. Installing basic packages ###
UTILS=(mc joe rpl net-tools curl jc whois wget rsync certbot git gnupg2 software-properties-common ufw)
for pkg in "${UTILS[@]}"; do
  if ! dpkg -s $pkg >/dev/null 2>&1; then
    log "Installing $pkg..."
    apt install -y "$pkg"
  fi
done

### 3. Installing PHP and detecting version ###
log "Installing base PHP..."
apt install -y php
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
log "Detected PHP version: $PHP_VERSION"

### 4. Installing additional PHP modules and other software ###
log "Installing PHP $PHP_VERSION, nginx, MySQL, memcached..."
PHP_PACKAGES=(php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-cli php$PHP_VERSION-common php$PHP_VERSION-mysql php$PHP_VERSION-zip php$PHP_VERSION-mbstring php$PHP_VERSION-curl php$PHP_VERSION-xml php$PHP_VERSION-opcache php-ssh2 php-memcache php-memcached)
apt install -y nginx mysql-server mysql-client memcached "${PHP_PACKAGES[@]}"

### 5. Creating user vdsadmin ###
log "Creating user vdsadmin..."
useradd -m -s /bin/bash vdsadmin || log "User already exists"
mkdir -p /home/vdsadmin/.ssh
cp /home/ubuntu/.ssh/authorized_keys /home/vdsadmin/.ssh/ || true
chmod 700 /home/vdsadmin/.ssh
chmod 600 /home/vdsadmin/.ssh/authorized_keys || true
chown -R vdsadmin:vdsadmin /home/vdsadmin/.ssh
usermod -aG sudo vdsadmin
deluser --remove-home ubuntu || true

### 6. Creating directories ###
mkdir -p /home/vdsadmin/www /home/vdsadmin/logs/errors /home/vdsadmin/certs /home/vdsadmin/github_keys
chown -R vdsadmin:vdsadmin /home/vdsadmin
chmod 755 /home/vdsadmin/www /home/vdsadmin/logs /home/vdsadmin/github_keys

### 7. Alias s=sudo su ###
echo "alias s='sudo su'" >> /home/vdsadmin/.bashrc

### 8. Installing ionCube Loader ###
log "Installing ionCube..."
wget -qO /tmp/ioncube.tar.gz https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
mkdir -p /opt/ioncube && tar -xzf /tmp/ioncube.tar.gz -C /opt/ioncube
PHP_EXT_DIR=$(php -i | grep extension_dir | awk '{print $NF}')
if [ ! -f "$PHP_EXT_DIR/ioncube_loader_lin_${PHP_VERSION}.so" ]; then
  SHORT_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  cp "/opt/ioncube/ioncube_loader_lin_${SHORT_VER}.so" "$PHP_EXT_DIR"
fi
echo "zend_extension=$PHP_EXT_DIR/ioncube_loader_lin_${PHP_VERSION}.so" > "/etc/php/$PHP_VERSION/fpm/conf.d/00-ioncube.ini"
echo "zend_extension=$PHP_EXT_DIR/ioncube_loader_lin_${PHP_VERSION}.so" > "/etc/php/$PHP_VERSION/cli/conf.d/00-ioncube.ini"
systemctl enable php$PHP_VERSION-fpm && systemctl start php$PHP_VERSION-fpm

### 9. Configuring nginx ###
log "Configuring nginx..."
mkdir -p /etc/nginx/vhosts
cat << EOF > /etc/nginx/proxy.conf
location ~ \.php\$ {
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
EOF

cat << EOF > /etc/nginx/proxy_laravel.conf
include /etc/nginx/proxy.conf;
location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
}
EOF

systemctl enable nginx && systemctl start nginx

### 10. Configuring MySQL ###
log "Configuring MySQL..."
systemctl start mysql
MEMORY=$(free -m | awk '/^Mem:/{print $2}')
PASS=$(< /dev/urandom tr -dc A-Za-z0-9! | head -c12)
echo "$PASS" >> /home/vdsadmin/.all_settings
chmod 600 /home/vdsadmin/.all_settings
chown vdsadmin:vdsadmin /home/vdsadmin/.all_settings
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$PASS'; FLUSH PRIVILEGES;"

### 11. Installing phpMyAdmin ###
log "Installing phpMyAdmin..."
wget -qO /tmp/phpmyadmin.tar.gz https://files.phpmyadmin.net/phpMyAdmin/latest/phpMyAdmin-latest-all-languages.tar.gz
tar -xzf /tmp/phpmyadmin.tar.gz -C /var/www/html/
PMA_DIR=$(find /var/www/html -maxdepth 1 -type d -name "phpMyAdmin*")
mv "$PMA_DIR" /var/www/html/myadmin
chown -R www-data:www-data /var/www/html/myadmin

### 12. SSH, SFTP, Firewall ###
log "Configuring SSH and SFTP..."
ufw allow OpenSSH
ufw --force enable
sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql

### 13. Rsync and Memcached ###
systemctl enable memcached
systemctl start memcached

### 14. Fail2ban ###
log "Installing and configuring fail2ban..."
apt install -y fail2ban
cat << EOF > /etc/fail2ban/filter.d/nginx-404.conf
[Definition]
failregex = ^<HOST> -.*"(GET|POST).*(404)"
ignoreregex =
EOF

cat << EOF > /etc/fail2ban/jail.d/custom.conf
[sshd]
enabled = true
maxretry = 5
bantime = 600
findtime = 600

[nginx-404]
enabled = true
port = http,https
filter = nginx-404
logpath = /var/log/nginx/access.log
maxretry = 10
EOF
systemctl enable fail2ban
systemctl restart fail2ban

### 15. Log rotation ###
cat <<EOF > /etc/logrotate.d/vdsadmin
/home/vdsadmin/logs/*.log /home/vdsadmin/logs/errors/*.log {
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
}
EOF

log "Completed successfully."
systemctl reload nginx || log "Failed to reload nginx"
systemctl reload php$PHP_VERSION-fpm || log "Failed to reload php$PHP_VERSION-fpm"
systemctl reload mysql || log "Failed to reload mysql"
log "Postinstall completed."
exit 0

#!/bin/bash

set -euo pipefail
LOG_FILE="/var/log/adddomain.log"
exec > >(tee -a "$LOG_FILE") 2>&1

DOMAIN=$1
PROJECT_TYPE=${2:-default}
WEB_ROOT_BASE="/home/vdsadmin/www"
LOG_ROOT="/home/vdsadmin/logs"
NGINX_VHOST_DIR="/etc/nginx/vhosts"
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
CERTBOT_BIN="/usr/bin/certbot"
EMAIL="webmaster@$(hostname -f)"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') — $1"
}

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 domain.name [laravel]"
  exit 1
fi

log "Setting up virtual host for $DOMAIN"

mkdir -p "$WEB_ROOT_BASE/$DOMAIN"
mkdir -p "$LOG_ROOT/$DOMAIN"
mkdir -p "$LOG_ROOT/errors"

WEB_ROOT="$WEB_ROOT_BASE/$DOMAIN"
if [ "$PROJECT_TYPE" == "laravel" ]; then
  mkdir -p "$WEB_ROOT/public"
  WEB_ROOT="$WEB_ROOT/public"
fi

VHOST_FILE="$NGINX_VHOST_DIR/$DOMAIN.conf"

# Write nginx vhost configuration
cat > "$VHOST_FILE" <<__VHOST__
server {
    listen 80;
    server_name $DOMAIN;

    root $WEB_ROOT;
    index index.php index.html index.htm;

    access_log $LOG_ROOT/$DOMAIN/access.log;
    error_log $LOG_ROOT/errors/$DOMAIN.error.log;

    include /etc/nginx/proxy.conf;
}
__VHOST__

log "Testing nginx configuration"
nginx -t
systemctl reload nginx

# Create unique test file
TEST_CONTENT="test-$(date +%s)-$RANDOM"
echo "$TEST_CONTENT" > "$WEB_ROOT/test.txt"

sleep 2

# Test HTTP access
HTTP_RESPONSE=$(curl -s --max-time 10 "http://$DOMAIN/test.txt" || true)
if [[ "$HTTP_RESPONSE" != "$TEST_CONTENT" ]]; then
  log "HTTP validation failed for $DOMAIN"
  exit 1
fi

# Check certbot existence
if [ ! -x "$CERTBOT_BIN" ]; then
  log "Certbot not installed"
  exit 1
fi

# Request certificate
log "Requesting certificate for $DOMAIN"
$CERTBOT_BIN --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

systemctl reload nginx

sleep 2

# Test HTTPS access
HTTPS_RESPONSE=$(curl -s --max-time 10 --insecure "https://$DOMAIN/test.txt" || true)
if [[ "$HTTPS_RESPONSE" != "$TEST_CONTENT" ]]; then
  log "HTTPS validation failed for $DOMAIN"
  exit 1
fi

log "Virtual host and SSL setup completed for $DOMAIN"
exit 0

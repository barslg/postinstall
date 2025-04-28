#!/bin/bash
# Script to add a new domain with SSL certificate using Certbot
# and Nginx
# This script is intended to be run as root or with sudo privileges
# It creates a new virtual host for the specified domain,
# sets up the web root, and configures SSL using Certbot
# It also includes logging for debugging purposes
# Usage: ./addDomain.sh domain.name [laravel]
# Example: ./addDomain.sh example.com laravel

# This script uses strict error handling by enabling the following options:
# - `set -e`: Exit immediately if a command exits with a non-zero status.
# - `set -u`: Treat unset variables as an error and exit immediately.
# - `set -o pipefail`: Return the exit status of the last command in the pipeline that failed.
# These options ensure robust and predictable script execution.
set -euo pipefail

DOMAIN=$1
LOG_FILE="/var/log/adddomain.log"
PROJECT_TYPE=${2:-default}
WEB_ROOT_BASE="/home/vdsadmin/www"
LOG_ROOT="/home/vdsadmin/logs"
NGINX_VHOST_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
CERTBOT_BIN="/usr/bin/certbot"
EMAIL="webmaster@$(hostname -f)"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] — $1"
}

# Detect the default interface IP address
DEFAULT_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
if [ -z "$DEFAULT_IP" ]; then
  log "Failed to detect default IP address. Exiting."
  exit 1
fi
log "Detected default IP address: $DEFAULT_IP"

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 domain.name [laravel]"
  exit 1
fi

log "Starting setup for domain: $DOMAIN"

# Step 1: Create necessary directories
log "Creating directories for web root and logs"
mkdir -p "$WEB_ROOT_BASE/$DOMAIN" "$LOG_ROOT/errors"


WEB_ROOT="$WEB_ROOT_BASE/$DOMAIN"
if [ "$PROJECT_TYPE" == "laravel" ]; then
  log "Detected Laravel project type, setting up public directory"
  mkdir -p "$WEB_ROOT/public"
  WEB_ROOT="$WEB_ROOT/public"
fi

# Step 2: Create Nginx virtual host configuration
log "Creating Nginx virtual host configuration for $DOMAIN"
VHOST_FILE="$NGINX_VHOST_DIR/$DOMAIN.conf"
echo "server {
    listen $DEFAULT_IP:80; # Listen on the detected IP address
    server_name $DOMAIN;

    root $WEB_ROOT;
    index index.php index.html index.htm;

    access_log $LOG_ROOT/$DOMAIN.access.log;
    error_log $LOG_ROOT/errors/$DOMAIN.error.log;

    include /etc/nginx/proxy.conf;
}" > "$VHOST_FILE"

log "Linking virtual host configuration to enabled sites"
ln -s "$VHOST_FILE" "$NGINX_ENABLED_DIR/$DOMAIN.conf"

# Step 3: Test and reload Nginx configuration
log "Testing Nginx configuration"
nginx -t
log "Reloading Nginx to apply changes"
systemctl reload nginx

# Step 4: Create a unique test file
log "Creating a test file to validate HTTP access"
TEST_CONTENT="test-$(date +%s)-$RANDOM"
echo "$TEST_CONTENT" > "$WEB_ROOT/test.txt"

# Step 5: Validate HTTP access
log "Validating HTTP access to the test file"
HTTP_RESPONSE=$(curl -s --max-time 10 "http://$DOMAIN/test.txt" || true)
if [[ "$HTTP_RESPONSE" != "$TEST_CONTENT" ]]; then
  log "HTTP validation failed for $DOMAIN"
  exit 1
fi
log "HTTP validation successful"

# Step 6: Check Certbot installation
log "Checking if Certbot is installed"
if [ ! -x "$CERTBOT_BIN" ]; then
  log "Certbot not installed, exiting"
  exit 1
fi

# Step 7: Request SSL certificate
log "Requesting SSL certificate for $DOMAIN using Certbot"
$CERTBOT_BIN --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

# Step 8: Reload Nginx after SSL setup
log "Reloading Nginx to apply SSL configuration"
systemctl restart nginx

# Step 9: Validate HTTPS access
log "Validating HTTPS access to the test file"
HTTPS_RESPONSE=$(curl -s --max-time 10 --insecure "https://$DOMAIN/test.txt" || true)
if [[ "$HTTPS_RESPONSE" != "$TEST_CONTENT" ]]; then
  log "HTTPS validation failed for $DOMAIN"
  exit 1
fi
log "HTTPS validation successful"

log "Virtual host and SSL setup completed successfully for $DOMAIN"
exit 0

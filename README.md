# Postinstall Script for Ubuntu 22.04.5 LTS Server

This script automates the setup and configuration of an Ubuntu 22.04.5 LTS server. It installs essential software, configures services, and prepares the server for web hosting and development tasks.

## Features

1. **System Update**
   Updates the system packages and removes unnecessary ones.

2. **Basic Utilities Installation**
   Installs essential utilities like `mc`, `curl`, `wget`, `git`, `ufw`, and more.

3. **PHP Installation**
   Installs PHP and detects its version for further configuration.

4. **Additional Software Installation**
   Installs Nginx, MySQL, Memcached, and additional PHP modules.

5. **User Management**
   Creates a new user `vdsadmin` with sudo privileges and sets up SSH access.

6. **Directory Structure**
   Creates necessary directories for web hosting, logs, certificates, and GitHub keys.

7. **ionCube Loader Installation**
   Installs and configures the ionCube Loader for PHP.

8. **Nginx Configuration**
   Configures Nginx with reusable proxy configurations for PHP and Laravel.

9. **MySQL Configuration**
   Secures MySQL by setting a random root password and enabling remote access.

10. **phpMyAdmin Installation**
    Installs and configures phpMyAdmin for database management.

11. **Firewall and SSH Configuration**
    Configures UFW to allow SSH and enables SFTP access.

12. **Memcached Setup**
    Installs and starts Memcached for caching.

13. **Fail2Ban Configuration**
    Installs and configures Fail2Ban to protect against brute-force attacks.

14. **Log Rotation**
    Sets up log rotation for custom logs in `/home/vdsadmin/logs`.

## Usage

1. Clone or copy the script to your server.
2. Make the script executable:
   ```bash
   chmod +x preinstall.sh
   ```

   or

## Usage for post-install at hosting panel
```bash
   #!/bin/bash
   wget https://raw.githubusercontent.com/barslg/postinstall/refs/heads/main/devops/postinstall.sh -O /root/postinstall.sh
   /bin/bash /root/postinstall.sh
```

# Ubuntu Server Automation Toolkit

A fully automated and production-ready bash-based toolkit for deploying and managing Ubuntu 22.04.5 LTS servers with Laravel or generic PHP projects.

## 🔧 Features

### ✅ `postinstall.sh`
Automates the initial configuration of a fresh Ubuntu server.

- System update and cleanup
- Installs essential software:
  - Nginx, MySQL, PHP (auto-detected version), Memcached
  - Composer, Curl, Git, Ioncube Loader, Fail2ban, Certbot
- Creates `vdsadmin` user with `sudo` and secure SSH access
- Creates standard directory structure:
  - `/home/vdsadmin/www` — websites
  - `/home/vdsadmin/logs` — logs
  - `/home/vdsadmin/certs` — SSL certificates
- Configures:
  - MySQL memory and performance settings
  - PHP-FPM workers based on system RAM
  - Nginx for optimal server performance
- Enables firewall and basic protection
- Logs to `/var/log/postinstall.log` and `/var/log/postinstall_pkg.log`

### ✅ `addDomain.sh`
Adds a new domain with Nginx and Let's Encrypt certificate in seconds.

- Creates new Nginx vhost for specified domain
- Supports Laravel or static/PHP projects
- Auto-detects PHP version
- Sets up directory:
  - `/home/vdsadmin/www/<domain>` and logs to `/home/vdsadmin/logs/<domain>`
- Issues SSL via Certbot with HTTP challenge
- Logs to `/var/log/adddomain.log`

## ⚙️ Usage

### Run post-install configuration:
```bash
sudo bash postinstall.sh
```

or

```bash
#!/bin/bash
wget https://raw.githubusercontent.com/barslg/postinstall/refs/heads/main/devops/postinstall.sh -O /root/postinstall.sh
/bin/bash /root/postinstall.sh
```

### Add a new domain:
```bash
sudo bash addDomain.sh yourdomain.com [laravel]
```

Example for Laravel:
```bash
sudo bash addDomain.sh example.com laravel
```

## 🧱 Requirements

- Ubuntu 22.04.5 LTS
- Root or `sudo` privileges
- Domain with DNS pointing to server's public IP
- Open ports: 22, 80, 443, 873

## 📁 Directory Structure

```
/home/vdsadmin/
├── www/               # Web root for domains
│   └── example.com/
├── logs/              # Nginx logs per domain
├── certs/             # SSL certificates (if not using Certbot)
├── .ssh/              # SSH access for vdsadmin
```

## 🛡️ Security and Best Practices

- Uses `set -euo pipefail` for reliable execution
- Non-interactive APT operations
- All configurations and logics are auditable
- Ensures minimal human interaction
- Auto-detects server specs (RAM, disk, CPU) and configures accordingly


---

> Maintained by [Oleksandr](mailto:barsnata@gmail.com) — built with ❤️ in Norway.

# Remnawave Scripts
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Shell](https://img.shields.io/badge/language-Bash-blue.svg)](#)
[![Remnawave Panel](https://img.shields.io/badge/Installer-Remnawave-brightgreen)](#-remnawave-panel-installer)
[![RemnaNode](https://img.shields.io/badge/Installer-RemnaNode-lightgrey)](#-remnanode-installer)
[![Backup](https://img.shields.io/badge/Tool-Backup-orange)](#-remnawave-backup-script)
[![Restore](https://img.shields.io/badge/Tool-Restore-red)](#%EF%B8%8F-remnawave-restore-script-beta)

![remna-scripts-dark](https://github.com/user-attachments/assets/8edf7e60-7675-4727-8d8b-ff15ec0f85ae)

A collection of Bash scripts to simplify the installation, backup, and restoration of **Remnawave Panel** and **RemnaNode** setups. These scripts are designed for system administrators and technical users who want a clean, CLI-based approach to configuring proxy panels and nodes.

## [Readme на русском](/README_RU.md)
---


## 📚 Table of Contents

* [🚀 Remnawave Panel Installer](#-remnawave-panel-installer)
* [🛰 RemnaNode Installer](#-remnanode-installer)
* [💾 Remnawave Backup Script](#-remnawave-backup-script)
* [🔄 Remnawave Restore Script (BETA)](#%EF%B8%8F-remnawave-restore-script-beta)
* [🤝 Contributing](#-contributing)
* [📜 License](#-license)
* [👥 Join My Community OpeNode.XYZ & NeoNode.cc !](#-community)


---

## 🚀 Remnawave Panel Installer

A universal Bash script to install and manage the [Remnawave Panel](https://github.com/remnawave/). It offers an all-in-one setup experience with full automation and CLI control.

### ✅ Key Features

* CLI interface with commands like `install`, `up`, `down`, `restart`, `logs`, `status`, `edit`, etc.
* Auto-generation of `.env`, secrets, ports, and `docker-compose.yml`
* Optional `--dev` mode for development builds
* Telegram bot notifications
* Secure environment with reverse proxy readiness

---

### 📦 Quick Start

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave.sh)" @ install
```

---

### ⚙️ Installation Flags

| Flag | Description |
| --- | --- |
| `--name` | Set the name of the installation directory (default: `remnawave`) |
| `--dev` | Install the dev version (`remnawave/backend:dev`) |

You can also install **only the script**, without starting the full panel installation:

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave.sh)" @ install-script --name remnawave
```

To remove only the script:

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave.sh)" @ uninstall-script --name remnawave
```

Full example installing the `dev` version under the name `remnawave-2`:

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave.sh)" @ install --name remnawave-2 --dev
```

---

### 🛠 Supported Commands

| Command     | Description                                 |
| ----------- | ------------------------------------------- |
| `install`   | Install the panel                           |
| `update`    | Update script and docker images             |
| `uninstall` | Fully remove the panel                      |
| `up`        | Start containers                            |
| `down`      | Stop containers                             |
| `restart`   | Restart panel                               |
| `status`    | Show running status                         |
| `install-script`     | Install Remnawave script to`/usr/local/bin`|
| `uninstall-script`     |Uninstall Remnawave script|
| `logs`      | View logs                                   |
| `edit`      | Edit `docker-compose.yml` with `$EDITOR`    |
| `edit-env`  | Edit `.env` file with `$EDITOR`             |
| `console`   | Open Remnawave panel's internal CLI console |
| `backup`    | Make DB dump in the /opt/remnawave/backup (--data-only) |

---

### 🔐 Telegram Notifications

Optionally configure Telegram alerts during installation:

* `IS_TELEGRAM_ENABLED=true`
* `TELEGRAM_BOT_TOKEN`
* `TELEGRAM_ADMIN_ID`
* `NODES_NOTIFY_CHAT_ID`
* `*_THREAD_ID` (optional)

> Recommended: Use [@BotFather](https://t.me/BotFather) to create your bot.

---

### 🌍 Reverse Proxy Setup

Ports are bound to `127.0.0.1` by default. Set up your proxy like:

```text
panel.example.com       → 127.0.0.1:3000
sub.example.com/sub     → 127.0.0.1:3010
```

---

### 📂 File Structure

```text
/opt/remnawave/
├── .env
├── docker-compose.yml
└── app-config.json      # Optional
```

---

### 🧩 Requirements

The script automatically installs required packages:

* `curl`
* `docker`
* `docker compose`
* `openssl`
* `nano` or `vi`

---

### 🧼 Uninstall Panel

```bash
remnawave uninstall
```

> ⚠️ You will be asked whether to remove database volumes.

---

## 🛰 RemnaNode Installer

A universal Bash script to install and manage a **RemnaNode** — a proxy node designed to securely connect to Remnawave Panel using **Xray-core**.

---
## 📦 Quick Start

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh)" @ install
```

---

## ✅ Features

* CLI interface (`install`, `up`, `down`, `restart`, `logs`, `status`, etc.)
* Auto-detects and avoids port conflicts
* Installs optional latest Xray-core
* Auto-generates `.env` and `docker-compose.yml`
* Full support for `--dev` branch deployments
* Log rotation and backup system
* Adaptive interface for different terminal sizes
* Support for multiple Linux distributions

---

## ⚙️ Installation Flags

| Flag     | Description                                        |
| -------- | -------------------------------------------------- |
| `--name` | Custom node name (default: remnanode)              |
| `--dev`  | Use `remnawave/node:dev` image instead of `latest` |

---

## 🛠 Supported Commands

| Command       | Description                                       |
| ------------- | ------------------------------------------------- |
| `install`     | Installs RemnaNode                                |
| `update`      | Updates the script and Docker image               |
| `uninstall`   | Removes the node and optionally its data          |
| `up`          | Starts the node                                   |
| `down`        | Stops the node                                    |
| `restart`     | Restarts the node                                 |
| `status`      | Displays if the node is running                   |
| `logs`        | Shows logs                                        |
| `core-update` | Update/change Xray-core interactively             |
| `edit`        | Open `docker-compose.yml` in your terminal editor |
| `setup-logs`  | Configure log rotation                            |
| `xray_log_out`| Show Xray output logs                            |
| `xray_log_err`| Show Xray error logs                             |

---

## 📂 File Structure

```text
/opt/remnanode/
├── .env
└── docker-compose.yml

/var/lib/remnanode/
├── xray               # Xray-core binary if installed
└── *.log              # Xray-core logs

/usr/local/bin/remnanode    # Management script
/etc/logrotate.d/remnanode  # Log rotation configuration
```

---

## 🔐 Xray-core Support

* Downloads and installs latest or chosen version
* Places it under `/var/lib/remnanode/xray`
* Binds it into container at runtime
* Interactive version selection with pre-release support
* Real-time log monitoring

---

## 🌐 Reverse Proxy Example

```text
node.example.com → 127.0.0.1:3000
```

---

## 🛡 Security

Recommended UFW setup after installation:

```bash
# Allow access only from panel IP
sudo ufw allow from PANEL_IP to any port 3000
sudo ufw enable
```

---

## 🔧 System Requirements

* **Minimum 1GB** free disk space
* **Minimum 256MB** available RAM
* **Linux** (Ubuntu, Debian, CentOS, Amazon Linux, Fedora, Arch, openSUSE)
* **Supported architectures**: x86_64, ARM64, ARM32, MIPS

---

## 📊 Monitoring

```bash
# Check status
remnanode status

# View container logs
remnanode logs

# Monitor Xray in real-time
remnanode xray_log_out
```

---

## 🧼 Uninstall Node

```bash
remnanode uninstall
```

> ⚠️ You will be asked whether to delete core data.

---

## 💾 Remnawave Backup Script

Creates backups of the Remnawave database and configuration files, with optional Telegram delivery.

---

### 📦 Quick Start

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave-backup.sh)"
```

---

### 📂 What It Backs Up

* `db_backup.sql` from the Remnawave database
* One of the following:

  * Entire install directory (e.g., `/opt/remnawave`)
  * Specific files: `docker-compose.yml`, `.env`, `app-config.json`

---

### 🔔 Telegram Integration

You’ll be prompted to enter:

* Bot Token
* Chat or Channel ID
* (Optional) Topic ID

> Files are automatically split if exceeding Telegram size limits.

---

## 🧙‍♂️ Remnawave Restore Script (BETA)

Restores Remnawave from a `.tar.gz` archive. **Use with caution on live systems.**

---

### 📦 Quick Start

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/restore.sh)"
```

---

### 🧩 Restore Modes

* **Full restore:**

  * Extracts all files into destination
  * Drops and replaces PostgreSQL data
* **Database-only restore:**

  * Keeps your current files intact
  * Overwrites DB contents from `db_backup.sql`

---

### ✅ Requirements

* `docker`
* `docker compose`
* Archive must contain `db_backup.sql`
* PostgreSQL credentials must be in `.env` or entered manually

---

## 🤝 Contributing

PRs and suggestions are welcome. Stick to Bash and ensure compatibility with Docker.

---

## 🪪 License

MIT License

---

## 🔗 Community

* Forum: [https://openode.xyz](https://openode.xyz) — premium clubs for Marzban, SHM, and Remnawave
* Blog: [https://neonode.cc](https://neonode.cc) — tech articles, guides, and project updates

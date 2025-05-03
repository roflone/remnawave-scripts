# Remnawave Scripts

A collection of Bash scripts to simplify the installation, backup, and restoration of **Remnawave Panel** and **RemnaNode** setups. These scripts are designed for system administrators and technical users who want a clean, CLI-based approach to configuring proxy panels and nodes.

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

| Flag     | Description                                       |
| -------- | ------------------------------------------------- |
| `--name` | Set custom installation name (default: remnawave) |
| `--dev`  | Install dev version of the panel                  |

Example:

```bash
remnawave install --name vpn-panel --dev
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
| `logs`      | View logs                                   |
| `edit`      | Edit `docker-compose.yml` with `$EDITOR`    |
| `edit-env`  | Edit `.env` file with `$EDITOR`             |
| `console`   | Open Remnawave panel's internal CLI console |

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

### 📦 Quick Start

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh)" @ install
```

---

### ✅ Features

* CLI interface (`install`, `up`, `down`, `restart`, `logs`, `status`, etc.)
* Auto-detects and avoids port conflicts
* Installs optional latest Xray-core
* Auto-generates `.env` and `docker-compose.yml`
* Full support for `--dev` branch deployments

---

### ⚙️ Installation Flags

| Flag     | Description                                        |
| -------- | -------------------------------------------------- |
| `--name` | Custom node name (default: remnanode)              |
| `--dev`  | Use `remnawave/node:dev` image instead of `latest` |

---

### 🛠 Supported Commands

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

---

### 📂 File Structure

```text
/opt/remnanode/
├── .env
└── docker-compose.yml

/var/lib/remnanode/
└── xray               # Xray-core binary if installed
```

---

### 🔐 Xray-core Support

* Downloads and installs latest or chosen version
* Places it under `/var/lib/remnanode/xray`
* Binds it into container at runtime

---

### 🌐 Reverse Proxy Example

```text
node.example.com → 127.0.0.1:3000
```

---

### 🧼 Uninstall Node

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

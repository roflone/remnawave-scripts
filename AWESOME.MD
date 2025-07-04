### Remnawave Management Scripts by DigneZzZ

Comprehensive bash scripts for **Remnawave Panel**, **Remnawave Node**, and **Reality Selfsteal** with full automation support. Features Docker integration, automated backups with Telegram notifications, system monitoring, and complete lifecycle management.

📦 **Key Features:**
- 🚀 **One-line installation** for Panel, Node, and Selfsteal configurations
- 🎛️ **Interactive menus** with real-time status monitoring and guided operations
- 💾 **Integrated backup system** with scheduled automation and Telegram delivery
- 🔄 **Complete lifecycle management** - install, update, backup, restore, uninstall
- 🛡️ **Production-ready** with health checks, logging, and error handling
- 🎯 **Reality masking** with 11 AI-generated website templates
- ⚙️ **Advanced configuration** with OAuth, SSL, and performance monitoring
- 🔧 **Xray-core management** with automatic updates and log monitoring

📦 Full info, updates, and examples: [**/remnawave-scripts**](https://github.com/DigneZzZ/remnawave-scripts)

Author: [DigneZzZ](https://github.com/DigneZzZ)

---

<details>
<summary>🚀 Quick Install Commands</summary>

**Remnawave Panel (v3.3.2+):**
```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave.sh)" @ install
```

**Remnawave Node (v3.1.2+):**
```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh)" @ install
```

**Reality Selfsteal (v2.1.3+):**
```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh)" @ install
```

**Options:**
- Add `--dev` for development version
- Add `--name customname` for custom directory (default: `/opt/remnawave`, `/opt/remnanode`)

**For existing installations:**
Use `install-script` to add CLI wrapper only:
```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave.sh)" @ install-script
```

</details>

<details>
<summary>⚙️ Available CLI Commands</summary>

**Installation & Management:**
- `install`, `update`, `uninstall`
- `install-script`, `uninstall-script`

**Service Control:**
- `up`, `down`, `restart`, `status`, `logs`

**Node-specific Commands:**
- `core-update` - Update Xray-core to latest version
- `xray-log-out`, `xray-log-err` - View Xray logs
- `setup-logs` - Configure log rotation

**Configuration:**
- `edit`, `edit-env`, `console` (Panel only)

**Interactive Menus:**
- Run `remnawave`, `remnanode`, or `selfsteal` without arguments for interactive menu
- Real-time status monitoring and resource usage
- Step-by-step guided operations

**Backup & Restore (Panel):**
- `backup` - Create manual backup
- `schedule` - Configure automated backups
- `restore` - Restore from backup archive

**Reality Selfsteal:**
- Choose from 11 AI-generated website templates
- Automatic SSL certificate management
- DNS validation and domain setup

Run `remnawave help`, `remnanode help`, or `selfsteal help` for detailed usage.

</details>

<details>
<summary>💾 Integrated Backup System</summary>

**Automated Features:**
- **Scheduled backups** with cron integration
- **Telegram notifications** with file delivery
- **Compression and retention** management
- **Health monitoring** and failure alerts
- **Database + files** complete backup

**What's backed up:**
- PostgreSQL database as `db_backup.sql`
- Configuration files: `docker-compose.yml`, `.env`, `app-config.json`
- Optional: full directory backup

**Backup Types:**
- **Manual backup:** `remnawave backup`
- **Scheduled backup:** Configure via `remnawave schedule`
- **Full restore:** Automatic or selective restoration from `.tar.gz` archives

**Restore Options:**
- Full restore (replace all files and database)
- Database-only restore (keep existing files)
- Custom directory restoration

**Legacy Standalone Scripts:**
Still available for users who prefer separate backup/restore tools:
- [remnawave-backup.sh](https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave-backup.sh) - Standalone backup script
- [restore.sh](https://github.com/DigneZzZ/remnawave-scripts/raw/main/restore.sh) - Standalone restore script

</details>

<div style={{ display: 'flex', justifyContent: 'center', gap: '1rem' }}>
  <Button label="Github repository" link="https://github.com/DigneZzZ/remnawave-scripts" variant="secondary" size="md" outline />
</div>
<br />
<div style={{ display: 'flex', justifyContent: 'center' }}>
  <img src="/awesome/remnawave-script.webp" alt="Remnawave Management Scripts" width="600" />
</div>

---
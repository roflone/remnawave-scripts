# Remnawave Scripts

A collection of bash scripts to simplify the installation, backup, and restoration of Remnawave and RemnaNode setups. These scripts streamline configuration and maintenance for Remnawave users.

# 🚀 Remnawave Panel Installer

Универсальный Bash-скрипт для установки и управления [Remnawave Panel](https://github.com/remnawave/), включающий:
- удобный CLI-интерфейс (`up`, `down`, `logs`, `console` и др.);
- автогенерацию токенов, паролей и портов;
- поддержку Telegram-уведомлений;
- автоматическую установку зависимостей (`docker`, `docker compose`, `openssl` и др.);
- настройку конфигурации и `docker-compose.yml` в папке `/opt/<название>`.

> ✅ Поддерживает установку **как production, так и dev версии** панели через флаг `--dev`.

---

## 📦 Быстрый старт

```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave.sh)" @ install
````

По умолчанию установка происходит в `/opt/remnawave`.
Скрипт предложит ввести домены, токен бота (если нужен), мета-данные и сгенерирует `.env` и `docker-compose.yml`.

---

## ⚙️ Параметры установки

| Флаг     | Описание                                        |
| -------- | ----------------------------------------------- |
| `--name` | Задать имя установки (по умолчанию `remnawave`) |
| `--dev`  | Установить dev-версию (`remnawave/backend:dev`) |

Пример:

```bash
remnawave install --name remnawave --dev
```

---

## 🛠 Поддерживаемые команды

| Команда     | Описание                                            |
| ----------- | --------------------------------------------------- |
| `install`   | Установка панели Remnawave                          |
| `update`    | Обновление скрипта и образов docker                 |
| `uninstall` | Удаление панели с возможностью очистки volumes      |
| `up`        | Запуск панели                                       |
| `down`      | Остановка панели                                    |
| `restart`   | Перезапуск                                          |
| `status`    | Проверка текущего статуса                           |
| `logs`      | Просмотр логов всех контейнеров                     |
| `edit`      | Редактирование `docker-compose.yml` через `$EDITOR` |
| `edit-env`  | Редактирование `.env` через `$EDITOR`               |
| `console`   | Вход в CLI-интерфейс панели внутри контейнера       |

---

## 🔐 Telegram уведомления

При установке будет предложено включить поддержку Telegram:

* `IS_TELEGRAM_ENABLED=true`
* `TELEGRAM_BOT_TOKEN`
* `TELEGRAM_ADMIN_ID`
* `NODES_NOTIFY_CHAT_ID` (можно оставить как `TELEGRAM_ADMIN_ID`)
* `*_THREAD_ID` — опционально

> 📌 Рекомендуется использовать [BotFather](https://t.me/BotFather) и каналы с включёнными уведомлениями.

---

## 🌍 Обратный прокси

По умолчанию все порты проброшены на `127.0.0.1`, и доступны только локально.

Настрой Nginx, Caddy или другой обратный прокси:

```text
panel.example.com        → 127.0.0.1:3000
sub.example.com/sub      → 127.0.0.1:3010
```

---

## 📂 Структура установки

```text
/opt/remnawave/
├── .env
├── docker-compose.yml
└── app-config.json      # (опционально)
```

---

## 🧩 Требования

Скрипт сам установит всё, что нужно:

* `curl`
* `docker`
* `docker compose`
* `openssl`
* `nano` или `vi`

---

## 📋 Пример команды установки

```bash
remnawave install --name vpn-panel
```

---

## 🧼 Удаление панели

```bash
remnawave uninstall
```

> ⚠️ Скрипт спросит, удалять ли volumes с данными базы.




# RemnaNode Install

Installs a RemnaNode with Xray Core, enabling quick setup of a proxy node compatible with Remnawave for secure and efficient connections.

## Install and Run
```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh)" @ install
```

The script sets up:
- RemnaNode in the working directory `/opt/remnanode`
- Custom Xray Core in `/var/lib/remnanode`
- Command-line interface for management:
  - Run `remnanode help` for available commands
- Optional development branch installation with `--dev` flag

![RemnaNode Install](https://github.com/user-attachments/assets/7f351b1e-0980-4301-8db4-cb922ee7dc48)

## Remnawave Backup Script

Creates backups of the Remnawave database and configuration files, with options to back up specific files or an entire folder. Backups are sent to a Telegram chat for easy access.

### Install and Run
```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnawave-backup.sh)"
```

The script backs up:
- The Remnawave database as `db_backup.sql`
- Either the entire specified folder (e.g., `/opt/remnawave` or user-defined) or specific files:
  - `docker-compose.yml`
  - `.env`
  - `app-config.json` (custom file for the subscription page, see [instructions](https://remna.st/subscription-templating/client-configuration))

![Remnawave Backup](https://github.com/user-attachments/assets/44b10d68-c292-48dc-8131-e3481504d273)

## Remnawave Restore Script (BETA)

Restores Remnawave backups from a `.tar.gz` archive, supporting full restoration (files and database) or database-only. **Warning: This is a beta version. Use with extreme caution, especially on a live Remnawave panel, as it may overwrite critical data or cause instability.**

### Install and Run
```bash
sudo bash -c "$(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/restore.sh)"
```

The script performs the following:
- Clears all existing data in the specified database and restores it from `db_backup.sql`
- Restores files to the chosen directory (e.g., `/opt/remnawave` or user-defined), including:
  - `docker-compose.yml`
  - `.env`
  - `app-config.json` (custom file for the subscription page, see [instructions](https://remna.st/subscription-templating/client-configuration))
- Starts containers to ensure the restored setup is operational

![Remnawave Restore](https://github.com/user-attachments/assets/34ddcde7-ec22-41ee-8ec5-dd10cc3f4d81)

## Contributing

Feel free to open issues or submit pull requests to improve these scripts. Ensure your contributions are compatible with Remnawave and follow the existing script structure.

## License

MIT License

## Join My Community!

Explore my **forum community** at [Openode.xyz](https://openode.xyz), where paid subscription clubs offer in-depth resources on configuring VPNs, proxies, panels, and more. The guides are highly detailed, packed with screenshots and comprehensive explanations to help you not just set up but truly master the tools. The most popular clubs cover **Marzban** and **Remnawave**, with a dedicated premium club for setting up the **SHM panel** (perfect for selling subscriptions via Telegram).

Also, check out my **open blog** at [Neonode.cc](https://neonode.cc) for free tips, tricks, and insights on various tech topics!


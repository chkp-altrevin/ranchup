# 🐮 RanchUp: Simplified Rancher on Docker

*Just another way to do what we do. Enjoy. 🙂*

RanchUp is a lightweight shell-based lifecycle manager to automate your **Rancher on Docker** deployments. With support for install, upgrade, cleanup, rebuilds, and verification, it's your daily Rancher companion.

## 🚀 Quick Start
If you have docker installed it's ok, script will verify and install with consent:

```bash
./provision.sh --install --start
````

This will:

* Install Docker (if missing)
* Pull Rancher (default: `rancher/rancher:stable`)
* Start Rancher with sane defaults

---

## ☁️ Kiosk Mode
Check it out. It's kinda like it says. If you like it enough, autostart it, automate it, auto lock it up for your flows and make Rancher magic.

```bash
./provision.sh --kiosk
```

---

## 🛠️ Actions

```bash
./provision.sh [action] [options]
```

| Flag        | Description                                                    |
| ----------- | -------------------------------------------------------------- |
| `--install` | Installs Docker and Rancher dependencies                       |
| `--start`   | Starts Rancher container                                       |
| `--upgrade` | Upgrades Rancher (requires `--rancher-version`)                |
| `--stop`    | Stops and removes Rancher container                            |
| `--cleanup` | Deletes Rancher container and data (**confirmation required**) |
| `--verify`  | Verifies Rancher is reachable and running                      |
| `--status`  | Displays current Rancher container status                      |
| `--rebuild` | Runs `--cleanup`, `--install`, and `--start` in sequence       |

---

## ⚙️ Optional Flags (Install Mode)

| Flag                | Description                                                              |
| ------------------- | ------------------------------------------------------------------------ |
| `--kiosk`           | Kiosk type menu display, check it out                                    |
| `--rancher-version` | Specify Rancher version (default: `rancher/rancher:stable`)              |
| `--acme-domain`     | Domain name for Let's Encrypt SSL                                        |
| `--volume-value`    | Custom `-v` volume value (default: `-v ./rancher-data:/var/lib/rancher`) |
| `--data-dir`        | Rancher data directory (default: `./rancher-data`)                       |
| `--log-file`        | Log file path (default: `./rancher-lifecycle.log`)                       |

---

## 🧪 Utilities

| Flag        | Description                                 |
| ----------- | ------------------------------------------- |
| `--force`   | Bypass confirmation prompts (dangerous!)    |
| `--dry-run` | Preview actions without executing them      |
| `--offline` | Disable internet access during provisioning |
| `--example` | Show usage examples                         |
| `--help`    | Show full help message                      |

---

## 📦 Examples

```bash
# Install and start Rancher
./provision.sh --install --start

# Upgrade Rancher to a specific version
./provision.sh --upgrade --rancher-version v2.11.2

# Show all available usage examples
./provision.sh --example
```

---

## 🔒 Requirements

* Linux-based host (tested on Ubuntu)
* Bash shell
* Docker (installed automatically if missing)

---

## ✨ Why RanchUp?

* 🔄 Rebuild and redeploy Rancher with ease
* ☁️ Built-in Docker and version management
* 🧹 One-liner cleanup support
* 🔍 Clear, verbose logging and dry-run support

---

## 📜 License

MIT License — do what you want, just don’t blame me when the cows come home. 🐄

---

## 🤝 Contributions

Pull requests welcome! Please file an issue first if you plan large changes. Keep it clean, lean, and Unixy.

---

# 🐮 RanchUp: Simplified Rancher on Docker

*Just another way to do what we do. Enjoy. 🙂*

RanchUp is a lightweight shell-based lifecycle manager to automate your **Rancher on Docker** deployments. With support for install, upgrade, cleanup, rebuilds, and verification, it's your daily Rancher companion.

## 🚀 Quick Start
If you have docker installed it's ok, script will verify and install with consent. If you do not have docker installed it is recommended to run `--install` first, and then run `--install --start` to avoid docker and user permission issues. Both options are listed below:

- Docker already installed, this one is a great option:
```bash
curl -fsSL https://raw.githubusercontent.com/chkp-altrevin/ranchup/main/provision.sh -o provision.sh -f && chmod +x provision.sh && ./provision.sh --install --start
```
- No Docker, this one is for you. Copy & paste below. After it finishes arrow up, (add --start to the end) and re-run.
```bash
curl -fsSL https://raw.githubusercontent.com/chkp-altrevin/ranchup/main/provision.sh -o provision.sh -f && chmod +x provision.sh && ./provision.sh --install
```

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
- Or use a one liner:

```bash
curl -fsSL https://raw.githubusercontent.com/chkp-altrevin/ranchup/main/provision.sh -o provision.sh -f && chmod +x provision.sh && ./provision.sh --kiosk
```

## 🔍 **Log Viewer Features:**

### **📄 Log Display Options:**
1. **Recent Logs** - Last 50 lines for quick overview
2. **Problem Events Only** - Filters for errors, warnings, failures (great for troubleshooting!)
3. **Show All Logs** - Complete container history
4. **Debug Mode** - Container details + timestamped logs
5. **Auto-Refresh** - Live monitoring with multiple modes
6. **Save to File** - Export logs for analysis

### **🔄 Auto-Refresh Modes:**
- **Recent logs** (refreshes every 5 seconds)
- **Problem events** (refreshes every 10 seconds) 
- **Live tail** (real-time streaming)
- All with **Ctrl+C** to stop gracefully

### **💾 Save Options:**
- Recent logs (last 100 lines)
- Complete log history
- Problem events only
- Full debug dump (container inspect + logs)
- Auto-generated timestamped filenames

### **🐛 Debug Mode Includes:**
- Container details (image, status, ports, mounts)
- Recent timestamped logs
- Complete container inspection data

## 🎯 **Key Benefits:**

**For Troubleshooting:**
- Quick problem detection with filtered error/warning view
- Debug mode shows container configuration issues
- Save logs for sharing with support teams

**For Monitoring:**
- Live tail for real-time monitoring during deployments
- Auto-refresh for hands-off monitoring
- Problem-only view to catch issues immediately

**For Documentation:**
- Save logs with timestamps and metadata
- Multiple export formats for different use cases

The log viewer automatically checks if the container exists and provides guidance.
This should make debugging and monitoring your Rancher deployments much more effective! 🚀

---


## 🛠️ Manual Mode

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

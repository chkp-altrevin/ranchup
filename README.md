# rancher-magic
rancher magic shell

```bash
Install Usage:
./provision.sh --install --start (Installs components, dependencies, starts Rancher)

Install Examples:
./provision.sh --install (Installs the components and dependencies)
./provision.sh --upgrade --rancher-version v2.11.2

More Examples:
./provision.sh --example

Actions (Assumes Rancher is Installed):
  --start                 Start Rancher container
  --upgrade               Stop and upgrade Rancher to specified or latest version
  --stop                  Stop and remove Rancher container
  --cleanup               Stop and delete all Rancher data and config (prompts unless --force)
  --verify                Check if Rancher is running
  --status                Show container status (running, stopped, or not found)
  --rebuild               Run cleanup, install, and start in sequence

Optional --install Custom Flags:
  --rancher-version X.Y.Z Override Rancher version (default: rancher/rancher:stable)
  --acme-domain DOMAIN    Let's Encrypt domain name (default: none)
  --volume-value VALUE    Volume value used to map. Use -v (default: -v \$DATA_DIR:/var/lib/rancher)
  --data-dir /path        Path to store Rancher data (default: ./rancher-data)
  --log-file /path        Log file path (default: ./rancher-lifecycle.log)

General:
  --force                 Skip confirmation prompts for cleanup
  --offline               Disable network calls (no effect currently)
  --dry-run               Preview actions without making changes
  --example               Show common usage examples
  --help                  Show this help message
```

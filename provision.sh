#!/bin/bash
set -euo pipefail

# Defaults
RANCHER_VERSION="${RANCHER_VERSION:-}"
ACME_DOMAIN="${ACME_DOMAIN:-}"
VOLUME_VALUE="${VOLUME_VALUE:-}"
DATA_DIR="${DATA_DIR:-$(pwd)/rancher-data}"
LOG_FILE="${LOG_FILE:-rancher-lifecycle.log}"
CONTAINER_NAME="rancher_server"
FORCE_CLEANUP="false"
OFFLINE_MODE="false"
DRY_RUN="false"
ACTION=""

log() {
    echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [ACTION] [OPTIONS]

Examples: ./rancher-provisioner.sh --install --start (Install dependencies, start Rancher)
          ./rancher-provisioner.sh --upgrade --rancher-version v2.11.2

Additional examples: --example

Actions (exactly one required):
  --install               Prepare system (install Docker, jq, curl, create data dir)
  --start                 Start Rancher container
  --upgrade               Stop and upgrade Rancher to specified or latest version
  --stop                  Stop and remove Rancher container
  --cleanup               Stop and delete all Rancher data and config (prompts unless --force)
  --verify                Check if Rancher is running
  --status                Show container status (running, stopped, or not found)
  --rebuild               Run cleanup, install, and start in sequence

Options:
  --rancher-version X.Y.Z Override Rancher version (default: rancher/rancher:stable)
  --acme-domain DOMAIN    Let's Encrypt domain name (default: none)
  --volume-value VALUE    Volume value used to map. Use -v (default: -v \$DATA_DIR:/var/lib/rancher)
  --data-dir /path        Path to store Rancher data (default: ./rancher-data)
  --log-file /path        Log file path (default: ./rancher-lifecycle.log)
  --force                 Skip confirmation prompts for cleanup
  --offline               Disable network calls (no effect currently)
  --dry-run               Preview actions without making changes
  --example               Show common usage examples
  --help                  Show this help message
EOF
    exit 1
}

validate_args() {
    # Check if an action was specified
    [[ -z "$ACTION" ]] && error_exit "No action specified. Use --help for usage information."
    
    # Validate data directory path (create parent if needed)
    if [[ -n "$DATA_DIR" ]]; then
        local parent_dir
        parent_dir=$(dirname "$DATA_DIR")
        if [[ ! -d "$parent_dir" ]]; then
            log "Creating parent directory: $parent_dir"
            mkdir -p "$parent_dir" || error_exit "Cannot create parent directory '$parent_dir'"
        fi
        if [[ ! -w "$parent_dir" ]]; then
            # Try to create a test file to check write permissions
            if ! touch "$parent_dir/.write_test" 2>/dev/null; then
                error_exit "Parent directory '$parent_dir' is not writable"
            fi
            rm -f "$parent_dir/.write_test"
        fi
    fi
    
    # Validate log file path
    if [[ -n "$LOG_FILE" ]]; then
        local log_dir
        log_dir=$(dirname "$LOG_FILE")
        if [[ "$log_dir" != "." ]]; then
            if [[ ! -d "$log_dir" ]]; then
                mkdir -p "$log_dir" || error_exit "Cannot create log directory '$log_dir'"
            fi
        fi
        # Test if we can write to the log file location
        if ! touch "$LOG_FILE" 2>/dev/null; then
            error_exit "Cannot write to log file '$LOG_FILE'"
        fi
    fi
}

parse_args() {
    local actions=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install) actions+=("install"); shift ;;
            --start) actions+=("start"); shift ;;
            --upgrade) actions+=("upgrade"); shift ;;
            --stop) actions+=("stop"); shift ;;
            --cleanup) actions+=("cleanup"); shift ;;
            --verify) actions+=("verify"); shift ;;
            --status) actions+=("status"); shift ;;
            --rebuild) actions+=("rebuild"); shift ;;
            --rancher-version) 
                [[ -z "${2:-}" ]] && error_exit "--rancher-version requires a value"
                RANCHER_VERSION="$2"; shift 2 ;;
            --acme-domain) 
                [[ -z "${2:-}" ]] && error_exit "--acme-domain requires a value"
                ACME_DOMAIN="$2"; shift 2 ;;
            --volume-value) 
                [[ -z "${2:-}" ]] && error_exit "--volume-value requires a value"
                VOLUME_VALUE="$2"; shift 2 ;;
            --data-dir) 
                [[ -z "${2:-}" ]] && error_exit "--data-dir requires a value"
                DATA_DIR="$2"; shift 2 ;;
            --log-file) 
                [[ -z "${2:-}" ]] && error_exit "--log-file requires a value"
                LOG_FILE="$2"; shift 2 ;;
            --force) FORCE_CLEANUP="true"; shift ;;
            --offline) OFFLINE_MODE="true"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --example) show_examples ;;
            --help) usage ;;
            --) shift; break ;;
            -*) error_exit "Unknown option: $1. Use --help for usage information." ;;
            *) error_exit "Unexpected argument: $1. Use --help for usage information." ;;
        esac
    done
    
    # Handle multiple actions (some combinations are valid)
    if [[ ${#actions[@]} -eq 0 ]]; then
        error_exit "No action specified. Use --help for usage information."
    elif [[ ${#actions[@]} -eq 1 ]]; then
        ACTION="${actions[0]}"
    elif [[ ${#actions[@]} -eq 2 ]] && [[ " ${actions[*]} " =~ " install " ]] && [[ " ${actions[*]} " =~ " start " ]]; then
        # Special case: --install --start is allowed
        ACTION="install_and_start"
    else
        error_exit "Invalid action combination: ${actions[*]}. Only --install --start combination is allowed."
    fi
    
    validate_args
}

run_or_echo() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would execute: $*"
    else
        log "Executing: $*"
        eval "$@"
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        error_exit "Docker is not installed. Please install Docker first."
    fi
    
    if ! systemctl is-active --quiet docker; then
        error_exit "Docker is not running. Please start Docker service."
    fi
    
    if ! docker info &>/dev/null; then
        error_exit "Cannot connect to Docker daemon. Please check Docker permissions."
    fi
}

fetch_latest_rancher_version() {
    local version_file=".rancher-version"

    if [[ -n "$RANCHER_VERSION" ]]; then
        log "📌 Using provided Rancher version: $RANCHER_VERSION"
        echo "$RANCHER_VERSION" > "$version_file"
        return
    fi

    log "📌 No version provided. Using default: rancher/rancher:stable"
    RANCHER_VERSION="stable"
    echo "$RANCHER_VERSION" > "$version_file"
}

install_dependencies() {
    log "🔧 Running initial setup (install)..."

    # Check if Rancher container already exists
    if [[ "$DRY_RUN" == "false" ]] && command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        if container_exists; then
            log "⚠️  Rancher container '$CONTAINER_NAME' already exists!"
            log "   To start existing container: ./$(basename "$0") --start"
            log "   To upgrade existing container: ./$(basename "$0") --upgrade --rancher-version X.Y.Z"
            log "   To rebuild from scratch: ./$(basename "$0") --cleanup --force && ./$(basename "$0") --install --start"
            log "   Or use: ./$(basename "$0") --rebuild"
            error_exit "Container already exists. Use --start, --upgrade, --cleanup, or --rebuild instead of --install"
        fi
    fi

    # Check if running as root (not recommended)
    [[ $EUID -eq 0 ]] && log "⚠️  Warning: Running as root is not recommended"

    for tool in docker.io jq curl; do
        if ! command -v "$tool" &>/dev/null; then
            log "📦 Installing missing dependency: $tool"
            if command -v apt-get &>/dev/null; then
                run_or_echo "sudo apt-get update && sudo apt-get install -y $tool"
            elif command -v yum &>/dev/null; then
                run_or_echo "sudo yum install -y $tool"
            elif command -v dnf &>/dev/null; then
                run_or_echo "sudo dnf install -y $tool"
            else
                error_exit "Package manager not found. Please install $tool manually."
            fi
        else
            log "✅ $tool is already installed."
        fi
    done

    # Start and enable Docker service
    if ! systemctl is-active --quiet docker; then
        log "🔌 Starting Docker service..."
        run_or_echo "sudo systemctl start docker"
        run_or_echo "sudo systemctl enable docker"
    fi

    # Add user to docker group if needed
    if ! groups "$USER" | grep -qw docker; then
        log "➕ Adding user '$USER' to docker group (re-login required)"
        run_or_echo "sudo usermod -aG docker $USER"
        log "⚠️  Please log out and log back in for docker group changes to take effect"
    fi

    # Create data directory with proper permissions
    if [[ ! -d "$DATA_DIR" ]]; then
        run_or_echo "mkdir -p '$DATA_DIR'"
        run_or_echo "chmod 755 '$DATA_DIR'"
        log "📁 Created data directory: $DATA_DIR"
    else
        log "📁 Data directory already exists: $DATA_DIR"
    fi

    fetch_latest_rancher_version
    
    # Pull Rancher image
    log "📥 Pulling Rancher image..."
    if [[ "$DRY_RUN" == "false" ]]; then
        check_docker
    fi
    run_or_echo "docker pull rancher/rancher:$RANCHER_VERSION"
    log "✅ Install complete."
}

container_exists() {
    docker ps -a --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"
}

container_running() {
    docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"
}

verify_running() {
    if [[ "$DRY_RUN" == "false" ]]; then
        check_docker
    fi
    
    if container_running; then
        log "✅ Rancher is running."
        return 0
    else
        log "❌ Rancher is NOT running."
        return 1
    fi
}

status_rancher() {
    if [[ "$DRY_RUN" == "false" ]]; then
        check_docker
    fi
    
    if container_running; then
        log "✅ Rancher container '$CONTAINER_NAME' is running."
        # Show additional info
        if [[ "$DRY_RUN" == "false" ]]; then
            local container_info
            container_info=$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}} | {{.State.StartedAt}}' 2>/dev/null || echo "N/A")
            log "   Image: $(echo "$container_info" | cut -d'|' -f1)"
            log "   Started: $(echo "$container_info" | cut -d'|' -f2)"
        fi
    elif container_exists; then
        log "💤 Rancher container '$CONTAINER_NAME' exists but is stopped."
    else
        log "❌ Rancher container '$CONTAINER_NAME' does not exist."
    fi
}

start_rancher() {
    if [[ "$DRY_RUN" == "false" ]]; then
        check_docker
    fi
    
    if [[ -z "$RANCHER_VERSION" ]]; then
        fetch_latest_rancher_version
    fi
    RANCHER_VERSION="${RANCHER_VERSION:-stable}"

    log "🚀 Starting Rancher version $RANCHER_VERSION"

    # Check if container is already running
    if container_running; then
        log "✅ Rancher container is already running."
        return 0
    fi

    # Restart container if it exists but is stopped
    if container_exists; then
        log "♻️ Container '$CONTAINER_NAME' exists but is not running. Restarting..."
        run_or_echo "docker start $CONTAINER_NAME"
        if [[ "$DRY_RUN" == "false" ]]; then
            sleep 5  # Give it a moment to start
            verify_running
        fi
        return 0
    fi

    # Build docker run command
    local docker_cmd="docker run -d --restart=unless-stopped --name $CONTAINER_NAME"
    
    # Volume mount
    if [[ -n "$VOLUME_VALUE" ]]; then
        docker_cmd="$docker_cmd $VOLUME_VALUE"
    else
        docker_cmd="$docker_cmd -v $DATA_DIR:/var/lib/rancher"
    fi
    
    # Port mappings
    docker_cmd="$docker_cmd -p 80:80 -p 443:443"
    
    # ACME support
    if [[ -n "$ACME_DOMAIN" ]]; then
        docker_cmd="$docker_cmd --acme-domain $ACME_DOMAIN"
    fi
    
    # Privileged mode and image
    docker_cmd="$docker_cmd --privileged rancher/rancher:$RANCHER_VERSION"

    # Run new container
    run_or_echo "$docker_cmd"

    if [[ "$DRY_RUN" == "false" ]]; then
        log "⏱  Waiting for Rancher to bootstrap..."
        sleep 60

        # Save bootstrap password if it exists
        if [[ ! -e "$DATA_DIR/k3s" ]]; then
            log "📥 Saving bootstrap password..."
            if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Bootstrap Password:"; then
                docker logs "$CONTAINER_NAME" 2>&1 | grep "Bootstrap Password:" > ./initial-passwd || true
            else
                log "⚠️  Bootstrap password not found in logs yet"
            fi
        fi

        verify_running
    fi
}

stop_rancher() {
    if [[ "$DRY_RUN" == "false" ]]; then
        check_docker
    fi
    
    log "🛑 Stopping Rancher..."
    
    if container_exists; then
        run_or_echo "docker stop '$CONTAINER_NAME' || true"
        run_or_echo "docker rm '$CONTAINER_NAME' || true"
        log "✅ Container stopped and removed"
    else
        log "ℹ️  Container '$CONTAINER_NAME' does not exist"
    fi
}

upgrade_rancher() {
    if [[ -z "$RANCHER_VERSION" ]]; then
        log "⚠️  No version specified for upgrade. Fetching latest..."
        fetch_latest_rancher_version
    fi
    
    log "🔁 Upgrading Rancher to version $RANCHER_VERSION..."
    
    # Pull new image first
    log "📥 Pulling new Rancher image..."
    if [[ "$DRY_RUN" == "false" ]]; then
        check_docker
    fi
    run_or_echo "docker pull rancher/rancher:$RANCHER_VERSION"
    
    stop_rancher
    start_rancher
}

cleanup_rancher() {
    log "🔥 Cleaning up Rancher data..."
    stop_rancher

    # Ask about creating backup first if data directory exists
    local create_backup="no"
    if [[ -d "$DATA_DIR" ]] && [[ "$FORCE_CLEANUP" != "true" ]]; then
        echo -n "❓ Create backup before cleanup? [y/N]: "
        read -r backup_confirm
        create_backup=$(echo "$backup_confirm" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$create_backup" == "y" || "$create_backup" == "yes" ]]; then
            local timestamp backup_root backup_dir
            timestamp=$(date +'%Y%m%d-%H%M%S')
            backup_root="$(pwd)/rancher_backup"
            backup_dir="$backup_root/$(basename "$DATA_DIR")_cleanup_backup_$timestamp"
            
            log "💾 Creating cleanup backup at: $backup_dir"
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would execute: mkdir -p '$backup_root'"
                log "[DRY-RUN] Would execute: sudo cp -r '$DATA_DIR' '$backup_dir'"
                log "[DRY-RUN] Would execute: sudo tar -czf '${backup_dir}.tar.gz' -C '$backup_root' '$(basename "$backup_dir")'"
                log "[DRY-RUN] Would execute: sudo rm -rf '$backup_dir'"
            else
                mkdir -p "$backup_root" || error_exit "Cannot create backup directory"
                
                log "📁 Copying Rancher data (using sudo for permissions)..."
                if sudo cp -r "$DATA_DIR" "$backup_dir"; then
                    log "✅ Data copied successfully"
                    
                    log "📦 Creating compressed backup..."
                    if sudo tar -czf "${backup_dir}.tar.gz" -C "$backup_root" "$(basename "$backup_dir")"; then
                        log "✅ Cleanup backup created: ${backup_dir}.tar.gz"
                        sudo rm -rf "$backup_dir"
                    else
                        log "⚠️  Failed to create compressed backup, keeping directory backup"
                    fi
                else
                    error_exit "Failed to create backup of Rancher data"
                fi
            fi
        fi
    fi

    local delete_data_dir="no"
    if [[ "$FORCE_CLEANUP" == "true" ]]; then
        delete_data_dir="yes"
    else
        echo -n "❓ Delete Rancher data at '$DATA_DIR'? [y/N]: "
        read -r confirm
        delete_data_dir=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    fi

    if [[ "$delete_data_dir" == "y" || "$delete_data_dir" == "yes" ]]; then
        if [[ -d "$DATA_DIR" ]]; then
            log "🧹 Attempting to delete data directory: $DATA_DIR"
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would execute: rm -rf '$DATA_DIR'"
            else
                # Try normal deletion first
                if rm -rf "$DATA_DIR" 2>/dev/null; then
                    log "✅ Successfully deleted data directory"
                else
                    log "⚠️  Normal deletion failed, attempting with sudo..."
                    if sudo rm -rf "$DATA_DIR"; then
                        log "✅ Successfully deleted data directory using sudo"
                    else
                        error_exit "Failed to delete data directory even with sudo"
                    fi
                fi
            fi
        else
            log "ℹ️  Data directory '$DATA_DIR' does not exist"
        fi
    else
        log "🛑 Skipped data directory deletion."
    fi

    # Clean up auxiliary files
    [[ -f "initial-passwd" ]] && run_or_echo "rm -f initial-passwd"
    [[ -f ".rancher-version" ]] && run_or_echo "rm -f .rancher-version"
}

rebuild_rancher() {
    log "🔄 Rebuilding Rancher environment..."

    local original_force="$FORCE_CLEANUP"
    FORCE_CLEANUP="true"

    # Create backup if data exists
    if [[ -d "$DATA_DIR" ]]; then
        local timestamp backup_root backup_dir
        timestamp=$(date +'%Y%m%d-%H%M%S')
        backup_root="$(pwd)/rancher_backup"
        backup_dir="$backup_root/$(basename "$DATA_DIR")_backup_$timestamp"
        
        log "💾 Creating snapshot backup at: $backup_dir"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would execute: mkdir -p '$backup_root'"
            log "[DRY-RUN] Would execute: sudo cp -r '$DATA_DIR' '$backup_dir'"
            log "[DRY-RUN] Would execute: sudo tar -czf '${backup_dir}.tar.gz' -C '$backup_root' '$(basename "$backup_dir")'"
            log "[DRY-RUN] Would execute: sudo rm -rf '$backup_dir'"
        else
            mkdir -p "$backup_root" || error_exit "Cannot create backup directory"
            
            # Use sudo for cp in case of permission issues with Rancher data
            log "📁 Copying Rancher data (using sudo for permissions)..."
            if sudo cp -r "$DATA_DIR" "$backup_dir"; then
                log "✅ Data copied successfully"
                
                # Create compressed backup (using sudo to handle permission issues)
                log "📦 Creating compressed backup..."
                if sudo tar -czf "${backup_dir}.tar.gz" -C "$backup_root" "$(basename "$backup_dir")"; then
                    log "✅ Compressed backup created: ${backup_dir}.tar.gz"
                    
                    # Remove uncompressed backup directory (using sudo)
                    sudo rm -rf "$backup_dir"
                else
                    log "⚠️  Failed to create compressed backup, keeping directory backup"
                fi
            else
                error_exit "Failed to create backup of Rancher data"
            fi
        fi

        # Prune old backups
        log "🧹 Pruning old backups in $backup_root (keeping 7 most recent)"
        if [[ "$DRY_RUN" == "false" ]] && [[ -d "$backup_root" ]]; then
            # More portable approach to prune old backups - only count .tar.gz files
            local backup_count
            backup_count=$(find "$backup_root" -maxdepth 1 -name "*.tar.gz" -type f | wc -l)
            
            if [[ $backup_count -gt 7 ]]; then
                log "📊 Found $backup_count backups, removing oldest..."
                # Use ls with time sorting (more portable than stat) - only target .tar.gz files
                if ls -t "$backup_root"/*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f; then
                    log "✅ Old backups pruned successfully"
                    
                    # Also clean up any leftover uncompressed directories from failed previous runs
                    log "🧹 Cleaning up any leftover backup directories..."
                    find "$backup_root" -maxdepth 1 -type d -name "*_backup_*" -exec sudo rm -rf {} \; 2>/dev/null || true
                else
                    log "⚠️  Could not prune old backups (will clean up manually if needed)"
                fi
            else
                log "📊 Only $backup_count backups found, no pruning needed"
            fi
        fi
    fi

    cleanup_rancher
    FORCE_CLEANUP="$original_force"

    install_dependencies
    start_rancher
}

show_examples() {
    cat <<EOF

🔧 Rancher Lifecycle Script – Usage Examples:

🛠 Install dependencies and start Rancher:
  ./$(basename "$0") --install --start
  ./$(basename "$0") --install --rancher-version v2.11.2 --start

🚀 Start the Rancher container:
  ./$(basename "$0") --start

♻️ Upgrade Rancher to latest or pinned version:
  ./$(basename "$0") --upgrade --rancher-version v2.11.2

🛑 Stop the Rancher container:
  ./$(basename "$0") --stop

🔥 Force cleanup of Rancher data:
  ./$(basename "$0") --cleanup --force

🔁 Full rebuild with backup, cleanup, install, and start:
  ./$(basename "$0") --rebuild

📁 Use custom volume mapping:
  ./$(basename "$0") --start --volume-value "-v /opt/rancher-data:/var/lib/rancher"

📁 Use a custom data directory:
  ./$(basename "$0") --install --data-dir /opt/rancher-data

🔍 Dry-run any action for safety:
  ./$(basename "$0") --cleanup --dry-run

📡 Start with Let's Encrypt:
  ./$(basename "$0") --start --acme-domain rancher.example.com

🔍 Check status:
  ./$(basename "$0") --status
  ./$(basename "$0") --verify

EOF
    exit 0
}

main() {
    # Parse arguments first
    parse_args "$@"
    
    # Initialize logging (create log directory if needed, but skip if it's current directory)
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [[ "$log_dir" != "." ]] && [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir"
    fi
    
    log "📌 Action: $ACTION | Data: $DATA_DIR | Version: ${RANCHER_VERSION:-(unspecified)} | Dry Run: $DRY_RUN"

    case "$ACTION" in
        install) 
            install_dependencies 
            # Show next steps only for install-only operations
            log ""
            log "📋 Next Steps:"
            log "   1. Start Rancher: ./$(basename "$0") --start"
            log "   2. After starting, the bootstrap password will be saved to: $(pwd)/initial-passwd"
            log "   3. Access Rancher UI at: https://$(hostname -I | awk '{print $1}') or https://your-domain"
            log "   4. Use the bootstrap password for initial login"
            log ""
            ;;
        start) start_rancher ;;
        stop) stop_rancher ;;
        upgrade) upgrade_rancher ;;
        cleanup) cleanup_rancher ;;
        verify) verify_running ;;
        status) status_rancher ;;
        rebuild) rebuild_rancher ;;
        install_and_start) 
            install_dependencies
            start_rancher
            # Show completion message with password info for combined operations
            if [[ "$DRY_RUN" == "false" ]]; then
                log ""
                log "🎉 Installation and startup complete!"
                
                # Try to get the password from the file first, then from container logs
                local password=""
                if [[ -f "initial-passwd" ]]; then
                    password=$(grep "Bootstrap Password:" initial-passwd 2>/dev/null | cut -d' ' -f3- | tr -d '\r\n' || echo "")
                fi
                
                # If not in file, try to get it from container logs
                if [[ -z "$password" ]]; then
                    log "📄 Extracting bootstrap password from container logs..."
                    password=$(docker logs "$CONTAINER_NAME" 2>&1 | grep "Bootstrap Password:" | tail -1 | cut -d' ' -f3- | tr -d '\r\n' 2>/dev/null || echo "")
                    
                    # Save it to file for future reference
                    if [[ -n "$password" ]]; then
                        echo "Bootstrap Password: $password" > ./initial-passwd
                        log "📄 Bootstrap password saved to: $(pwd)/initial-passwd"
                    fi
                fi
                
                if [[ -n "$password" ]]; then
                    log "🔑 Bootstrap password: $password"
                else
                    log "⚠️  Bootstrap password not found yet. Check container logs with:"
                    log "   docker logs $CONTAINER_NAME 2>&1 | grep 'Bootstrap Password:'"
                fi
                
                log "🌐 Access Rancher UI at: https://$(hostname -I | awk '{print $1}') or https://your-domain"
                log ""
            fi
            ;;
        *) error_exit "Invalid action: $ACTION" ;;
    esac
    
    log "✅ Action '$ACTION' completed successfully"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

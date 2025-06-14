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
KIOSK_MODE="false"
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
          ./rancher-provisioner.sh --kiosk (Interactive menu mode)

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
  --kiosk                 Launch interactive menu mode

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

# Kiosk Mode Functions
clear_screen() {
    clear
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                           🐄 RANCHER LIFECYCLE MANAGER                <<======\\"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
}

show_current_status() {
    echo "📊 Current Status:"
    echo "   Data Directory: $DATA_DIR"
    echo "   Log File: $LOG_FILE"
    echo "   Container Name: $CONTAINER_NAME"
    if [[ -n "$RANCHER_VERSION" ]]; then
        echo "   Rancher Version: $RANCHER_VERSION"
    else
        echo "   Rancher Version: (auto-detect latest)"
    fi
    
    # Check container status
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        if container_running; then
            echo "   Container Status: ✅ RUNNING"
        elif container_exists; then
            echo "   Container Status: 💤 STOPPED"
        else
            echo "   Container Status: ❌ NOT FOUND"
        fi
    else
        echo "   Container Status: ⚠️  DOCKER NOT AVAILABLE"
    fi
    echo ""
}

kiosk_menu() {
    while true; do
        clear_screen
        show_current_status
        
        echo "🎛️  Main Menu - Select an action:"
        echo ""
        echo "   1) 🛠️  Install Dependencies     - Prepare system for Rancher"
        echo "   2) 🚀 Start Rancher            - Launch Rancher container"
        echo "   3) 🔄 Install + Start          - Complete setup in one step"
        echo "   4) 🛑 Stop Rancher             - Stop and remove container"
        echo "   5) ♻️  Upgrade Rancher          - Update to newer version"
        echo "   6) 🔁 Rebuild Everything       - Complete reinstall with backup"
        echo "   7) 🔥 Cleanup All Data         - Remove all Rancher data"
        echo "   8) 📊 Show Status              - Display detailed status"
        echo "   9) 🔍 Verify Running           - Check if Rancher is operational"
        echo "  10) 📋 View Logs                - Monitor container logs"
        echo "  11) ⚙️ Settings                 - Configure options"
        echo "   0) 🚪 Exit                     - Quit kiosk mode"
        echo ""
        echo -n "Enter your choice [0-11]: "
        
        local choice
        read -r choice
        
        case "$choice" in
            1)
                kiosk_smart_install
                ;;
            2)
                echo ""
                echo "🚀 Starting Rancher..."
                ACTION="start"
                start_rancher
                kiosk_pause
                ;;
            3)
                kiosk_smart_install_and_start
                ;;
            4)
                echo ""
                echo "🛑 Stopping Rancher..."
                ACTION="stop"
                stop_rancher
                kiosk_pause
                ;;
            5)
                kiosk_upgrade_menu
                ;;
            6)
                echo ""
                echo "🔁 Rebuilding everything (this will backup existing data)..."
                echo "⚠️  This will stop, backup, cleanup, and reinstall Rancher."
                echo -n "Continue? [y/N]: "
                local confirm
                read -r confirm
                if [[ "${confirm,,}" == "y" ]]; then
                    ACTION="rebuild"
                    rebuild_rancher
                    kiosk_show_completion_info
                fi
                kiosk_pause
                ;;
            7)
                kiosk_cleanup_menu
                ;;
            8)
                echo ""
                ACTION="status"
                status_rancher
                kiosk_pause
                ;;
            9)
                echo ""
                ACTION="verify"
                if verify_running; then
                    echo "✅ Rancher is running and accessible"
                else
                    echo "❌ Rancher is not running or not accessible"
                fi
                kiosk_pause
                ;;
            10)
                kiosk_logs_menu
                ;;
            11)
                kiosk_settings_menu
                ;;
            0)
                echo ""
                echo "👋 Exiting kiosk mode. Goodbye!"
                exit 0
                ;;
            *)
                echo ""
                echo "❌ Invalid choice. Please select 0-11."
                sleep 2
                ;;
        esac
    done
}

kiosk_smart_install() {
    clear_screen
    echo "🛠️  Smart Install - Dependency Check"
    echo ""
    
    # Check if container already exists
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1 && container_exists; then
        if container_running; then
            echo "✅ Rancher container '$CONTAINER_NAME' is already running!"
            echo ""
            echo "📊 Current Status:"
            local container_info
            container_info=$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}} | {{.State.StartedAt}}' 2>/dev/null || echo "N/A")
            echo "   Image: $(echo "$container_info" | cut -d'|' -f1)"
            echo "   Started: $(echo "$container_info" | cut -d'|' -f2)"
            echo ""
            echo "🎯 What would you like to do?"
            echo ""
            echo "  1) 📊 Show detailed status"
            echo "  2) 📋 View container logs"
            echo "  3) ♻️  Upgrade to newer version"
            echo "  4) 🔁 Rebuild everything (fresh install)"
            echo "  0) ⬅️  Back to main menu"
            echo ""
            echo -n "Enter your choice [0-4]: "
            
            local choice
            read -r choice
            
            case "$choice" in
                1)
                    echo ""
                    ACTION="status"
                    status_rancher
                    kiosk_pause
                    ;;
                2)
                    kiosk_logs_menu
                    ;;
                3)
                    kiosk_upgrade_menu
                    ;;
                4)
                    echo ""
                    echo "🔁 This will backup existing data and do a fresh install."
                    echo -n "Continue? [y/N]: "
                    local confirm
                    read -r confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        ACTION="rebuild"
                        rebuild_rancher
                        kiosk_show_completion_info
                        kiosk_pause
                    fi
                    ;;
                0)
                    return
                    ;;
                *)
                    echo "❌ Invalid choice"
                    sleep 2
                    ;;
            esac
        else
            echo "💤 Rancher container '$CONTAINER_NAME' exists but is stopped."
            echo ""
            echo "🎯 What would you like to do?"
            echo ""
            echo "  1) 🚀 Start the existing container"
            echo "  2) ♻️  Upgrade to newer version"
            echo "  3) 🔁 Rebuild everything (fresh install)"
            echo "  4) 🔥 Remove existing container and install fresh"
            echo "  0) ⬅️  Back to main menu"
            echo ""
            echo -n "Enter your choice [0-4]: "
            
            local choice
            read -r choice
            
            case "$choice" in
                1)
                    echo ""
                    echo "🚀 Starting existing Rancher container..."
                    ACTION="start"
                    start_rancher
                    kiosk_pause
                    ;;
                2)
                    kiosk_upgrade_menu
                    ;;
                3)
                    echo ""
                    echo "🔁 This will backup existing data and do a fresh install."
                    echo -n "Continue? [y/N]: "
                    local confirm
                    read -r confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        ACTION="rebuild"
                        rebuild_rancher
                        kiosk_show_completion_info
                        kiosk_pause
                    fi
                    ;;
                4)
                    echo ""
                    echo "🔥 This will remove the existing container and install fresh."
                    echo "⚠️  Data will be lost unless you backup first!"
                    echo -n "Continue? [y/N]: "
                    local confirm
                    read -r confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        echo ""
                        echo "🛑 Stopping and removing existing container..."
                        ACTION="stop"
                        stop_rancher
                        echo ""
                        echo "🛠️  Installing dependencies..."
                        ACTION="install"
                        install_dependencies
                        kiosk_pause
                    fi
                    ;;
                0)
                    return
                    ;;
                *)
                    echo "❌ Invalid choice"
                    sleep 2
                    ;;
            esac
        fi
    else
        # No existing container, proceed with normal install
        echo "📦 No existing Rancher container found. Proceeding with installation..."
        echo ""
        
        # Check if Docker is installed
        if ! command -v docker &>/dev/null; then
            echo "🐳 Docker not found - will be installed as part of dependencies"
        else
            echo "✅ Docker is already installed"
        fi
        
        # Check other dependencies
        local missing_deps=()
        for tool in jq curl; do
            if ! command -v "$tool" &>/dev/null; then
                missing_deps+=("$tool")
            fi
        done
        
        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            echo "📦 Missing dependencies that will be installed: ${missing_deps[*]}"
        else
            echo "✅ All basic dependencies are already installed"
        fi
        
        echo ""
        echo "🎯 Installation options:"
        echo ""
        echo "  1) 🛠️  Install dependencies only"
        echo "  2) 🔄 Install dependencies + start Rancher"
        echo "  0) ⬅️  Back to main menu"
        echo ""
        echo -n "Enter your choice [0-2]: "
        
        local choice
        read -r choice
        
        case "$choice" in
            1)
                echo ""
                echo "🛠️  Installing dependencies..."
                ACTION="install"
                install_dependencies
                kiosk_pause
                ;;
            2)
                echo ""
                echo "🔄 Installing dependencies and starting Rancher..."
                ACTION="install_and_start"
                install_dependencies
                start_rancher
                kiosk_show_completion_info
                kiosk_pause
                ;;
            0)
                return
                ;;
            *)
                echo "❌ Invalid choice"
                sleep 2
                ;;
        esac
    fi
}

kiosk_smart_install_and_start() {
    clear_screen
    echo "🔄 Smart Install + Start - Complete Setup"
    echo ""
    
    # Check if container already exists
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1 && container_exists; then
        if container_running; then
            echo "✅ Rancher container '$CONTAINER_NAME' is already running!"
            echo ""
            echo "📊 Current Status:"
            local container_info
            container_info=$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}} | {{.State.StartedAt}}' 2>/dev/null || echo "N/A")
            echo "   Image: $(echo "$container_info" | cut -d'|' -f1)"
            echo "   Started: $(echo "$container_info" | cut -d'|' -f2)"
            echo ""
            echo "🎯 Rancher is already up and running! What would you like to do?"
            echo ""
            echo "  1) 📊 Show detailed status"
            echo "  2) 📋 View container logs"
            echo "  3) ♻️  Upgrade to newer version"
            echo "  4) 🔁 Rebuild everything (fresh install)"
            echo "  0) ⬅️  Back to main menu"
            echo ""
            echo -n "Enter your choice [0-4]: "
            
            local choice
            read -r choice
            
            case "$choice" in
                1)
                    echo ""
                    ACTION="status"
                    status_rancher
                    kiosk_pause
                    ;;
                2)
                    kiosk_logs_menu
                    ;;
                3)
                    kiosk_upgrade_menu
                    ;;
                4)
                    echo ""
                    echo "🔁 This will backup existing data and do a fresh install."
                    echo -n "Continue? [y/N]: "
                    local confirm
                    read -r confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        ACTION="rebuild"
                        rebuild_rancher
                        kiosk_show_completion_info
                        kiosk_pause
                    fi
                    ;;
                0)
                    return
                    ;;
                *)
                    echo "❌ Invalid choice"
                    sleep 2
                    ;;
            esac
        else
            echo "💤 Rancher container '$CONTAINER_NAME' exists but is stopped."
            echo ""
            echo "🎯 What would you like to do?"
            echo ""
            echo "  1) 🚀 Start the existing container"
            echo "  2) ♻️  Upgrade and start with newer version"
            echo "  3) 🔁 Rebuild everything (fresh install + start)"
            echo "  0) ⬅️  Back to main menu"
            echo ""
            echo -n "Enter your choice [0-3]: "
            
            local choice
            read -r choice
            
            case "$choice" in
                1)
                    echo ""
                    echo "🚀 Starting existing Rancher container..."
                    ACTION="start"
                    start_rancher
                    kiosk_show_completion_info
                    kiosk_pause
                    ;;
                2)
                    kiosk_upgrade_menu
                    ;;
                3)
                    echo ""
                    echo "🔁 This will backup existing data and do a fresh install."
                    echo -n "Continue? [y/N]: "
                    local confirm
                    read -r confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        ACTION="rebuild"
                        rebuild_rancher
                        kiosk_show_completion_info
                        kiosk_pause
                    fi
                    ;;
                0)
                    return
                    ;;
                *)
                    echo "❌ Invalid choice"
                    sleep 2
                    ;;
            esac
        fi
    else
        # No existing container, proceed with normal install + start
        echo "📦 No existing Rancher container found. Proceeding with complete setup..."
        echo ""
        
        # Check if Docker is installed
        if ! command -v docker &>/dev/null; then
            echo "🐳 Docker not found - will be installed as part of dependencies"
        else
            echo "✅ Docker is already installed"
        fi
        
        # Check other dependencies
        local missing_deps=()
        for tool in jq curl; do
            if ! command -v "$tool" &>/dev/null; then
                missing_deps+=("$tool")
            fi
        done
        
        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            echo "📦 Missing dependencies that will be installed: ${missing_deps[*]}"
        else
            echo "✅ All basic dependencies are already installed"
        fi
        
        echo ""
        echo "🚀 Ready to install dependencies and start Rancher!"
        echo -n "Continue with complete setup? [Y/n]: "
        
        local choice
        read -r choice
        choice=${choice:-y}  # Default to 'y' if empty
        
        if [[ "${choice,,}" == "y" ]]; then
            echo ""
            echo "🔄 Installing dependencies and starting Rancher..."
            ACTION="install_and_start"
            install_dependencies
            start_rancher
            kiosk_show_completion_info
            kiosk_pause
        else
            echo "❌ Setup cancelled"
            sleep 2
        fi
    fi
}
kiosk_upgrade_menu() {
    clear_screen
    echo "♻️  Upgrade Rancher"
    echo ""
    echo "Current version setting: ${RANCHER_VERSION:-(auto-detect latest)}"
    echo ""
    echo "1) Upgrade to latest stable"
    echo "2) Specify version"
    echo "3) Back to main menu"
    echo ""
    echo -n "Enter your choice [1-3]: "
    
    local choice
    read -r choice
    
    case "$choice" in
        1)
            RANCHER_VERSION="stable"
            echo ""
            echo "♻️  Upgrading to latest stable version..."
            ACTION="upgrade"
            upgrade_rancher
            kiosk_pause
            ;;
        2)
            echo ""
            echo -n "Enter Rancher version (e.g., v2.11.2): "
            read -r version
            if [[ -n "$version" ]]; then
                RANCHER_VERSION="$version"
                echo ""
                echo "♻️  Upgrading to version $version..."
                ACTION="upgrade"
                upgrade_rancher
                kiosk_pause
            else
                echo "❌ Version cannot be empty"
                sleep 2
            fi
            ;;
        3)
            return
            ;;
        *)
            echo "❌ Invalid choice"
            sleep 2
            ;;
    esac
}

kiosk_cleanup_menu() {
    clear_screen
    echo "🔥 Cleanup Rancher Data"
    echo ""
    echo "⚠️  WARNING: This will permanently delete all Rancher data!"
    echo "   Data directory: $DATA_DIR"
    echo ""
    echo "1) Cleanup with backup"
    echo "2) Force cleanup (no backup)"
    echo "3) Back to main menu"
    echo ""
    echo -n "Enter your choice [1-3]: "
    
    local choice
    read -r choice
    
    case "$choice" in
        1)
            echo ""
            echo "🔥 Cleaning up with backup..."
            FORCE_CLEANUP="false"
            ACTION="cleanup"
            cleanup_rancher
            kiosk_pause
            ;;
        2)
            echo ""
            echo "⚠️  Are you ABSOLUTELY sure? This cannot be undone!"
            echo -n "Type 'YES' to confirm: "
            local confirm
            read -r confirm
            if [[ "$confirm" == "YES" ]]; then
                echo ""
                echo "🔥 Force cleaning up..."
                FORCE_CLEANUP="true"
                ACTION="cleanup"
                cleanup_rancher
                FORCE_CLEANUP="false" # Reset to default
            else
                echo "❌ Cleanup cancelled"
                sleep 2
            fi
            kiosk_pause
            ;;
        3)
            return
            ;;
        *)
            echo "❌ Invalid choice"
            sleep 2
            ;;
    esac
}

kiosk_logs_menu() {
    while true; do
        clear_screen
        echo "📋 Container Logs Viewer"
        echo ""
        
        # Check if container exists
        if ! container_exists; then
            echo "❌ Rancher container '$CONTAINER_NAME' does not exist."
            echo "   Please install and start Rancher first."
            echo ""
            echo "Press Enter to return to main menu..."
            read -r
            return
        fi
        
        echo "Log Viewing Options:"
        echo ""
        echo "  1) 📄 Show Recent Logs (last 50 lines)"
        echo "  2) 🔍 Show Problem Events Only (errors/warnings)"
        echo "  3) 📜 Show All Logs"
        echo "  4) 🐛 Debug Mode (detailed logging)"
        echo "  5) 🔄 Auto-Refresh Logs (live tail)"
        echo "  6) 💾 Save Logs to File"
        echo "  0) ⬅️  Back to Main Menu"
        echo ""
        echo -n "Enter your choice [0-6]: "
        
        local choice
        read -r choice
        
        case "$choice" in
            1)
                kiosk_show_logs "recent"
                ;;
            2)
                kiosk_show_logs "problems"
                ;;
            3)
                kiosk_show_logs "all"
                ;;
            4)
                kiosk_show_logs "debug"
                ;;
            5)
                kiosk_auto_refresh_logs
                ;;
            6)
                kiosk_save_logs
                ;;
            0)
                return
                ;;
            *)
                echo ""
                echo "❌ Invalid choice. Please select 0-6."
                sleep 2
                ;;
        esac
    done
}

kiosk_show_logs() {
    local log_type="$1"
    clear_screen
    
    case "$log_type" in
        "recent")
            echo "📄 Recent Logs (last 50 lines):"
            echo "═══════════════════════════════════════════════════════════════════════════════"
            docker logs --tail 50 "$CONTAINER_NAME" 2>&1 || echo "❌ Failed to retrieve logs"
            ;;
        "problems")
            echo "🔍 Problem Events (Errors & Warnings):"
            echo "═══════════════════════════════════════════════════════════════════════════════"
            docker logs "$CONTAINER_NAME" 2>&1 | grep -iE "(error|warn|fail|exception|panic|fatal)" | tail -30 || echo "✅ No recent problems found"
            ;;
        "all")
            echo "📜 All Container Logs:"
            echo "═══════════════════════════════════════════════════════════════════════════════"
            echo "⚠️  This may be very long. Press Ctrl+C to stop if needed."
            echo ""
            sleep 2
            docker logs "$CONTAINER_NAME" 2>&1 || echo "❌ Failed to retrieve logs"
            ;;
        "debug")
            echo "🐛 Debug Mode - Detailed Container Information:"
            echo "═══════════════════════════════════════════════════════════════════════════════"
            echo ""
            echo "📊 Container Details:"
            docker inspect "$CONTAINER_NAME" --format '
🏷️  Name: {{.Name}}
🖼️  Image: {{.Config.Image}}
🔄 Status: {{.State.Status}}
⏰ Created: {{.Created}}
🚀 Started: {{.State.StartedAt}}
🔌 Ports: {{range $p, $conf := .NetworkSettings.Ports}}{{$p}} -> {{(index $conf 0).HostPort}} {{end}}
💾 Mounts: {{range .Mounts}}{{.Source}} -> {{.Destination}} {{end}}' 2>/dev/null || echo "❌ Failed to retrieve container details"
            
            echo ""
            echo "📋 Recent Logs with Timestamps:"
            echo "───────────────────────────────────────────────────────────────────────────────"
            docker logs --timestamps --tail 20 "$CONTAINER_NAME" 2>&1 || echo "❌ Failed to retrieve logs"
            ;;
    esac
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    kiosk_pause
}

kiosk_auto_refresh_logs() {
    clear_screen
    echo "🔄 Auto-Refresh Logs (Live Tail)"
    echo ""
    echo "Options:"
    echo "  1) Recent logs (last 20 lines, refresh every 5 seconds)"
    echo "  2) Problem events only (refresh every 10 seconds)"
    echo "  3) Live tail (real-time streaming)"
    echo "  0) Back to logs menu"
    echo ""
    echo -n "Enter your choice [0-3]: "
    
    local choice
    read -r choice
    
    case "$choice" in
        1)
            clear_screen
            echo "🔄 Auto-Refreshing Recent Logs (Press Ctrl+C to stop)"
            echo "═══════════════════════════════════════════════════════════════════════════════"
            echo ""
            
            trap 'echo ""; echo "⏹️  Auto-refresh stopped."; sleep 2; return' INT
            while true; do
                echo -e "\033[2J\033[H" # Clear screen and move cursor to top
                echo "🔄 Auto-Refreshing Recent Logs - $(date) (Press Ctrl+C to stop)"
                echo "═══════════════════════════════════════════════════════════════════════════════"
                docker logs --tail 20 --timestamps "$CONTAINER_NAME" 2>&1 | tail -15 || echo "❌ Failed to retrieve logs"
                echo ""
                echo "Next refresh in 5 seconds..."
                sleep 5
            done
            ;;
        2)
            clear_screen
            echo "🔍 Auto-Refreshing Problem Events (Press Ctrl+C to stop)"
            echo "═══════════════════════════════════════════════════════════════════════════════"
            echo ""
            
            trap 'echo ""; echo "⏹️  Auto-refresh stopped."; sleep 2; return' INT
            while true; do
                echo -e "\033[2J\033[H" # Clear screen and move cursor to top
                echo "🔍 Auto-Refreshing Problem Events - $(date) (Press Ctrl+C to stop)"
                echo "═══════════════════════════════════════════════════════════════════════════════"
                local problems
                problems=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -iE "(error|warn|fail|exception|panic|fatal)" | tail -10)
                if [[ -n "$problems" ]]; then
                    echo "$problems"
                else
                    echo "✅ No recent problems detected"
                fi
                echo ""
                echo "Next refresh in 10 seconds..."
                sleep 10
            done
            ;;
        3)
            clear_screen
            echo "📡 Live Log Streaming (Press Ctrl+C to stop)"
            echo "═══════════════════════════════════════════════════════════════════════════════"
            echo ""
            trap 'echo ""; echo "⏹️  Live stream stopped."; sleep 2; return' INT
            docker logs -f --tail 10 "$CONTAINER_NAME" 2>&1
            ;;
        0)
            return
            ;;
        *)
            echo "❌ Invalid choice"
            sleep 2
            ;;
    esac
    
    trap - INT # Reset trap
}

kiosk_save_logs() {
    clear_screen
    echo "💾 Save Logs to File"
    echo ""
    
    local timestamp
    timestamp=$(date +'%Y%m%d-%H%M%S')
    local default_filename="rancher_logs_${timestamp}.txt"
    
    echo "Save options:"
    echo "  1) Save recent logs (last 100 lines)"
    echo "  2) Save all logs"
    echo "  3) Save problem events only"
    echo "  4) Save debug information"
    echo "  0) Cancel"
    echo ""
    echo -n "Enter your choice [0-4]: "
    
    local choice
    read -r choice
    
    if [[ "$choice" == "0" ]]; then
        return
    fi
    
    echo ""
    echo -n "Enter filename [$default_filename]: "
    local filename
    read -r filename
    filename="${filename:-$default_filename}"
    
    echo ""
    echo "💾 Saving logs to: $filename"
    
    case "$choice" in
        1)
            {
                echo "# Rancher Container Logs - Recent (Last 100 lines)"
                echo "# Generated: $(date)"
                echo "# Container: $CONTAINER_NAME"
                echo "# ═══════════════════════════════════════════════════════════════════════════════"
                echo ""
                docker logs --tail 100 --timestamps "$CONTAINER_NAME" 2>&1
            } > "$filename"
            ;;
        2)
            {
                echo "# Rancher Container Logs - Complete"
                echo "# Generated: $(date)"
                echo "# Container: $CONTAINER_NAME"
                echo "# ═══════════════════════════════════════════════════════════════════════════════"
                echo ""
                docker logs --timestamps "$CONTAINER_NAME" 2>&1
            } > "$filename"
            ;;
        3)
            {
                echo "# Rancher Container Logs - Problem Events Only"
                echo "# Generated: $(date)"
                echo "# Container: $CONTAINER_NAME"
                echo "# ═══════════════════════════════════════════════════════════════════════════════"
                echo ""
                docker logs --timestamps "$CONTAINER_NAME" 2>&1 | grep -iE "(error|warn|fail|exception|panic|fatal)"
            } > "$filename"
            ;;
        4)
            {
                echo "# Rancher Container Debug Information"
                echo "# Generated: $(date)"
                echo "# Container: $CONTAINER_NAME"
                echo "# ═══════════════════════════════════════════════════════════════════════════════"
                echo ""
                echo "## Container Inspection:"
                docker inspect "$CONTAINER_NAME" 2>/dev/null
                echo ""
                echo "## Container Logs:"
                docker logs --timestamps "$CONTAINER_NAME" 2>&1
            } > "$filename"
            ;;
        *)
            echo "❌ Invalid choice"
            sleep 2
            return
            ;;
    esac
    
    if [[ -f "$filename" ]]; then
        local file_size
        file_size=$(du -h "$filename" | cut -f1)
        echo "✅ Logs saved successfully!"
        echo "   File: $filename"
        echo "   Size: $file_size"
    else
        echo "❌ Failed to save logs"
    fi
    
    kiosk_pause
}

kiosk_settings_menu() {
    while true; do
        clear_screen
        echo "⚙️  Settings Configuration"
        echo ""
        echo "Current Settings:"
        echo "  1) Data Directory: $DATA_DIR"
        echo "  2) Log File: $LOG_FILE"
        echo "  3) Rancher Version: ${RANCHER_VERSION:-(auto-detect latest)}"
        echo "  4) ACME Domain: ${ACME_DOMAIN:-(none)}"
        echo "  5) Volume Value: ${VOLUME_VALUE:-(default)}"
        echo "  6) Dry Run Mode: $DRY_RUN"
        echo ""
        echo "  7) Reset to defaults"
        echo "  0) Back to main menu"
        echo ""
        echo -n "Enter setting to change [0-7]: "
        
        local choice
        read -r choice
        
        case "$choice" in
            1)
                echo ""
                echo -n "Enter new data directory [$DATA_DIR]: "
                local new_dir
                read -r new_dir
                if [[ -n "$new_dir" ]]; then
                    DATA_DIR="$new_dir"
                    echo "✅ Data directory updated to: $DATA_DIR"
                    sleep 2
                fi
                ;;
            2)
                echo ""
                echo -n "Enter new log file path [$LOG_FILE]: "
                local new_log
                read -r new_log
                if [[ -n "$new_log" ]]; then
                    LOG_FILE="$new_log"
                    echo "✅ Log file updated to: $LOG_FILE"
                    sleep 2
                fi
                ;;
            3)
                echo ""
                echo -n "Enter Rancher version (empty for auto-detect): "
                local new_version
                read -r new_version
                RANCHER_VERSION="$new_version"
                echo "✅ Rancher version updated to: ${RANCHER_VERSION:-(auto-detect)}"
                sleep 2
                ;;
            4)
                echo ""
                echo -n "Enter ACME domain (empty to disable): "
                local new_domain
                read -r new_domain
                ACME_DOMAIN="$new_domain"
                echo "✅ ACME domain updated to: ${ACME_DOMAIN:-(disabled)}"
                sleep 2
                ;;
            5)
                echo ""
                echo -n "Enter volume value (empty for default): "
                local new_volume
                read -r new_volume
                VOLUME_VALUE="$new_volume"
                echo "✅ Volume value updated to: ${VOLUME_VALUE:-(default)}"
                sleep 2
                ;;
            6)
                if [[ "$DRY_RUN" == "true" ]]; then
                    DRY_RUN="false"
                    echo "✅ Dry run mode disabled"
                else
                    DRY_RUN="true"
                    echo "✅ Dry run mode enabled"
                fi
                sleep 2
                ;;
            7)
                DATA_DIR="$(pwd)/rancher-data"
                LOG_FILE="rancher-lifecycle.log"
                RANCHER_VERSION=""
                ACME_DOMAIN=""
                VOLUME_VALUE=""
                DRY_RUN="false"
                echo "✅ Settings reset to defaults"
                sleep 2
                ;;
            0)
                return
                ;;
            *)
                echo "❌ Invalid choice"
                sleep 2
                ;;
        esac
    done
}

kiosk_show_completion_info() {
    if [[ "$DRY_RUN" == "false" ]]; then
        echo ""
        echo "🎉 Operation completed successfully!"
        
        # Try to get the password
        local password=""
        if [[ -f "initial-passwd" ]]; then
            password=$(grep "Bootstrap Password:" initial-passwd 2>/dev/null | cut -d' ' -f3- | tr -d '\r\n' || echo "")
        fi
        
        if [[ -z "$password" ]] && container_exists; then
            password=$(docker logs "$CONTAINER_NAME" 2>&1 | grep "Bootstrap Password:" | tail -1 | cut -d' ' -f3- | tr -d '\r\n' 2>/dev/null || echo "")
        fi
        
        if [[ -n "$password" ]]; then
            echo "🔑 Bootstrap password: $password"
        fi
        
        echo "🌐 Access Rancher UI at: https://$(hostname -I | awk '{print $1}') or https://your-domain"
        echo ""
    fi
}

kiosk_pause() {
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

validate_args() {
    # Check if an action was specified (skip for kiosk mode)
    if [[ "$KIOSK_MODE" != "true" ]] && [[ -z "$ACTION" ]]; then
        error_exit "No action specified. Use --help for usage information."
    fi
    
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
            --kiosk) KIOSK_MODE="true"; shift ;;
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
    
    # Handle kiosk mode early
    if [[ "$KIOSK_MODE" == "true" ]]; then
        validate_args
        return
    fi
    
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
        error_exit "Cannot connect to Docker daemon. If 1st time Docker install log out/in and run again."
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
            error_exit "Container already exists. --install is not allowed. Use --kiosk or --help for more info"
        fi
    fi

    # Check if running as root (not recommended)
    [[ $EUID -eq 0 ]] && log "⚠️  Warning: Running as root is not recommended"

    # Install non-Docker dependencies first
    for tool in jq curl; do
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

    # Handle Docker installation separately
    if ! command -v docker &>/dev/null; then
        log "📦 Installing Docker..."
        if command -v apt-get &>/dev/null; then
            # Remove any conflicting packages first
            run_or_echo "sudo apt-get remove -y containerd containerd.io docker docker-engine docker.io runc || true"
            run_or_echo "sudo apt-get autoremove -y || true"
            
            # Check if Docker CE repository is available
            if apt-cache search docker-ce | grep -q "docker-ce"; then
                log "📦 Installing Docker CE from official repository..."
                run_or_echo "sudo apt-get update"
                run_or_echo "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
            else
                log "📦 Docker CE repository not found, setting up official Docker repository..."
                # Install prerequisites
                run_or_echo "sudo apt-get update"
                run_or_echo "sudo apt-get install -y ca-certificates curl"
                
                # Add Docker's official GPG key
                run_or_echo "sudo install -m 0755 -d /etc/apt/keyrings"
                run_or_echo "sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc"
                run_or_echo "sudo chmod a+r /etc/apt/keyrings/docker.asc"
                
                # Add Docker repository
                run_or_echo 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null'
                
                # Update package index and install Docker
                run_or_echo "sudo apt-get update"
                run_or_echo "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
            fi
        elif command -v yum &>/dev/null; then
            run_or_echo "sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
        elif command -v dnf &>/dev/null; then
            run_or_echo "sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
        else
            error_exit "Package manager not found. Please install Docker manually."
        fi
    else
        log "✅ Docker is already installed."
    fi

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
        sleep 80

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
                    
                    log "📦 Creating compressed backup, this could take a minute..."
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

🎛️ Interactive kiosk mode:
  ./$(basename "$0") --kiosk

EOF
    exit 0
}

main() {
    # Parse arguments first
    parse_args "$@"
    
    # Handle kiosk mode
    if [[ "$KIOSK_MODE" == "true" ]]; then
        kiosk_menu
        exit 0
    fi
    
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
                log "✅ Run ./provision.sh --kiosk to monitor and manage your Rancher configuration"
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

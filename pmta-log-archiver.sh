#!/bin/bash

# =============================================================================
# PowerMTA Log Archiver to Cloudflare R2
# =============================================================================
# Self-configuring script that:
# - Installs required dependencies (rclone, jq)
# - Creates configuration on first run
# - Keeps last 7 days of logs locally
# - Archives older files to Cloudflare R2
# =============================================================================

set -euo pipefail

# Script locations
SCRIPT_NAME="pmta-log-archiver"
CONFIG_DIR="/etc/${SCRIPT_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"

# Default values (overridden by config file)
LOG_DIR="/var/log/pmta-accounting"
LOG_PATTERN="oempro-*.csv"
R2_BUCKET=""
R2_PATH="pmta-logs"
R2_ACCOUNT_ID=""
R2_ACCESS_KEY_ID=""
R2_SECRET_ACCESS_KEY=""
RETENTION_DAYS=7

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO: $1"
}

log_error() {
    log "ERROR: $1"
}

log_success() {
    log "SUCCESS: $1"
}

error_exit() {
    log_error "$1"
    exit 1
}

# =============================================================================
# Dependency Management
# =============================================================================

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

install_package() {
    local package="$1"
    local pkg_manager=$(detect_package_manager)
    
    log_info "Installing $package using $pkg_manager..."
    
    case "$pkg_manager" in
        apt)
            apt-get update -qq
            apt-get install -y -qq "$package"
            ;;
        yum)
            yum install -y -q "$package"
            ;;
        dnf)
            dnf install -y -q "$package"
            ;;
        zypper)
            zypper install -y -q "$package"
            ;;
        pacman)
            pacman -S --noconfirm "$package"
            ;;
        *)
            return 1
            ;;
    esac
}

install_rclone() {
    log_info "Installing rclone..."
    
    # Try package manager first
    if install_package rclone 2>/dev/null; then
        log_success "rclone installed via package manager"
        return 0
    fi
    
    # Fallback to official install script
    log_info "Falling back to rclone official installer..."
    
    if command -v curl &>/dev/null; then
        curl -sL https://rclone.org/install.sh | bash
    elif command -v wget &>/dev/null; then
        wget -qO- https://rclone.org/install.sh | bash
    else
        error_exit "Neither curl nor wget available. Cannot install rclone."
    fi
    
    if command -v rclone &>/dev/null; then
        log_success "rclone installed successfully"
        return 0
    else
        error_exit "Failed to install rclone"
    fi
}

install_jq() {
    log_info "Installing jq..."
    
    if install_package jq 2>/dev/null; then
        log_success "jq installed via package manager"
        return 0
    fi
    
    # Fallback: download binary
    log_info "Falling back to direct binary download..."
    
    local arch=$(uname -m)
    local jq_url=""
    
    case "$arch" in
        x86_64)
            jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
            ;;
        aarch64)
            jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-arm64"
            ;;
        *)
            error_exit "Unsupported architecture: $arch"
            ;;
    esac
    
    if command -v curl &>/dev/null; then
        curl -sL "$jq_url" -o /usr/local/bin/jq
    elif command -v wget &>/dev/null; then
        wget -q "$jq_url" -O /usr/local/bin/jq
    else
        error_exit "Neither curl nor wget available. Cannot install jq."
    fi
    
    chmod +x /usr/local/bin/jq
    
    if command -v jq &>/dev/null; then
        log_success "jq installed successfully"
        return 0
    else
        error_exit "Failed to install jq"
    fi
}

check_and_install_dependencies() {
    log_info "Checking dependencies..."
    
    # Check for root privileges (needed for installation)
    local need_install=false
    
    if ! command -v rclone &>/dev/null; then
        need_install=true
    fi
    
    if ! command -v jq &>/dev/null; then
        need_install=true
    fi
    
    if [ "$need_install" = true ] && [ "$(id -u)" -ne 0 ]; then
        error_exit "Root privileges required to install dependencies. Run with sudo."
    fi
    
    # Check/install rclone
    if ! command -v rclone &>/dev/null; then
        log_info "rclone not found"
        install_rclone
    else
        log_info "rclone found: $(rclone version | head -1)"
    fi
    
    # Check/install jq
    if ! command -v jq &>/dev/null; then
        log_info "jq not found"
        install_jq
    else
        log_info "jq found: $(jq --version)"
    fi
    
    # Check for curl or wget (needed for uploads)
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        log_info "Installing curl..."
        install_package curl || install_package wget || error_exit "Cannot install curl or wget"
    fi
    
    log_success "All dependencies satisfied"
}

# =============================================================================
# Configuration Management
# =============================================================================

create_config_dir() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        chmod 700 "$CONFIG_DIR"
        log_info "Created config directory: $CONFIG_DIR"
    fi
}

config_exists() {
    [ -f "$CONFIG_FILE" ]
}

load_config() {
    if config_exists; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_info "Loaded configuration from $CONFIG_FILE"
        return 0
    fi
    return 1
}

validate_config() {
    local errors=()
    
    [ -z "$R2_BUCKET" ] && errors+=("R2_BUCKET is not set")
    [ -z "$R2_ACCOUNT_ID" ] && errors+=("R2_ACCOUNT_ID is not set")
    [ -z "$R2_ACCESS_KEY_ID" ] && errors+=("R2_ACCESS_KEY_ID is not set")
    [ -z "$R2_SECRET_ACCESS_KEY" ] && errors+=("R2_SECRET_ACCESS_KEY is not set")
    [ -z "$LOG_DIR" ] && errors+=("LOG_DIR is not set")
    
    if [ ! -d "$LOG_DIR" ]; then
        errors+=("LOG_DIR does not exist: $LOG_DIR")
    fi
    
    if [ ${#errors[@]} -gt 0 ]; then
        log_error "Configuration validation failed:"
        for error in "${errors[@]}"; do
            log_error "  - $error"
        done
        return 1
    fi
    
    log_success "Configuration validated"
    return 0
}

prompt_for_config() {
    echo ""
    echo "=============================================="
    echo "  PowerMTA Log Archiver - Initial Setup"
    echo "=============================================="
    echo ""
    echo "This wizard will help you configure the archiver."
    echo "You'll need your Cloudflare R2 credentials ready."
    echo ""
    echo "To get R2 credentials:"
    echo "  1. Go to Cloudflare Dashboard > R2"
    echo "  2. Click 'Manage R2 API Tokens'"
    echo "  3. Create a new API token with read/write access"
    echo ""
    
    # Log directory
    read -rp "PowerMTA log directory [$LOG_DIR]: " input
    LOG_DIR="${input:-$LOG_DIR}"
    
    # Validate log directory
    while [ ! -d "$LOG_DIR" ]; do
        echo "Directory does not exist: $LOG_DIR"
        read -rp "PowerMTA log directory: " LOG_DIR
    done
    
    # Log file pattern
    read -rp "Log file pattern [$LOG_PATTERN]: " input
    LOG_PATTERN="${input:-$LOG_PATTERN}"
    
    # Retention days
    read -rp "Days to keep locally [$RETENTION_DAYS]: " input
    RETENTION_DAYS="${input:-$RETENTION_DAYS}"
    
    echo ""
    echo "--- Cloudflare R2 Configuration ---"
    echo ""
    
    # R2 Account ID
    while [ -z "$R2_ACCOUNT_ID" ]; do
        read -rp "R2 Account ID: " R2_ACCOUNT_ID
    done
    
    # R2 Bucket
    while [ -z "$R2_BUCKET" ]; do
        read -rp "R2 Bucket name: " R2_BUCKET
    done
    
    # R2 Path prefix
    read -rp "R2 path prefix [$R2_PATH]: " input
    R2_PATH="${input:-$R2_PATH}"
    
    # R2 Access Key ID
    while [ -z "$R2_ACCESS_KEY_ID" ]; do
        read -rp "R2 Access Key ID: " R2_ACCESS_KEY_ID
    done
    
    # R2 Secret Access Key
    while [ -z "$R2_SECRET_ACCESS_KEY" ]; do
        read -rsp "R2 Secret Access Key: " R2_SECRET_ACCESS_KEY
        echo ""
    done
    
    echo ""
}

save_config() {
    create_config_dir
    
    cat > "$CONFIG_FILE" << EOF
# PowerMTA Log Archiver Configuration
# Generated: $(date)

# Local Settings
LOG_DIR="$LOG_DIR"
LOG_PATTERN="$LOG_PATTERN"
RETENTION_DAYS=$RETENTION_DAYS

# Cloudflare R2 Settings
R2_ACCOUNT_ID="$R2_ACCOUNT_ID"
R2_BUCKET="$R2_BUCKET"
R2_PATH="$R2_PATH"
R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
EOF
    
    chmod 600 "$CONFIG_FILE"
    log_success "Configuration saved to $CONFIG_FILE"
}

test_r2_connection() {
    log_info "Testing R2 connection..."

    if rclone lsd ":s3:${R2_BUCKET}" $(get_r2_flags) &>/dev/null; then
        log_success "R2 connection successful"
        return 0
    else
        # Try to create bucket if it doesn't exist
        log_info "Bucket may not exist, attempting to verify..."
        if rclone mkdir ":s3:${R2_BUCKET}" $(get_r2_flags) 2>/dev/null; then
            log_success "R2 connection successful (bucket created/verified)"
            return 0
        fi
        log_error "R2 connection failed. Please check your credentials."
        return 1
    fi
}

setup_config() {
    prompt_for_config
    
    echo ""
    echo "--- Configuration Summary ---"
    echo "Log directory:    $LOG_DIR"
    echo "File pattern:     $LOG_PATTERN"
    echo "Retention:        $RETENTION_DAYS days"
    echo "R2 Account:       $R2_ACCOUNT_ID"
    echo "R2 Bucket:        $R2_BUCKET"
    echo "R2 Path:          $R2_PATH"
    echo ""
    
    read -rp "Save this configuration? [Y/n]: " confirm
    if [[ "${confirm,,}" =~ ^(y|yes|)$ ]]; then
        save_config
        
        if test_r2_connection; then
            echo ""
            log_success "Setup complete!"
            echo ""
            echo "You can now run the archiver:"
            echo "  $0 --run"
            echo ""
            echo "To set up automatic daily archival, run:"
            echo "  $0 --install-cron"
            echo ""
        else
            echo ""
            echo "Configuration saved but R2 connection failed."
            echo "Please edit $CONFIG_FILE and fix credentials."
            echo ""
            exit 1
        fi
    else
        echo "Configuration not saved."
        exit 0
    fi
}

# =============================================================================
# Cron Management
# =============================================================================

install_cron() {
    local cron_file="/etc/cron.d/${SCRIPT_NAME}"
    local script_path=$(realpath "$0")
    
    cat > "$cron_file" << EOF
# PowerMTA Log Archiver - Archive old logs to Cloudflare R2
# Runs daily at 2:00 AM

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 2 * * * root $script_path --run >> $LOG_FILE 2>&1
EOF
    
    chmod 644 "$cron_file"
    log_success "Cron job installed: $cron_file"
    echo "The archiver will run daily at 2:00 AM"
}

remove_cron() {
    local cron_file="/etc/cron.d/${SCRIPT_NAME}"
    
    if [ -f "$cron_file" ]; then
        rm -f "$cron_file"
        log_success "Cron job removed"
    else
        log_info "No cron job found"
    fi
}

# =============================================================================
# Archive Functions
# =============================================================================

get_cutoff_date() {
    date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d'
}

extract_date_from_filename() {
    local filename="$1"
    echo "$filename" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1
}

# Returns the rclone S3 flags for R2 connection
# Usage: rclone <command> ":s3:${R2_BUCKET}/path" $(get_r2_flags)
get_r2_flags() {
    echo "--s3-provider Cloudflare --s3-access-key-id ${R2_ACCESS_KEY_ID} --s3-secret-access-key ${R2_SECRET_ACCESS_KEY} --s3-endpoint https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
}

upload_to_r2() {
    local file_path="$1"
    local filename=$(basename "$file_path")
    local file_date=$(extract_date_from_filename "$filename")
    local year_month=$(echo "$file_date" | cut -d'-' -f1,2)
    local dest_path="${R2_PATH}/${year_month}/${filename}"

    log_info "Uploading: $filename -> r2://${R2_BUCKET}/${dest_path}"

    if rclone copyto "$file_path" ":s3:${R2_BUCKET}/${dest_path}" \
        $(get_r2_flags) \
        --checksum \
        --retries 3 \
        --low-level-retries 10 \
        2>&1 | tee -a "$LOG_FILE"; then
        return 0
    else
        return 1
    fi
}

verify_upload() {
    local file_path="$1"
    local filename=$(basename "$file_path")
    local file_date=$(extract_date_from_filename "$filename")
    local year_month=$(echo "$file_date" | cut -d'-' -f1,2)
    local dest_path="${R2_PATH}/${year_month}/${filename}"
    local local_size=$(stat -c%s "$file_path")

    local remote_info
    remote_info=$(rclone size ":s3:${R2_BUCKET}/${dest_path}" $(get_r2_flags) --json 2>/dev/null) || {
        log_error "Could not get remote file info"
        return 1
    }

    local remote_size
    remote_size=$(echo "$remote_info" | jq -r '.bytes')

    if [ "$local_size" -eq "$remote_size" ]; then
        log_info "Verified: sizes match (${local_size} bytes)"
        return 0
    else
        log_error "Size mismatch: local=$local_size, remote=$remote_size"
        return 1
    fi
}

run_archive() {
    log_info "=========================================="
    log_info "Starting PowerMTA log archival process"
    log_info "=========================================="
    
    # Load and validate config
    load_config || error_exit "No configuration found. Run: $0 --setup"
    validate_config || error_exit "Invalid configuration"
    
    local cutoff_date=$(get_cutoff_date)
    log_info "Cutoff date: $cutoff_date"
    log_info "Files older than $cutoff_date will be archived"
    log_info "Log directory: $LOG_DIR"
    log_info "File pattern: $LOG_PATTERN"
    
    local archived_count=0
    local failed_count=0
    local kept_count=0
    local total_bytes=0
    
    # Process files
    shopt -s nullglob
    local files=("$LOG_DIR"/$LOG_PATTERN)
    shopt -u nullglob
    
    if [ ${#files[@]} -eq 0 ]; then
        log_info "No files matching pattern found"
        return 0
    fi
    
    log_info "Found ${#files[@]} files to process"
    
    for file_path in "${files[@]}"; do
        [ -f "$file_path" ] || continue
        
        local filename=$(basename "$file_path")
        local file_date=$(extract_date_from_filename "$filename")
        
        if [ -z "$file_date" ]; then
            log_info "SKIP: Cannot extract date from $filename"
            continue
        fi
        
        # Compare dates
        if [[ "$file_date" < "$cutoff_date" ]]; then
            local file_size=$(stat -c%s "$file_path")
            local file_size_mb=$(echo "scale=2; $file_size / 1048576" | bc)
            
            log_info "ARCHIVE: $filename (${file_size_mb}MB, date: $file_date)"
            
            if upload_to_r2 "$file_path"; then
                if verify_upload "$file_path"; then
                    rm -f "$file_path"
                    log_success "COMPLETED: $filename archived and removed"
                    ((archived_count++))
                    total_bytes=$((total_bytes + file_size))
                else
                    log_error "FAILED: Verification failed for $filename"
                    ((failed_count++))
                fi
            else
                log_error "FAILED: Upload failed for $filename"
                ((failed_count++))
            fi
        else
            log_info "KEEP: $filename (date: $file_date)"
            ((kept_count++))
        fi
    done
    
    local total_mb=$(echo "scale=2; $total_bytes / 1048576" | bc)
    
    log_info "=========================================="
    log_info "Archival Summary"
    log_info "=========================================="
    log_info "  Archived:     $archived_count files (${total_mb}MB)"
    log_info "  Failed:       $failed_count files"
    log_info "  Kept locally: $kept_count files"
    log_info "=========================================="
    
    [ "$failed_count" -eq 0 ] || return 1
    return 0
}

# =============================================================================
# Utility Commands
# =============================================================================

show_status() {
    echo ""
    echo "=== PowerMTA Log Archiver Status ==="
    echo ""
    
    # Config status
    if config_exists; then
        echo "Configuration: $CONFIG_FILE"
        load_config
        echo "  Log directory:  $LOG_DIR"
        echo "  Retention:      $RETENTION_DAYS days"
        echo "  R2 Bucket:      $R2_BUCKET"
        echo "  R2 Path:        $R2_PATH"
    else
        echo "Configuration: Not configured"
        echo "  Run: $0 --setup"
    fi
    
    echo ""
    
    # Dependencies
    echo "Dependencies:"
    if command -v rclone &>/dev/null; then
        echo "  rclone: $(rclone version | head -1)"
    else
        echo "  rclone: Not installed"
    fi
    
    if command -v jq &>/dev/null; then
        echo "  jq: $(jq --version)"
    else
        echo "  jq: Not installed"
    fi
    
    echo ""
    
    # Cron status
    local cron_file="/etc/cron.d/${SCRIPT_NAME}"
    if [ -f "$cron_file" ]; then
        echo "Cron job: Installed"
        grep -v '^#' "$cron_file" | grep -v '^$' | head -1
    else
        echo "Cron job: Not installed"
        echo "  Run: $0 --install-cron"
    fi
    
    echo ""
    
    # Local files
    if [ -d "$LOG_DIR" ]; then
        echo "Local log files:"
        local count=$(find "$LOG_DIR" -name "$LOG_PATTERN" 2>/dev/null | wc -l)
        local size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)
        echo "  Count: $count files"
        echo "  Size:  $size"
    fi
    
    echo ""
}

list_remote() {
    load_config || error_exit "No configuration found"

    echo ""
    echo "=== R2 Archived Files ==="
    echo ""

    rclone ls ":s3:${R2_BUCKET}/${R2_PATH}/" $(get_r2_flags) --human-readable 2>/dev/null || {
        echo "No files found or connection error"
    }

    echo ""
    echo "Total size:"
    rclone size ":s3:${R2_BUCKET}/${R2_PATH}/" $(get_r2_flags) --human-readable 2>/dev/null || true
    echo ""
}

show_help() {
    cat << EOF

PowerMTA Log Archiver - Archive logs to Cloudflare R2

Usage: $0 [command]

Commands:
  --setup           Run interactive setup wizard
  --run             Run the archival process
  --status          Show current status
  --list-remote     List files in R2 bucket
  --test            Test R2 connection
  --install-cron    Install daily cron job
  --remove-cron     Remove cron job
  --help            Show this help message

Configuration: $CONFIG_FILE
Log file:      $LOG_FILE

Examples:
  $0 --setup        # First-time setup
  $0 --run          # Archive old logs now
  $0 --status       # Check configuration and status

EOF
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    # Create log file directory if needed
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    
    # Parse command line
    local command="${1:---help}"
    
    case "$command" in
        --setup|-s)
            check_and_install_dependencies
            setup_config
            ;;
        --run|-r)
            check_and_install_dependencies
            run_archive
            ;;
        --status)
            show_status
            ;;
        --list-remote|--list)
            list_remote
            ;;
        --test|-t)
            load_config || error_exit "No configuration found"
            test_r2_connection
            ;;
        --install-cron)
            install_cron
            ;;
        --remove-cron)
            remove_cron
            ;;
        --help|-h|*)
            show_help
            ;;
    esac
}

main "$@"
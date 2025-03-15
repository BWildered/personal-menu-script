#!/bin/bash

#---------------------------------------------------------------
# sysb - System Backup Script
# A script to backup Linux system directories with rsync
# Features:
# - Interactive menu system with arrow key navigation
# - Configuration persistence via .ini file
# - Incremental backups (only syncs changes with hard linking)
# - Maximum compression with XZ
# - Error handling and reporting with recovery options
# - Comprehensive logging with rotation
# - Resource usage monitoring
# - Backup verification
#---------------------------------------------------------------

# Define paths for configuration and log files
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INI_FILE="${SCRIPT_DIR}/sysb.ini"
LOG_FILE="${SCRIPT_DIR}/sysb.log"
ERROR_STATE_FILE="${SCRIPT_DIR}/sysb.error"

# Initialize logging with rotation
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
    
    # Rotate log if it's too large (>5MB)
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 5242880 ]; then
        local backup_log="${LOG_FILE}.$(date '+%Y%m%d_%H%M%S')"
        mv "$LOG_FILE" "$backup_log"
        touch "$LOG_FILE"
        log "Log file rotated to $backup_log"
    fi
}

error() {
    log "ERROR: $1"
    echo "$1" >> "$ERROR_STATE_FILE"
}

# Create files if they don't exist
if [ ! -d "$(dirname "$LOG_FILE")" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
fi

if [ ! -d "$(dirname "$INI_FILE")" ]; then
    mkdir -p "$(dirname "$INI_FILE")"
fi

if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

if [ ! -f "$INI_FILE" ]; then
    touch "$INI_FILE"
fi

if [ ! -f "$ERROR_STATE_FILE" ]; then
    touch "$ERROR_STATE_FILE"
fi

# Function to read values from INI file
read_ini() {
    local key="$1"
    local default="$2"
    if [ -f "$INI_FILE" ]; then
        local value=$(grep "^$key=" "$INI_FILE" | cut -d'=' -f2-)
        if [ -z "$value" ]; then
            echo "$default"
        else
            echo "$value"
        fi
    else
        echo "$default"
    fi
}

# Function to write values to INI file
write_ini() {
    local key="$1"
    local value="$2"
    if [ ! -f "$INI_FILE" ]; then
        touch "$INI_FILE"
    fi
    
    if grep -q "^$key=" "$INI_FILE"; then
        # Key exists, update it
        sed -i "s|^$key=.*|$key=$value|" "$INI_FILE"
    else
        # Key doesn't exist, append it
        echo "$key=$value" >> "$INI_FILE"
    fi
}

# Function to add directory to history
add_directory_to_history() {
    local type="$1"  # source or destination
    local dir="$2"
    local history_key="${type}_history"
    local history=$(read_ini "$history_key" "")
    
    # Check if directory is already in history
    if [[ "$history" != *"$dir"* ]]; then
        # Add directory to history
        if [ -z "$history" ]; then
            write_ini "$history_key" "$dir"
        else
            write_ini "$history_key" "$history:$dir"
        fi
    fi
}

# Check for errors from previous runs
check_errors() {
    if [ -f "$ERROR_STATE_FILE" ] && [ -s "$ERROR_STATE_FILE" ]; then
        echo "Errors from previous run detected:"
        cat "$ERROR_STATE_FILE"
        return 1
    fi
    return 0
}

# Function to clear error states
clear_errors() {
    if [ -f "$ERROR_STATE_FILE" ]; then
        rm -f "$ERROR_STATE_FILE"
        touch "$ERROR_STATE_FILE"
        log "Error states cleared"
    fi
}

# Check if rsync is installed
check_dependencies() {
    if ! command -v rsync &> /dev/null; then
        error "rsync could not be found. Please install it."
        return 1
    fi
    if ! command -v tar &> /dev/null; then
        error "tar could not be found. Please install it."
        return 1
    fi
    if ! command -v xz &> /dev/null; then
        error "xz could not be found. Please install it."
        return 1
    fi
    return 0
}

# Function to check directory permissions
check_permissions() {
    local dir="$1"
    local type="$2"  # "source" or "destination"
    
    if [ ! -d "$dir" ]; then
        error "Directory $dir does not exist"
        return 1
    fi
    
    if [ "$type" = "source" ]; then
        if [ ! -r "$dir" ]; then
            error "No read permission for $dir"
            return 1
        fi
    elif [ "$type" = "destination" ]; then
        if [ ! -w "$dir" ]; then
            error "No write permission for $dir"
            return 1
        fi
    fi
    
    return 0
}

# Function to monitor system resources
monitor_resources() {
    log "System resource usage:"
    log "CPU: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}')% used"
    log "Memory: $(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2}')"
    log "Disk space: $(df -h "$1" | awk 'NR==2{print $5}') used on backup destination"
}

# Function to verify backup integrity
verify_backup() {
    local backup_file="$1"
    local test_dir="/tmp/sysb_verify_$(date +%s)"
    
    log "Verifying backup integrity: $backup_file"
    mkdir -p "$test_dir"
    
    # Try to list the archive contents
    tar -tJf "$backup_file" > /dev/null 2>&1
    local tar_status=$?
    if [ $tar_status -ne 0 ]; then
        error "Backup verification failed: Archive is corrupted"
        rm -rf "$test_dir"
        return 1
    fi
    
    # Try to extract a few small files to verify
    tar -xJf "$backup_file" -C "$test_dir" "etc/hostname" "etc/os-release" 2>/dev/null
    local extract_status=$?
    if [ $extract_status -ne 0 ]; then
        error "Backup verification failed: Could not extract test files"
        rm -rf "$test_dir"
        return 1
    fi
    
    # Clean up
    rm -rf "$test_dir"
    log "Backup verification passed: $backup_file"
    return 0
}

# Function to perform backup operation
perform_backup() {
    local source_dir=$(read_ini "source_dir" "")
    local dest_dir=$(read_ini "backup_dir" "")
    local exclude_dirs=$(read_ini "exclude_dirs" "")
    local compression_level=$(read_ini "compression_level" "9")  # Default to maximum
    
    # Check if source and destination are set
    if [ -z "$source_dir" ] || [ -z "$dest_dir" ]; then
        error "Source or destination directory not configured"
        return 1
    fi
    
    # Check permissions
    check_permissions "$source_dir" "source" || return 1
    check_permissions "$dest_dir" "destination" || return 1
    
    log "Starting backup from $source_dir to $dest_dir"

    # Create exclude parameter array
    local exclude_params=()
    if [ -n "$exclude_dirs" ]; then
        # Save the original IFS value
        local OLDIFS="$IFS"
        IFS=':'
        read -ra ADDR <<< "$exclude_dirs"
        # Restore original IFS
        IFS="$OLDIFS"
        
        for i in "${ADDR[@]}"; do
            exclude_params+=(--exclude="$i")
        done
    fi
    
    # Add standard system excludes
    exclude_params+=(--exclude=/proc --exclude=/tmp --exclude=/sys --exclude=/dev --exclude=/run --exclude=/mnt --exclude=/media --exclude=/lost+found)
    
    # Create timestamp for archive naming
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local archive_name="system_backup_$timestamp.tar.xz"
    local temp_dir="$dest_dir/temp_backup_$timestamp"
    local last_backup=$(read_ini "last_backup_dir" "")
    
    # First sync with rsync
    log "Running rsync to sync files..."
    mkdir -p "$temp_dir"
    
    # Use incremental backup if previous backup exists
    local rsync_params="-aAXv --info=progress2"
    if [ -n "$last_backup" ] && [ -d "$last_backup" ]; then
        log "Using incremental backup from $last_backup"
        rsync_params="$rsync_params --link-dest=$last_backup"
    fi
    
    # Run rsync with progress
    rsync $rsync_params "${exclude_params[@]}" "$source_dir/" "$temp_dir/" 2>&1 | tee -a "$LOG_FILE"
    
    local rsync_status=${PIPESTATUS[0]}
    if [ $rsync_status -ne 0 ]; then
        error "rsync failed with error code $rsync_status"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Now create compressed archive with maximum compression
    log "Creating compressed archive $archive_name (with maximum compression)..."
    XZ_OPT="-$compression_level" tar -cJf "$dest_dir/$archive_name" -C "$temp_dir" . 2>&1 | tee -a "$LOG_FILE"
    
    local tar_status=${PIPESTATUS[0]}
    if [ $tar_status -ne 0 ]; then
        error "tar compression failed with error code $tar_status"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Store reference to this backup for incremental backup support
    write_ini "last_backup_dir" "$temp_dir"
    write_ini "last_backup" "$dest_dir/$archive_name"
    
    # Verify backup integrity
    if ! verify_backup "$dest_dir/$archive_name"; then
        error "Backup verification failed for $dest_dir/$archive_name"
        # Keep temp directory for troubleshooting
        log "Temporary files preserved for troubleshooting at $temp_dir"
        return 1
    fi
    
    # Show backup statistics
    local backup_size=$(du -sh "$dest_dir/$archive_name" | cut -f1)
    log "Backup statistics:"
    log "- Size: $backup_size"
    log "- Location: $dest_dir/$archive_name"
    
    # Clean up temp directory if everything was successful
    if [ "$(read_ini "keep_temp" "0")" -eq 0 ]; then
        rm -rf "$temp_dir"
        log "Temporary files removed"
    else
        log "Temporary files preserved at $temp_dir"
    fi
    
    # Monitor resource usage after backup
    monitor_resources "$dest_dir"
    
    log "Backup completed successfully: $dest_dir/$archive_name"
    return 0
}

# Function to perform restore operation
perform_restore() {
    local backup_file=$(read_ini "last_backup" "")
    local restore_dir=$(read_ini "restore_dir" "/")
    
    # Prompt for backup file if not set
    if [ -z "$backup_file" ]; then
        echo "No backup file selected. Please select a backup file."
        return 1
    fi
    
    # Check if backup file exists
    if [ ! -f "$backup_file" ]; then
        error "Backup file $backup_file does not exist"
        return 1
    fi
    
    # Check permissions
    check_permissions "$restore_dir" "destination" || return 1
    
    log "Starting restore from $backup_file to $restore_dir"
    
    # Create temp directory for extraction
    local temp_dir="/tmp/sysb_restore_$(date +%s)"
    mkdir -p "$temp_dir"
    
    # Extract archive
    log "Extracting backup archive..."
    tar -xJf "$backup_file" -C "$temp_dir" 2>&1 | tee -a "$LOG_FILE"
    
    local tar_extract_status=$?
    if [ $tar_extract_status -ne 0 ]; then
        error "Failed to extract backup archive"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Sync files to restore location
    log "Syncing files to restore location..."
    rsync -aAXv --info=progress2 "$temp_dir/" "$restore_dir/" 2>&1 | tee -a "$LOG_FILE"
    
    local rsync_status=$?
    if [ $rsync_status -ne 0 ]; then
        error "Failed to sync files to restore location"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    log "Restore completed successfully"
    return 0
}

# Display menu function
display_menu() {
    local title="$1"
    shift
    local options=("$@")
    local selected=0
    local key=""
    
    # Save current terminal settings
    local saved_tty=$(stty -g)
    
    # Set terminal to raw mode
    stty raw -echo
    
    while true; do
        # Clear screen
        echo -e "\033[2J\033[H"
        
        # Display title
        echo -e "\033[1m$title\033[0m"
        echo
        
        # Display options
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then
                echo -e "\033[7m> ${options[$i]}\033[0m"
            else
                echo "  ${options[$i]}"
            fi
        done
        
        # Read key
        key=$(dd bs=1 count=1 2>/dev/null)
        
        # Process key
        case "$key" in
            $'\033')  # ESC sequence
                read -t 0.
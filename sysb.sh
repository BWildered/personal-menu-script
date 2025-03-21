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
    echo "ERROR: $1" >&2
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
        local value=$(grep "^$key=" "$INI_FILE" | cut -d'=' -f2- | sed 's/^"//;s/"$//')
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
        sed -i "s|^$key=.*|$key=\"$value\"|" "$INI_FILE"
    else
        # Key doesn't exist, append it
        echo "$key=\"$value\"" >> "$INI_FILE"
    fi
}

# Function to add directory to history
add_directory_to_history() {
    local type="$1"  # source or destination
    local dir="$2"
    local history_key="${type}_history"
    local history=$(read_ini "$history_key" "")
    
    # Check if directory is already in history
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 5242880 ]; then
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
    local missing_deps=0
    
    if ! command -v rsync &> /dev/null; then
        error "rsync could not be found. Please install it."
        missing_deps=1
    fi
    if ! command -v tar &> /dev/null; then
        error "tar could not be found. Please install it."
        missing_deps=1
    fi
    if ! command -v xz &> /dev/null; then
        error "xz could not be found. Please install it."
        missing_deps=1
    fi
    
    return $missing_deps
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
    log "Starting rsync operation..."
    rsync $rsync_params "${exclude_params[@]}" "$source_dir/" "$temp_dir/"
    local rsync_status=$?
    log "Rsync operation completed with status: $rsync_status"
    
    if [ $rsync_status -ne 0 ]; then
        error "rsync failed with error code $rsync_status"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Now create compressed archive with maximum compression
    log "Creating compressed archive $archive_name (with maximum compression)..."
    log "Starting tar compression..."
    XZ_OPT="-$compression_level" tar -cJf "$dest_dir/$archive_name" -C "$temp_dir" .
    local tar_status=$?
    log "Tar compression completed with status: $tar_status"
    
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
    local tar_extract_status=${PIPESTATUS[0]}
    
    if [ $tar_extract_status -ne 0 ]; then
        error "Failed to extract backup archive"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Sync files to restore location
    log "Syncing files to restore location..."
    rsync -aAXv --info=progress2 "$temp_dir/" "$restore_dir/" 2>&1 | tee -a "$LOG_FILE"
    local rsync_status=${PIPESTATUS[0]}
    
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
# Improved display_menu function
display_menu() {
if [ -z "$TERM" ] || [ "$TERM" = "dumb" ]; then
    export TERM=linux
fi
    local title="$1"
    shift
    local options=("$@")
    local selected=0
    local key=""
    
    # Check terminal capabilities
    if ! tput clear >/dev/null 2>&1; then
        # Fallback to basic menu if tput fails
        echo "=== $title ==="
        echo
        for i in "${!options[@]}"; do
            echo "$((i+1)). ${options[$i]}"
        done
        echo "q. Quit"
        echo
        echo -n "Enter your choice: "
        read choice
        
        if [[ $choice == "q" ]]; then
            return 255
        elif [[ $choice =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            return $((choice-1))
        else
            echo "Invalid choice. Please try again."
            sleep 1
            return 254
        fi
    fi
    
    # Full-featured menu with arrow key navigation
    while true; do
        # Clear screen and print title
        tput clear
        echo "=== $title ==="
        echo
        
        # Print menu options
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then
                echo -e "-> \033[1m${options[$i]}\033[0m"
            else
                echo "   ${options[$i]}"
            fi
        done
        
        # Print quit option
        if [ $selected -eq "${#options[@]}" ]; then
            echo -e "-> \033[1mQuit\033[0m"
        else
            echo "   Quit"
        fi
        
        # Get user input
        read -rsn1 key
        
        # Handle arrow keys
        case "$key" in
            A) # Up arrow
                selected=$((selected-1))
                if [ $selected -lt 0 ]; then
                    selected=$((${#options[@]}))
                fi
                ;;
            B) # Down arrow
                selected=$((selected+1))
                if [ $selected -gt "${#options[@]}" ]; then
                    selected=0
                fi
                ;;
            "") # Enter key
                if [ $selected -eq "${#options[@]}" ]; then
                    return 255
                else
                    return $selected
                fi
                ;;
            q) # Quit
                return 255
                ;;
        esac
    done
}

# Function to select directory
select_directory() {
    local type="$1"  # "source" or "destination"
    local title="Select $type directory"
    local history_key="${type}_history"
    local history=$(read_ini "$history_key" "")
    local options=()
    
    # Add history options
    if [ -n "$history" ]; then
        IFS=':' read -ra dirs <<< "$history"
        for dir in "${dirs[@]}"; do
            options+=("$dir")
        done
    fi
    
    # Add other options
    options+=("Enter custom path")
    
    # Display menu
    display_menu "$title" "${options[@]}"
    local choice=$?
    
    if [ $choice -eq 255 ]; then
        return 1
    elif [ $choice -eq $((${#options[@]}-1)) ]; then
        # Custom path selected
        echo -n "Enter $type directory path: "
        read custom_path
        if [ -n "$custom_path" ]; then
            echo "$custom_path"
            return 0
        else
            return 1
        fi
    else
        # History option selected
        echo "${options[$choice]}"
        return 0
    fi
}

# Function to configure backup
configure_backup() {
    local selected_option="source"
    local options=("Configure source directory" "Configure destination directory" "Configure exclusions" "Configure compression level" "Configure temp file retention" "Save and return")
    
    while true; do
        display_menu "Backup Configuration" "${options[@]}"
        local choice=$?
        
        if [ $choice -eq 255 ]; then
            return 1
        fi
        
        case $choice in
            0) # Configure source directory
                local source_dir=$(select_directory "source")
                if [ -n "$source_dir" ]; then
                    write_ini "source_dir" "$source_dir"
                    add_directory_to_history "source" "$source_dir"
                    log "Source directory set to $source_dir"
                fi
                ;;
            1) # Configure destination directory
                local dest_dir=$(select_directory "destination")
                if [ -n "$dest_dir" ]; then
                    write_ini "backup_dir" "$dest_dir"
                    add_directory_to_history "destination" "$dest_dir"
                    log "Destination directory set to $dest_dir"
                fi
                ;;
            2) # Configure exclusions
                echo "Enter directories to exclude (separated by colon):"
                echo "Current exclusions: $(read_ini "exclude_dirs" "none")"
                read exclude_dirs
                write_ini "exclude_dirs" "$exclude_dirs"
                log "Exclusions set to $exclude_dirs"
                ;;
            3) # Configure compression level
                echo "Enter compression level (1-9, where 9 is maximum compression):"
                echo "Current level: $(read_ini "compression_level" "9")"
                read compression_level
                if [[ "$compression_level" =~ ^[1-9]$ ]]; then
                    write_ini "compression_level" "$compression_level"
                    log "Compression level set to $compression_level"
                else
                    echo "Invalid compression level. Please enter a number between 1 and 9."
                    sleep 2
                fi
                ;;
            4) # Configure temp file retention
                echo "Keep temporary files after backup? (0=no, 1=yes)"
                echo "Current setting: $(read_ini "keep_temp" "0")"
                read keep_temp
                if [[ "$keep_temp" =~ ^[01]$ ]]; then
                    write_ini "keep_temp" "$keep_temp"
                    log "Temp file retention set to $keep_temp"
                else
                    echo "Invalid option. Please enter 0 or 1."
                    sleep 2
                fi
                ;;
            5) # Save and return
                return 0
                ;;
        esac
    done
}
# Function to configure restore
configure_restore() {
    local options=("Select backup file" "Select restore directory" "Save and return")
    
    while true; do
        display_menu "Restore Configuration" "${options[@]}"
        local choice=$?
        
        if [ $choice -eq 255 ]; then
            return 1
        fi
        
        case $choice in
            0) # Select backup file
                echo "Enter path to backup file:"
                echo "Current backup file: $(read_ini "last_backup" "none")"
                read backup_file
                if [ -f "$backup_file" ]; then
                    write_ini "last_backup" "$backup_file"
                    log "Backup file set to $backup_file"
                else
                    echo "File not found. Please enter a valid path."
                    sleep 2
                fi
                ;;
            1) # Select restore directory
                local restore_dir=$(select_directory "restore")
                if [ -n "$restore_dir" ]; then
                    write_ini "restore_dir" "$restore_dir"
                    log "Restore directory set to $restore_dir"
                fi
                ;;
            2) # Save and return
                return 0
                ;;
        esac
    done
}

# Function to show backup history
show_backup_history() {
    local last_backup=$(read_ini "last_backup" "")
    local last_backup_dir=$(read_ini "last_backup_dir" "")
    
    echo "Backup History:"
    echo "---------------"
    echo "Last backup file: $last_backup"
    echo "Last backup directory: $last_backup_dir"
    
    if [ -f "$last_backup" ]; then
        echo "Backup file size: $(du -sh "$last_backup" | cut -f1)"
        echo "Backup file date: $(stat -c %y "$last_backup")"
    else
        echo "Last backup file not found or not set."
    fi
    
    echo
    echo "Press any key to continue..."
    read -n 1
}

# Function to recover from errors
error_recovery() {
    local options=("View error log" "Clear error states" "Return to main menu")
    
    while true; do
        display_menu "Error Recovery" "${options[@]}"
        local choice=$?
        
        if [ $choice -eq 255 ]; then
            return
        fi
        
        case $choice in
            0) # View error log
                if [ -f "$ERROR_STATE_FILE" ]; then
                    echo "Error log:"
                    cat "$ERROR_STATE_FILE"
                    echo
                    echo "Press any key to continue..."
                    read -n 1
                else
                    echo "No error log found."
                    sleep 2
                fi
                ;;
            1) # Clear error states
                clear_errors
                echo "Error states cleared."
                sleep 2
                return
                ;;
            2) # Return to main menu
                return
                ;;
        esac
    done
}
# Main menu
main_menu() {
    local options=("Perform Backup" "Perform Restore" "Configure Backup" "Configure Restore" "Show Backup History" "Error Recovery" "About")
    
    while true; do
        display_menu "System Backup Script" "${options[@]}"
        local choice=$?
        
        if [ $choice -eq 255 ]; then
            echo "Exiting..."
            exit 0
        fi
        
        case $choice in
            0) # Perform Backup
                if perform_backup; then
                    echo "Backup completed successfully."
                else
                    echo "Backup failed. See error log for details."
                    error_recovery
                fi
                sleep 2
                ;;
            1) # Perform Restore
                if perform_restore; then
                    echo "Restore completed successfully."
                else
                    echo "Restore failed. See error log for details."
                    error_recovery
                fi
                sleep 2
                ;;
            2) # Configure Backup
                configure_backup
                ;;
            3) # Configure Restore
                configure_restore
                ;;
            4) # Show Backup History
                show_backup_history
                ;;
            5) # Error Recovery
                error_recovery
                ;;
            6) # About
                echo "System Backup Script v1.0"
                echo "A comprehensive backup solution for Linux systems"
                echo "Features:"
                echo "- Incremental backups with rsync"
                echo "- Maximum compression with XZ"
                echo "- Backup verification"
                echo "- Error recovery"
                echo "- Comprehensive logging"
                echo
                echo "Press any key to continue..."
                read -n 1
                ;;
            *)
                echo "Invalid choice. Please try again."
                ;;
        esac
    done
}
# Check dependencies
if ! check_dependencies; then
    echo "Missing dependencies. Please install required packages."
    exit 1
fi

# Check for errors
if ! check_errors; then
    echo "Errors detected from previous run."
    error_recovery
fi

# Start main menu
main_menu
# Signal handling for graceful exit
trap cleanup_and_exit SIGINT SIGTERM

# Cleanup function
cleanup_and_exit() {
    log "Script terminated by user or system signal"
    
    # Check if backup is in progress
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        log "Cleaning up temporary directory: $temp_dir"
        rm -rf "$temp_dir"
    fi
    
    log "Exiting gracefully"
    exit 0
}

# Log script start
log "System Backup Script started"

# Check dependencies
if ! check_dependencies; then
    error "Missing dependencies. Please install required packages."
    exit 1
fi

# Check for errors
if ! check_errors; then
    log "Errors detected from previous run."
    error_recovery
fi

# Start main menu
main_menu

# This point should never be reached under normal conditions
log "Script execution completed"
exit 0

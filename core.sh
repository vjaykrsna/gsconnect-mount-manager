#!/bin/bash
# Core utilities and foundational functions for GSConnect Mount Manager

# File locking functions
lock_file() {
    local lockfile="$1.lock"
    local timeout="${2:-10}"
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        if mkdir "$lockfile" 2>/dev/null; then
            echo $$ > "$lockfile/PID" 2>/dev/null || true
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    return 1
}

unlock_file() {
    local lockfile="$1.lock"
    if [[ -d "$lockfile" ]] && [[ -f "$lockfile/PID" ]] && [[ "$(cat "$lockfile/PID")" == "$$" ]]; then
        rm -rf "$lockfile"
    fi
}

# Logging functions
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Check if we should log this level (always log if VERBOSE is true)
    if [[ "$VERBOSE" != true ]]; then
        case "$LOG_LEVEL" in
            DEBUG) ;;
            INFO) [[ "$level" == "DEBUG" ]] && return ;;
            WARN) [[ "$level" == "DEBUG" || "$level" == "INFO" ]] && return ;;
            ERROR) [[ "$level" != "ERROR" ]] && return ;;
        esac
    fi

    # Write to log file (plain text, no colors)
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Output to console with colors (only if not DEBUG or if VERBOSE is true)
    if [[ "$level" != "DEBUG" ]] || [[ "$VERBOSE" == true ]]; then
        case "$level" in
            ERROR) echo -e "\033[0;31m[$timestamp] [$level] $message\033[0m" ;;
            WARN) echo -e "\033[1;33m[$timestamp] [$level] $message\033[0m" ;;
            INFO) echo -e "\033[0;32m[$timestamp] [$level] $message\033[0m" ;;
            DEBUG) [[ "$VERBOSE" == true ]] && echo -e "\033[0;36m[$timestamp] [$level] $message\033[0m" ;;
        esac
    fi
}

# Conditional logging function for command substitution contexts
log_conditional() {
    local level="$1"
    local message="$2"
    
    # Only log if not in command substitution (when stdout is not captured)
    if [[ -t 1 ]]; then
        log_message "$level" "$message"
    fi
}

# Log rotation function
rotate_logs() {
    if [[ "$MAX_LOG_SIZE" -gt 0 ]] && [[ -f "$LOG_FILE" ]]; then
        # Get file size in bytes (portable way)
        local size_bytes
        if command -v stat >/dev/null 2>&1; then
            # Try GNU stat first, then BSD stat
            size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        else
            # Fallback using ls and awk
            size_bytes=$(ls -l "$LOG_FILE" 2>/dev/null | awk '{print $5}' || echo 0)
        fi

        local size_mb=$((size_bytes / 1024 / 1024))
        if [[ "$size_mb" -gt "$MAX_LOG_SIZE" ]]; then
            if lock_file "$LOG_FILE"; then
                for i in $(seq $((LOG_ROTATE_COUNT-1)) -1 1); do
                    [[ -f "$LOG_FILE.$i" ]] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
                done
                mv "$LOG_FILE" "$LOG_FILE.1"
                touch "$LOG_FILE"
                unlock_file "$LOG_FILE"
                log_conditional "INFO" "Log rotated (was ${size_mb}MB)"
            else
                log_conditional "ERROR" "Failed to acquire lock for log file during rotation"
            fi
        fi
    fi
}

# Desktop notification function
send_notification() {
    if [[ "$ENABLE_NOTIFICATIONS" != true ]]; then
        return
    fi
    
    local message="$1"
    
    # Try multiple notification systems based on desktop environment
    local desktop_env=$(echo "$XDG_CURRENT_DESKTOP" | tr '[:upper:]' '[:lower:]')
    
    # KDE notification
    if [[ "$desktop_env" == *"kde"* ]] && command -v kdialog >/dev/null 2>&1; then
        kdialog --passivepopup "$message" 5 2>/dev/null
        return
    fi
    
    # GNOME and other desktops with notify-send
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "GSConnect Mount Manager" "$message" --icon=phone 2>/dev/null
        return
    fi
    
    # Fallback to terminal output if no notification system available
    log_conditional "INFO" "Notification: $message"
}
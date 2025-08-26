#!/bin/bash
# Storage management functions for GSConnect Mount Manager

# Function to cleanup broken symlinks
cleanup_broken_symlinks() {
    if [[ "$AUTO_CLEANUP" != true ]]; then
        log_conditional "DEBUG" "Auto cleanup disabled. Skipping."
        return
    fi

    if [[ ! -d "$MOUNT_STRUCTURE_DIR" ]]; then
        log_conditional "DEBUG" "Mount structure directory not found. Skipping cleanup."
        return
    fi

    log_conditional "DEBUG" "Starting cleanup of broken symlinks in $MOUNT_STRUCTURE_DIR"
    local broken_links
    mapfile -t broken_links < <(find "$MOUNT_STRUCTURE_DIR" -type l ! -exec test -e {} \; -print 2>/dev/null)

    if [[ ${#broken_links[@]} -gt 0 ]]; then
        log_conditional "DEBUG" "Found ${#broken_links[@]} broken symlinks."
        for broken_link in "${broken_links[@]}"; do
            if [[ -n "$broken_link" ]]; then
                rm "$broken_link"
                log_conditional "INFO" "Cleaned up broken symlink: $broken_link"
            fi
        done
    else
        log_conditional "DEBUG" "No broken symlinks found."
    fi

    log_conditional "DEBUG" "Checking for empty device directories..."
    local empty_dirs
    mapfile -t empty_dirs < <(find "$MOUNT_STRUCTURE_DIR" -mindepth 1 -maxdepth 1 -type d -empty -print 2>/dev/null)

    if [[ ${#empty_dirs[@]} -gt 0 ]]; then
        log_conditional "DEBUG" "Found ${#empty_dirs[@]} empty device directories."
        for empty_dir in "${empty_dirs[@]}"; do
            if [[ -n "$empty_dir" ]]; then
                rmdir "$empty_dir"
                log_conditional "INFO" "Cleaned up empty device directory: $(basename "$empty_dir")"
            fi
        done
    else
        log_conditional "DEBUG" "No empty device directories found."
    fi
}

# Function to discover available storage paths on device
discover_storage_paths() {
    local mount_point="$1"
    local storage_paths=()

    log_conditional "DEBUG" "Starting storage path discovery in: $mount_point"

    # Check for internal storage
    if [[ "$ENABLE_INTERNAL_STORAGE" == true ]]; then
        log_conditional "DEBUG" "Internal storage detection enabled. Path: $INTERNAL_STORAGE_PATH"
        local internal_path="$mount_point/$INTERNAL_STORAGE_PATH"
        if [[ -d "$internal_path" ]]; then
            storage_paths+=("internal:$internal_path")
            log_conditional "INFO" "Found internal storage: $internal_path"
        else
            log_conditional "WARN" "Internal storage path not found: $internal_path"
        fi
    else
        log_conditional "DEBUG" "Internal storage detection disabled."
    fi

    # Check for external storage
    if [[ "$ENABLE_EXTERNAL_STORAGE" == true ]]; then
        log_conditional "DEBUG" "External storage detection enabled. Patterns: $EXTERNAL_STORAGE_PATTERNS"
        local storage_dir="$mount_point/storage"
        if [[ -d "$storage_dir" ]]; then
            local external_count=0
            IFS=' ' read -ra patterns <<< "$EXTERNAL_STORAGE_PATTERNS"
            log_conditional "DEBUG" "Searching for patterns in: $storage_dir"

            for pattern in "${patterns[@]}"; do
                if [[ $external_count -ge $MAX_EXTERNAL_STORAGE ]]; then
                    log_conditional "DEBUG" "Reached max external storage limit ($MAX_EXTERNAL_STORAGE). Stopping search."
                    break
                fi

                log_conditional "DEBUG" "Checking pattern: $pattern"
                
                # Handle different pattern types
                if [[ "$pattern" == *"*"* ]] || [[ "$pattern" == *"["*"]"* ]] || [[ "$pattern" == *"?"* ]]; then
                    # This is a glob pattern, use find with -name
                    local found_paths
                    if ! mapfile -t found_paths < <(find "$storage_dir" -maxdepth 1 -type d -name "${pattern##*/}" -print 2>/dev/null); then
                        log_conditional "WARN" "Failed to execute find command for pattern: $pattern in $storage_dir"
                        continue
                    fi
                    for external_path in "${found_paths[@]}"; do
                        if [[ -n "$external_path" ]] && [[ -d "$external_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                            storage_paths+=("external:$external_path")
                            log_conditional "INFO" "Found external storage (glob): $external_path"
                            ((external_count++))
                        fi
                    done
                else
                    # Direct path pattern
                    local external_path="$mount_point/$pattern"
                    if [[ -d "$external_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                        storage_paths+=("external:$external_path")
                        log_conditional "INFO" "Found external storage (direct): $external_path"
                        ((external_count++))
                    fi
                fi
            done

            # Fallback: if no external storage found, try to find any storage directories
            if [[ $external_count -eq 0 ]]; then
                log_conditional "DEBUG" "No external storage devices found matching patterns. Trying fallback detection."
                local fallback_paths
                if ! mapfile -t fallback_paths < <(find "$storage_dir" -maxdepth 1 -type d -not -name "emulated" -not -name "." 2>/dev/null); then
                    log_conditional "WARN" "Failed to execute fallback find command in $storage_dir"
                else
                    log_conditional "DEBUG" "Fallback detection found ${#fallback_paths[@]} paths in $storage_dir"
                    for fallback_path in "${fallback_paths[@]}"; do
                        log_conditional "DEBUG" "Checking fallback path: $fallback_path"
                        if [[ -n "$fallback_path" ]] && [[ -d "$fallback_path" ]] && [[ $external_count -lt $MAX_EXTERNAL_STORAGE ]]; then
                            # Skip common system directories and the storage directory itself
                            local basename_fallback=$(basename "$fallback_path")
                            log_conditional "DEBUG" "Fallback path basename: $basename_fallback, storage_dir: $storage_dir, fallback_path: $fallback_path"
                            if [[ "$basename_fallback" != "self" ]] && [[ "$basename_fallback" != "emulated" ]] && [[ "$fallback_path" != "$storage_dir" ]]; then
                                storage_paths+=("external:$fallback_path")
                                log_conditional "INFO" "Found external storage (fallback): $fallback_path"
                                ((external_count++))
                            else
                                log_conditional "DEBUG" "Skipping fallback path: $fallback_path"
                            fi
                        fi
                    done
                fi
            fi
            
            if [[ $external_count -eq 0 ]]; then
                log_conditional "DEBUG" "No external storage devices found."
            fi
        else
            log_conditional "WARN" "Base storage directory not found: $storage_dir"
        fi
    else
        log_conditional "DEBUG" "External storage detection disabled."
    fi

    # Return the discovered paths
    if [[ ${#storage_paths[@]} -gt 0 ]]; then
        log_conditional "DEBUG" "Discovered storage paths: ${storage_paths[*]}"
        printf '%s\n' "${storage_paths[@]}"
    else
        log_conditional "WARN" "No storage paths were discovered."
    fi
}

# Function to create storage symlink within device directory
create_storage_symlink() {
    local device_dir="$1"
    local storage_type="$2"  # "internal", "external", or "usb"
    local target_path="$3"
    local storage_index="${4:-}"  # For multiple external storage

    # Determine folder name based on storage type
    local folder_name=""
    case "$storage_type" in
        internal)
            folder_name="$INTERNAL_STORAGE_NAME"
            ;;
        external)
            folder_name="$EXTERNAL_STORAGE_NAME"
            if [[ -n "$storage_index" ]] && [[ "$storage_index" -gt 1 ]]; then
                folder_name="${folder_name}${storage_index}"
            fi
            ;;
        usb)
            folder_name="$USB_STORAGE_NAME"
            if [[ -n "$storage_index" ]] && [[ "$storage_index" -gt 1 ]]; then
                folder_name="${folder_name}${storage_index}"
            fi
            ;;
    esac

    local link_path="$device_dir/$folder_name"

    # Remove existing symlink or directory if it exists
    if [[ -L "$link_path" ]]; then
        rm "$link_path"
        log_conditional "DEBUG" "Removed existing symlink: $link_path"
    elif [[ -d "$link_path" ]]; then
        # It's a directory, remove it
        rm -rf "$link_path"
        log_conditional "DEBUG" "Removed existing directory: $link_path"
    elif [[ -e "$link_path" ]]; then
        # It's a regular file, remove it
        rm -f "$link_path"
        log_conditional "DEBUG" "Removed existing file: $link_path"
    fi

    # Create the symlink
    log_conditional "DEBUG" "create_storage_symlink called with parameters:"
    log_conditional "DEBUG" "  device_dir: $device_dir"
    log_conditional "DEBUG" "  storage_type: $storage_type"
    log_conditional "DEBUG" "  target_path: $target_path"
    log_conditional "DEBUG" "  storage_index: $storage_index"
    log_conditional "DEBUG" "  folder_name: $folder_name"
    log_conditional "DEBUG" "  link_path: $link_path"
    
    if ln -s "$target_path" "$link_path"; then
       if lock_file "$LINK_PATH_FILE"; then
           echo "$link_path" >> "$LINK_PATH_FILE"
           unlock_file "$LINK_PATH_FILE"
           log_conditional "INFO" "🔗 ${storage_type^} storage linked: $link_path → $target_path"
       else
           log_conditional "ERROR" "Failed to acquire lock for link path file"
       fi
       return 0
   else
       log_conditional "ERROR" "Failed to create symlink: $link_path"
       return 1
   fi
}
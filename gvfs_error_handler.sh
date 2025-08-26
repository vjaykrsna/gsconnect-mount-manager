#!/usr/bin/env bash
# GSConnect Mount Manager - GVFS Error Handling
# Provides safe wrappers for commands interacting with GVFS mounts

set -euo pipefail
IFS=$'\n\t'

# ---------- Safe GVFS Operation ----------
# Executes a command safely, retrying transient GVFS errors
# Arguments: Command and its arguments
# Returns: 0 if success, 1 if failed
safe_gvfs_op() {
    local max_retries=3
    local retry_delay=1
    local attempt=1
    local error_log="/tmp/gvfs_error_$$.log"

    # Special handling for bash builtins like [[
    if [[ "$1" == "[[" ]]; then
        [[ "$@" ]]
        return $?
    fi

    # Retry loop
    while (( attempt <= max_retries )); do
        if "$@" 2>"$error_log"; then
            rm -f "$error_log"
            return 0
        else
            # Check for common GVFS symlink error
            if grep -q "GFileInfo created without standard::is-symlink" "$error_log"; then
                echo "WARN: GVFS symlink error (attempt $attempt): $*" >&2
                (( attempt < max_retries )) && { echo "INFO: Retrying in $retry_delay sec..." >&2; sleep $retry_delay; ((attempt++)); continue; }

                echo "ERROR: Persistent GVFS symlink error after $max_retries attempts: $*" >&2
                echo "ERROR: Details in $error_log" >&2
                rm -f "$error_log"
                return 1
            else
                echo "ERROR: Command failed: $*" >&2
                echo "ERROR: Details:" >&2
                while IFS= read -r line; do
                    echo "ERROR:   $line" >&2
                done <"$error_log"
                rm -f "$error_log"
                return 1
            fi
        fi
    done
}


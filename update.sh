#!/usr/bin/env bash
set -euo pipefail

# -------- Colors --------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { printf "%b%s%b\n" "$1" "$2" "$NC"; }

log "$YELLOW" "Updating GSConnect Mount Manager..."

# -------- Ensure git repo --------
if ! git rev-parse --git-dir &>/dev/null; then
    log "$RED" "Not in a git repository. Cannot update."
    exit 1
fi

# -------- Pull latest changes --------
if ! git pull --ff-only; then
    log "$YELLOW" "Default pull failed. Trying origin/main..."
    if ! git pull origin main --ff-only; then
        log "$RED" "Failed to pull from origin main."
        exit 1
    fi
fi

# -------- Warn if uncommitted changes exist --------
if ! git diff-index --quiet HEAD --; then
    log "$YELLOW" "Warning: You have uncommitted changes. They might be overwritten."
fi

# -------- Run installer --------
if [[ ! -f "./install.sh" ]]; then
    log "$RED" "install.sh not found. Cannot update."
    exit 1
fi

if ! ./install.sh; then
    log "$RED" "Installation/update failed."
    exit 1
fi

log "$GREEN" "✅ Update complete!"

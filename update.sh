#!/usr/bin/env bash
set -euo pipefail

echo "Updating GSConnect Mount Manager..."

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

# Try to pull latest changes, but handle cases where origin or main might be different
if ! git pull; then
    echo "Warning: Failed to pull from default remote. Trying origin main..."
    if ! git pull origin main; then
        echo "Error: Failed to pull from origin main"
        exit 1
    fi
fi

# Check if install.sh exists before running it
if [ ! -f "./install.sh" ]; then
    echo "Error: install.sh not found"
    exit 1
fi

# Run installer (handles updates)
./install.sh

echo "Update complete!"
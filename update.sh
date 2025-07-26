#!/usr/bin/env bash
set -euo pipefail

echo "Updating GSConnect Mount Manager..."

# Pull latest changes
git pull origin main

# Run installer (handles updates)
./install.sh

echo "Update complete!"
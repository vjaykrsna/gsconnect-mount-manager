
#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      echo "Usage: $0"
      echo "  -h, --help    Show this help message"
      echo
      echo "This script installs GSConnect Mount Manager with default settings."
      echo "To customize settings, edit ~/.config/gsconnect-mount-manager/config.conf after installation."
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# if root, exit
if [ "$(id -u)" -eq 0 ]; then
  echo -e "${RED}Please run this script as a normal user${NC}"
  exit 1
fi

# Get home directory of user
USER_HOME="$HOME"

# changing directory to the script directory
script_dir=$(dirname "$0")
cd "$script_dir" || exit # Exit the script if cd doesn't work, prevents following commands from running

# Check if required files exist
required_files=("run.sh" "config_loader.sh" "config.conf")
for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Error: Required file '$file' not found${NC}"
        exit 1
    fi
done

# putting files in place
echo -e "${GREEN}Installing gsconnect-mount-manager...${NC}"
install_dir="$USER_HOME/.config/gsconnect-mount-manager"
mkdir -p "$install_dir"
cp -f ./run.sh "$install_dir/"
cp -f ./config_loader.sh "$install_dir/"
chmod +x "$install_dir/run.sh"
chmod +x "$install_dir/config_loader.sh"

# Create configuration file
config_file="$install_dir/config.conf"
echo -e "${GREEN}Creating default configuration file...${NC}"
cp -f ./config.conf "$config_file"

# Create systemd service file
echo -e "${GREEN}Creating systemd service...${NC}"
service_file="$USER_HOME/.config/systemd/user/gsconnect-mount-manager.service"
mkdir -p "$(dirname "$service_file")"
cat > "$service_file" << EOF
[Unit]
Description=GSConnect Mount Manager
After=network.target

[Service]
Type=simple
ExecStart=$install_dir/run.sh
Restart=always
RestartSec=5
Environment=HOME=$USER_HOME

[Install]
WantedBy=default.target
EOF

# enabling service
echo -e "${GREEN}Reloading and starting the gsconnect-mount-manager service...${NC}"
systemctl --user daemon-reload
systemctl --user enable gsconnect-mount-manager.service

# Use start instead of restart for new installations
if systemctl --user is-active gsconnect-mount-manager.service >/dev/null 2>&1; then
    systemctl --user restart gsconnect-mount-manager.service
else
    systemctl --user start gsconnect-mount-manager.service
fi

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                        Installation Complete!                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}Service Status:${NC}"
systemctl --user is-active gsconnect-mount-manager.service >/dev/null 2>&1 && \
    echo -e "  ${GREEN}✓${NC} GSConnect Mount Manager is running" || \
    echo -e "  ${RED}✗${NC} Service failed to start"

echo
echo -e "${CYAN}Configuration:${NC}"
echo -e "  Config file: ${BLUE}$install_dir/config.conf${NC}"
echo -e "  Log file: ${BLUE}$install_dir/gsconnect-mount-manager.log${NC}"
echo -e "  Service file: ${BLUE}$service_file${NC}"

echo
echo -e "${CYAN}Default Settings:${NC}"
echo -e "  📁 Single bookmark per device (shows internal storage, SD cards as subfolders)"
echo -e "  🔗 Separate symlinks for internal storage and SD cards"
echo -e "  🔔 Desktop notifications enabled"
echo -e "  📊 INFO level logging with rotation"
echo -e "  ⚡ 5-second polling interval"

echo
echo -e "${YELLOW}💡 Customization:${NC}"
echo -e "  Edit ${BLUE}$install_dir/config.conf${NC} to customize settings"
echo -e "  Restart service after changes: ${BLUE}systemctl --user restart gsconnect-mount-manager${NC}"

echo
echo -e "${YELLOW}Usage:${NC}"
echo -e "  ${BLUE}systemctl --user status gsconnect-mount-manager${NC}  - Check service status"
echo -e "  ${BLUE}systemctl --user stop gsconnect-mount-manager${NC}    - Stop the service"
echo -e "  ${BLUE}systemctl --user start gsconnect-mount-manager${NC}   - Start the service"
echo -e "  ${BLUE}journalctl --user -u gsconnect-mount-manager -f${NC}  - View live logs"

echo
echo -e "${GREEN}Connect your phone via GSConnect and enable file sharing to test!${NC}"
echo

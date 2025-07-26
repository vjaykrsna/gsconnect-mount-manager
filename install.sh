
#!/bin/sh
set -eu

# Colors for output
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
PURPLE=$(printf '\033[0;35m')
CYAN=$(printf '\033[0;36m')
NC=$(printf '\033[0m') # No Color

# Parse command line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      printf "Usage: %s\n" "$0"
      printf "  -h, --help    Show this help message\n"
      printf "\n"
      printf "This script installs GSConnect Mount Manager with default settings.\n"
      printf "To customize settings, edit ~/.config/gsconnect-mount-manager/config.conf after installation.\n"
      exit 0
      ;;
    *)
      printf "%sUnknown option: %s%s\n" "$RED" "$1" "$NC"
      printf "Use --help for usage information\n"
      exit 1
      ;;
  esac
done

# if root, exit
if [ "$(id -u)" -eq 0 ]; then
  printf "%sPlease run this script as a normal user%s\n" "$RED" "$NC"
  exit 1
fi

# Get home directory of user
USER_HOME="$HOME"

# changing directory to the script directory
script_dir=$(dirname "$0")
cd "$script_dir" || exit # Exit the script if cd doesn't work, prevents following commands from running

# Check if required files exist
required_files="run.sh config_loader.sh config.conf"
for file in $required_files; do
    if [ ! -f "$file" ]; then
        printf "%sError: Required file '%s' not found%s\n" "$RED" "$file" "$NC"
        exit 1
    fi
done

# Check if already installed
if systemctl --user is-active gsconnect-mount-manager.service >/dev/null 2>&1; then
    printf "%sExisting installation detected. Updating...%s\n" "$YELLOW" "$NC"
else
    printf "%sNew installation.%s\n" "$GREEN" "$NC"
fi

# putting files in place
printf "%sInstalling gsconnect-mount-manager...%s\n" "$GREEN" "$NC"
install_dir="$USER_HOME/.config/gsconnect-mount-manager"
mkdir -p "$install_dir"
cp -f ./run.sh "$install_dir/"
cp -f ./config_loader.sh "$install_dir/"
chmod +x "$install_dir/run.sh"
chmod +x "$install_dir/config_loader.sh"

# Create configuration file
config_file="$install_dir/config.conf"
printf "%sCreating default configuration file...%s\n" "$GREEN" "$NC"
cp -f ./config.conf "$config_file"

# Create systemd service file
printf "%sCreating systemd service...%s\n" "$GREEN" "$NC"
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
printf "%sReloading and starting the gsconnect-mount-manager service...%s\n" "$GREEN" "$NC"
systemctl --user daemon-reload
systemctl --user enable gsconnect-mount-manager.service

# Use start instead of restart for new installations
if systemctl --user is-active gsconnect-mount-manager.service >/dev/null 2>&1; then
    systemctl --user restart gsconnect-mount-manager.service
else
    systemctl --user start gsconnect-mount-manager.service
fi

printf "\n"
printf "%s╔══════════════════════════════════════════════════════════════╗%s\n" "$GREEN" "$NC"
printf "%s║                        Installation Complete!                ║%s\n" "$GREEN" "$NC"
printf "%s╚══════════════════════════════════════════════════════════════╝%s\n" "$GREEN" "$NC"
printf "\n"
printf "%sService Status:%s\n" "$CYAN" "$NC"
if systemctl --user is-active gsconnect-mount-manager.service >/dev/null 2>&1; then
    printf "  %s✓%s GSConnect Mount Manager is running\n" "$GREEN" "$NC"
else
    printf "  %s✗%s Service failed to start\n" "$RED" "$NC"
fi

printf "\n"
printf "%sConfiguration:%s\n" "$CYAN" "$NC"
printf "  Config file: %s%s%s\n" "$BLUE" "$install_dir/config.conf" "$NC"
printf "  Log file: %s%s%s\n" "$BLUE" "$install_dir/gsconnect-mount-manager.log" "$NC"
printf "  Service file: %s%s%s\n" "$BLUE" "$service_file" "$NC"

printf "\n"
printf "%sDefault Settings:%s\n" "$CYAN" "$NC"
printf "  📁 Single bookmark per device (shows internal storage, SD cards as subfolders)\n"
printf "  🔗 Separate symlinks for internal storage and SD cards\n"
printf "  🔔 Desktop notifications enabled\n"
printf "  📊 INFO level logging with rotation\n"
printf "  ⚡ 5-second polling interval\n"

printf "\n"
printf "%s💡 Customization:%s\n" "$YELLOW" "$NC"
printf "  Edit %s%s%s to customize settings\n" "$BLUE" "$install_dir/config.conf" "$NC"
printf "  Restart service after changes: %ssystemctl --user restart gsconnect-mount-manager%s\n" "$BLUE" "$NC"

printf "\n"
printf "%sUsage:%s\n" "$YELLOW" "$NC"
printf "  %ssystemctl --user status gsconnect-mount-manager%s  - Check service status\n" "$BLUE" "$NC"
printf "  %ssystemctl --user stop gsconnect-mount-manager%s    - Stop the service\n" "$BLUE" "$NC"
printf "  %ssystemctl --user start gsconnect-mount-manager%s   - Start the service\n" "$BLUE" "$NC"
printf "  %sjournalctl --user -u gsconnect-mount-manager -f%s  - View live logs\n" "$BLUE" "$NC"

printf "\n"
printf "%sConnect your phone via GSConnect and enable file sharing to test!%s\n" "$GREEN" "$NC"
printf "\n"

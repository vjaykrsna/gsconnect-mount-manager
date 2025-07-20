
# if root, exit
if [ "$(id -u)" -eq 0 ]; then
  echo -e "\e[91mPlease run this script as a normal user\e[0m"
  exit 1
fi


# Get home directory of user
if [ "$(id -u)" -eq 0 ]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  USER_HOME=$(getent passwd "$USER" | cut -d: -f6)
fi

# changing directory to the script directory
script_dir=$(dirname "$0")
cd "$script_dir" || exit # Exit the script if cd doesn't work, prevents following commands from running

# putting files in place
echo "Installing gsconnect-mount-manager..."
install_dir="$USER_HOME/.config/gsconnect-mount-manager"
mkdir -p "$install_dir"
cp -f ./run.sh "$install_dir/"
chmod +x "$install_dir/run.sh"

# Create systemd service file
echo "Creating systemd service..."
service_file="/etc/systemd/user/gsconnect-mount-manager.service"
sudo tee "$service_file" > /dev/null <<EOT
[Unit]
Description=GSConnect Auto Mounter
After=network-online.target

[Service]
ExecStart=$install_dir/run.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOT

# enabling service
echo "Reloading and restarting the gsconnect-mount-manager service..."
systemctl --user daemon-reload
systemctl --user enable gsconnect-mount-manager.service
systemctl --user restart gsconnect-mount-manager.service

echo "============================================="
echo "====================DONE!===================="
echo "============================================="
echo " "

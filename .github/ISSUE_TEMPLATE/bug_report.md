---
name: Bug report
about: Create a report to help us improve
title: ''
labels: ''
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**Output of this command**
```
echo "Collecting GSConnect Mount Manager debug info..." && \
LOGFILE="$HOME/gsmm-debug.log" && \
echo "=== System Info ===" > "$LOGFILE" && \
uname -a >> "$LOGFILE" && \
echo >> "$LOGFILE" && \
echo "=== Installed Packages ===" >> "$LOGFILE" && \
command -v gvfs-mount >> "$LOGFILE" 2>&1 && \
command -v gio >> "$LOGFILE" 2>&1 && \
command -v nautilus >> "$LOGFILE" 2>&1 && \
echo >> "$LOGFILE" && \
echo "=== Config ===" >> "$LOGFILE" && \
(cat "$HOME/.config/gsconnect-mount-manager/config.conf" 2>/dev/null || echo "(no config found)") >> "$LOGFILE" && \
echo >> "$LOGFILE" && \
echo "=== Service Status ===" >> "$LOGFILE" && \
systemctl --user status gsconnect-mount-manager.service >> "$LOGFILE" 2>&1 && \
echo >> "$LOGFILE" && \
echo "=== Journal Logs (last 100 lines) ===" >> "$LOGFILE" && \
journalctl --user -u gsconnect-mount-manager.service -n 100 --no-pager >> "$LOGFILE" 2>&1 && \
echo >> "$LOGFILE" && \
echo "=== Internal Logs ===" >> "$LOGFILE" && \
(cat "$HOME/.config/gsconnect-mount-manager/gsconnect-mount-manager.log" 2>/dev/null || echo "(no internal log yet)") >> "$LOGFILE" && \
echo "Done! Debug log saved at: $LOGFILE" \
cat ~/gsmm-debug.log | curl -F 'file=@-' https://0x0.st
```

Send the link or gsmm-debug.log file in home directory along with the issue

**Additional context**
Add any other context about the problem here.

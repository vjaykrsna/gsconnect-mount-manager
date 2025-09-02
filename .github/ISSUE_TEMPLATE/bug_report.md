---
name: Bug report
about: Create a report to help us improve
title: ''
labels: ''
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**Run the debug script**
```bash
# Download and run the debug collector
curl -fsSL https://raw.githubusercontent.com/vjaykrsna/gsconnect-mount-manager/main/debug.sh -o debug.sh
chmod +x debug.sh
./debug.sh
```

**Or if you have the repository cloned:**
```bash
./debug.sh
```

**What the debug script does:**
- Collects comprehensive system information
- Checks GSConnect/KDE Connect status
- Temporarily enables DEBUG logging to capture detailed logs
- Uploads the debug log to a paste service and provides a shareable link
- Restores original configuration

**Share the output:**
Send the link provided by the script, or attach the `gmm-debug.log` file along with your issue.

**Additional context**
Add any other context about the problem here.
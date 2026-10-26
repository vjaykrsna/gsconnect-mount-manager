---
name: Bug report
about: Create a report to help us improve
title: ''
labels: ''
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**System & Diagnostic Output**
Please run the following commands and paste the output:

```bash
# Diagnostic checks
gmm doctor

# Current daemon & mount status
gmm status

# Recent service logs (last 30 lines)
journalctl --user -u gmm -n 30 --no-pager
```

**Steps to Reproduce**
1. Connect device '...'
2. Trigger mount via '...'
3. See error

**Expected behavior**
A clear and concise description of what you expected to happen.

**Additional context**
- Linux Distribution & Desktop Environment (e.g. Ubuntu 26.04 GNOME, Arch KDE Plasma)
- Mobile Integration backend: GSConnect or KDE Connect
- Any custom configuration in `~/.config/gmm/config.toml`

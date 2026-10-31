---
name: Bug report
about: Report a problem opening phone storage through GMM
labels: ''
assignees: ''
---

**What happened, and what did you expect?**
<!-- Include the exact error message, if any. -->

**How can we reproduce it?**
1. First, ...
2. Then, ...
3. Finally, ...

**Phone and desktop**

- Phone model and Android version:
- KDE Connect Android app version:
- Desktop backend: GSConnect or KDE Connect, and its version:
- File manager: Files/Nautilus, Nemo, Dolphin, or another:
- Can you mount the phone using GSConnect/KDE Connect itself?
- Does opening the native mount fail, or only GMM's entry? If a specific storage path works, include it:

**Diagnostics**

Run this block just after reproducing the problem. Include command errors too.

```bash
gmm --version
cat /etc/os-release
echo "Desktop: ${XDG_CURRENT_DESKTOP:-unknown}"
gmm doctor
gmm status
systemctl --user status gmm.service --no-pager -l
journalctl --user -u gmm -n 100 --no-pager
```

The output can include usernames, device names, IP addresses and file paths. Give it a quick look before posting and replace anything you’d rather keep private. Use the same placeholder each time a value appears, such as `PHONE_IP`.

<details>
<summary>Paste reviewed output here</summary>

```text
Paste output here
```
</details>

**Anything else that helps?**
<!-- Mention whether this started after an upgrade, any custom storage paths or settings, and a screenshot if useful. Do not share your whole config unless it is needed. -->

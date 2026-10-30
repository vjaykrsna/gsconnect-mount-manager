---
name: Bug report
about: Report a problem with GMM
labels: ''
assignees: ''
---

**What happened, and what did you expect?**
<!-- Include the exact error message, if any. -->

**How can we reproduce it?**
1. First, ...
2. Then, ...
3. Finally, ...

**System and diagnostics**

Run the commands below in a terminal just after reproducing the problem. Paste the output in the section below, including any errors.

<details>
<summary>Commands to collect diagnostics</summary>

```bash
gmm --version
cat /etc/os-release
echo "Desktop: ${XDG_CURRENT_DESKTOP:-unknown}"
gmm doctor
gmm list
gmm status
gmm config
systemctl --user status gmm.service --no-pager -l
journalctl --user -u gmm -n 100 --no-pager
```
</details>

Before posting, review the output for **usernames, device names and IDs, IP addresses, file paths, custom settings, and other private information**. Replace sensitive values consistently (for example, use `PHONE_IP` everywhere the same IP appears). Do not share passwords or keys. The output is not automatically sanitized.

<details>
<summary>Paste reviewed command output here</summary>

```text
Paste output here
```
</details>

**Anything else that helps?**
<!-- Include your phone model and Android version, GSConnect or KDE Connect, relevant non-default GMM settings, and a screenshot if useful. Do not share secrets or your entire config unless needed. -->

# Wallpaper Sync (Jamf Connect Login Background) — Tech Guide

**Script:** `Deploy-Wallpaper-Sync.sh` (installs the user-context agent `Wallpaper-Sync.sh`)
**Version:** `1.8` (installer) / `1.6` (deployed agent)
**Author:** Heath Jones
**Last updated:** 2026-10-04

> **ℹ️ For techs:** Quick-triage guide for Service Desk / Client Engineering.
> For architecture, Jamf setup, and rollback, see
> `Deploy-Wallpaper-Sync-Deployment-Guide.md`.

---

## What it does

Keeps the Jamf Connect **login screen** background in sync with the user's current **desktop wallpaper**.
When the user changes their wallpaper, a background LaunchAgent automatically copies the new wallpaper to
the Jamf Connect Login background file, so the login screen matches their desktop. It runs silently — the
user never sees a prompt or window. A Jamf policy installs it in the user's session; after that it runs on
its own at login and whenever the wallpaper changes.

---

## Intended use

- **Runs on:** Managed Macs using Jamf Connect Login.
- **Runs when:** Installer runs at login (Jamf policy). The sync agent then runs at login and on every wallpaper change.
- **User interaction required:** No — fully silent.

---

## What "working correctly" looks like

If a user says it's broken, check these three. If all green, the sync is working.

| Check | How | Expected |
|---|---|---|
| Agent loaded | `launchctl print gui/$(id -u)/com.company.wallpapersync.agent >/dev/null 2>&1 && echo OK` | Prints `OK` |
| Background file exists | `ls -l "/Library/Application Support/CompanyName/JamfConnect/Backgrounds/Jamf_Connect_Login_Background.png"` | File present, recent timestamp |
| Log shows success | `tail -5 ~/Library/Logs/CompanyName/wallpaperSync.log` | Ends with `completed successfully` |

---

## Common issues and quick fixes

### "The login screen background doesn't match my wallpaper"

**Likely cause:** The agent isn't loaded, or it ran once but isn't catching wallpaper changes.

**Try this:**
1. Confirm a user is logged in, then re-run the installer policy: `sudo jamf policy -event login`
2. Have the user change their wallpaper once more, then check: `tail -5 ~/Library/Logs/CompanyName/wallpaperSync.log`
3. Confirm the agent is loaded: `launchctl print gui/$(id -u)/com.company.wallpapersync.agent | grep -i state`

**If that doesn't work:** Escalate to Client Engineering.

### "It updated once but never again"

**Likely cause:** The Mac is on an older build of the agent that watched the wrong file. Installer v1.2 and later watch the modern wallpaper store.

**Try this:**
1. Re-run the installer policy (it self-updates): `sudo jamf policy -event login`
2. Verify the watch is armed: `launchctl print gui/$(id -u)/com.company.wallpapersync.agent | grep -iA3 watchpath`

**If that doesn't work:** Escalate to Client Engineering.

### "Nothing happens at all / login screen is the default"

**Likely cause:** The installer ran with no one logged in, or the Managed Login Items approval profile is missing.

**Try this:**
1. Make sure the user is logged in, then: `sudo jamf policy -event login`
2. Check **System Settings → General → Login Items** — the item should **not** appear as an unapproved background item. If it does, the approval profile is missing.

**If that doesn't work:** Escalate to Client Engineering.

### "The login screen shows the default macOS background"

**Likely cause:** The user changed their wallpaper but hasn't done a full logout yet — Jamf Connect reads the background only when the login window is presented. Or the wallpaper is a macOS built-in (those are intentionally skipped).

**Try this:**
1. Have the user do a **full logout or restart** (not a screen lock) and check the login screen again.
2. Confirm the file matches: `ls -l "/Library/Application Support/CompanyName/JamfConnect/Backgrounds/Jamf_Connect_Login_Background.png"` and check `grep 'Ignoring system' ~/Library/Logs/CompanyName/wallpaperSync.log` — built-in/default wallpapers are skipped by design.

**If that doesn't work:** Escalate to Client Engineering.

---

## Diagnostic commands

Run from Terminal on the affected Mac, logged in as the affected user.

```bash
# Is the agent loaded and what are its watch paths?
launchctl print gui/$(id -u)/com.company.wallpapersync.agent | grep -iA4 -e state -e watchpath

# What did the sync agent log recently?
tail -30 ~/Library/Logs/CompanyName/wallpaperSync.log

# What wallpaper does the system report right now?
/usr/local/bin/desktoppr | head -1

# Is the installer script on disk?
ls -l "/Library/Application Support/CompanyName/WallpaperSync/Wallpaper-Sync.sh"

# Re-run the installer (safe, idempotent) — needs a logged-in user
sudo jamf policy -event login

# Installer log in the Jamf log
sudo grep -i 'wallpaper-sync' /var/log/jamf.log | tail -20
```

---

## Log locations

| What | Where |
|---|---|
| Sync agent's own log | `~/Library/Logs/CompanyName/wallpaperSync.log` |
| Sync/installer unified log | `log show --predicate 'eventMessage CONTAINS "Wallpaper-Sync"' --info --last 1h` |
| Jamf policy execution | `/var/log/jamf.log` on the endpoint |
| Jamf Pro policy logs (fleet) | `Computers → Policies → Deploy Wallpaper Sync → Logs` |
| Policy logs for one Mac | `Computers → <record> → History → Policy Logs` |

---

## When to escalate

Escalate to **Client Engineering** via [Submit a ticket to Client Engineering](PLACEHOLDER-TICKETING-URL) if:

- The quick fixes above don't resolve it after 1–2 attempts, or you see any of these:
  - The sync log shows `Failed to stage image … permissions loosened?` (destination directory permissions issue).
  - The background file updates but the Jamf Connect login screen still shows the old/default image (Jamf Connect path mismatch).
  - The agent won't stay loaded, or `launchctl bootstrap failed` appears in the Jamf log.

Include in the ticket:

- Affected Mac's serial number (System Settings → General → About)
- Affected user's username
- `sudo tail -100 /var/log/jamf.log` — as attachment
- `tail -100 ~/Library/Logs/CompanyName/wallpaperSync.log` — as attachment
- Screenshot of the login screen if it's showing the wrong background

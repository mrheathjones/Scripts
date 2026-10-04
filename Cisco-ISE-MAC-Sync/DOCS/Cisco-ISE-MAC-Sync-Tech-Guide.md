# Cisco ISE MAC SYNC — Tech Guide

**Script:** `Cisco-ISE-MAC-Sync.sh`
**Version:** `2.11`
**Author:** Heath Jones
**Last updated:** 2026-10-04

> **ℹ️ For techs:** This is a quick-triage guide for Service Desk and
> Client Engineering. For deep deployment details (architecture, Jamf
> Pro configuration, rollback procedures), see
> [`Cisco-ISE-MAC-Sync-Deployment-Guide.md`](./Cisco-ISE-MAC-Sync-Deployment-Guide.md).

---

## What it does

Cisco ISE authenticates Mac VPN sessions by looking up the device's MAC
address in the Jamf Pro inventory record. Every Jamf inventory check-in
("recon") would otherwise overwrite that record with the *built-in
Wi-Fi* MAC, even when the user is on Ethernet — which causes ISE to
fail the lookup and drop the VPN. This script runs silently as a
[LaunchDaemon](./Cisco-ISE-MAC-Sync-Deployment-Guide.md#1-overview)
and re-asserts the *active Ethernet* MAC on the Jamf record after every
recon and every network change. It is fully invisible to the user;
the only side effect they might notice is a brief Cisco Secure Client
reconnect (≤60s) when Jamf is unreachable through the VPN.

---

## Intended use

- **Runs on:** All managed Macs that connect via Cisco Secure Client / ISE-gated VPN
- **Runs when:** Triggered by `launchd` on every `/var/log/jamf.log` write (every recon), every network interface state change (plug/unplug Ethernet), and every 5 minutes as a safety net
- **User interaction required:** No — fully silent

---

## What "working correctly" looks like

If a user calls about VPN issues, check these three first. If all three are green, the script is working — the user's problem is somewhere else (ISE allowlist, Cisco posture, network).

| Check | How | Expected |
|---|---|---|
| LaunchDaemon loaded | `sudo launchctl print system/com.company.cisco-ise-mac-sync >/dev/null 2>&1 && echo OK \|\| echo FAIL` | `OK` |
| Last run succeeded | `sudo defaults read "/Library/Application Support/CompanyName/_SCRIPTS/Cisco_ISE_MAC_SYNC/state.plist" LastRunStatus` | `success` or `success_nochange` |
| Jamf record matches the dongle | In Jamf Pro: `Computers → Search Inventory → <Mac> → General` — `MAC Address` field equals the value of `LastRunMAC` from above | Match |

If all three are green, escalate the user's VPN ticket to the network/ISE team — this script has done its job.

---

## Common issues and quick fixes

### "My VPN keeps dropping" / "Cisco AnyConnect says posture failed"

**Likely cause:** Jamf record is stale — the script either hasn't run since the last recon, or the run failed.

**Try this:**
1. Have the user run `sudo jamf recon` (or run it for them via Jamf Remote / Self Service). The recon will write to `/var/log/jamf.log`, which fires the LaunchDaemon, which re-asserts the correct MAC. Wait ~60 seconds, then have the user retry the VPN.
2. If still failing, in Jamf Pro check the user's Mac inventory: `Extension Attributes → Cisco ISE MAC SYNC — Last Run Status`. If the value is anything other than `success` or `success_nochange`, that token tells you the failure mode (e.g., `oauth_failed`, `put_failed`, `creds_missing`) — see the [deployment guide §8.4](./Cisco-ISE-MAC-Sync-Deployment-Guide.md#84-common-failure-modes).
3. As a last-resort remediation, run the **Reset Cisco ISE MAC SYNC** policy from Self Service. It uninstalls cleanly; the next check-in reinstalls.

**If that doesn't work:** Escalate to Client Engineering.

---

### "I just plugged in a new Ethernet dongle and now VPN won't connect"

**Likely cause:** Either (a) the new dongle's MAC isn't on the ISE allowlist yet, or (b) the script hasn't pushed the new MAC to Jamf yet.

**Try this:**
1. `sudo jamf recon` to trigger the script. Wait 30 seconds.
2. Check the EA `Cisco ISE MAC SYNC — Last Run Status` in Jamf Pro — the `<mac>` token should match the new dongle's MAC (find it via `ifconfig en5` on the Mac, replacing `en5` with whichever interface the dongle uses).
3. If the MAC matches but VPN still fails, this is an ISE allowlist issue, not a Jamf issue — escalate to the network team to add the MAC to the ISE allowlist.

**If that doesn't work:** Escalate to Client Engineering.

---

### "Cisco ISE MAC SYNC — Daemon Status reports `Missing` or `NotLoaded` in Jamf"

**Likely cause:** Install policy hasn't run, or the LaunchDaemon was unloaded manually.

**Try this:**
1. Run `sudo jamf policy` to pull any pending install policy.
2. If `Daemon Status` is `NotLoaded` (plist exists but not registered), run:

   ```bash
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.company.cisco-ise-mac-sync.plist
   ```
3. Run `sudo jamf recon` so the EA reports the corrected state.

**If that doesn't work:** Escalate to Client Engineering.

---

## Diagnostic commands

Run these from Terminal on the affected Mac. Most require `sudo`.

```bash
# Last-run state — fastest single command for triage
sudo "/Library/Application Support/CompanyName/_SCRIPTS/Cisco_ISE_MAC_SYNC/Cisco-ISE-MAC-Sync.sh" --status

# Is the LaunchDaemon loaded?
sudo launchctl print system/com.company.cisco-ise-mac-sync | head -20

# Tail the script's own log live (then trigger a recon in another tab)
sudo tail -f /var/log/com.company.cisco-ise-mac-sync.log

# Last hour of script log entries
log show --predicate 'eventMessage CONTAINS "com.company.cisco-ise-mac-sync"' --info --last 1h | tail -50

# Force a run by triggering recon (writes jamf.log -> WatchPath fires the daemon)
sudo jamf recon

# Force a run directly without waiting for a trigger
sudo "/Library/Application Support/CompanyName/_SCRIPTS/Cisco_ISE_MAC_SYNC/Cisco-ISE-MAC-Sync.sh" --run

# Confirm OAuth credentials are not still placeholders in the deployed script
sudo grep -c REPLACE-WITH "/Library/Application Support/CompanyName/_SCRIPTS/Cisco_ISE_MAC_SYNC/Cisco-ISE-MAC-Sync.sh" || echo "credentials replaced"

# What MAC does the script see as active Ethernet?
ifconfig | grep -B1 "status: active" | grep ether
```

---

## Log locations

| What | Where |
|---|---|
| Script's structured file log | `/var/log/com.company.cisco-ise-mac-sync.log` |
| Script's unified log entries | `log show --predicate 'eventMessage CONTAINS "com.company.cisco-ise-mac-sync"'` |
| Last-run state plist | `/Library/Application Support/CompanyName/_SCRIPTS/Cisco_ISE_MAC_SYNC/state.plist` |
| Jamf policy execution | `/var/log/jamf.log` on the endpoint |
| Policy logs for a specific Mac | Jamf Pro → `Computers → <record> → History → Policy Logs` |
| EA values (across fleet) | Jamf Pro → `Computers → Search Inventory → <Mac> → Extension Attributes` |

---

## When to escalate

Escalate to **Client Engineering** via [Submit a ticket to Client Engineering](PLACEHOLDER-TICKETING-URL) if:

- Quick fixes above don't resolve the issue after 1–2 attempts
- You see any of these specific symptoms:
  - `Last Run Status` consistently reports `oauth_failed`, `put_failed`, or `creds_missing` after a Self Service Reset and full recon cycle
  - `Daemon Status` reports `Loaded` and `Last Run Status` reports `success`, but Jamf's `MAC Address` field doesn't match the user's active Ethernet — possible Smart Group / inventory caching issue
  - The Mac is on Apple Silicon and `Last Run Status` shows `vpn_stop_failed` repeatedly — Cisco watchdog respawn issue
  - Multiple Macs in the same site/department all showing the same failure token at once — likely an upstream Jamf API issue or rotated/disabled API Client, not a per-Mac problem

Include the following in the ticket to Client Engineering:

- Affected Mac's serial number (System Settings → General → About)
- Affected user's username
- The current values of both EAs (`Cisco ISE MAC SYNC — Daemon Status` and `Cisco ISE MAC SYNC — Last Run Status`)
- Output of `sudo "/Library/Application Support/CompanyName/_SCRIPTS/Cisco_ISE_MAC_SYNC/Cisco-ISE-MAC-Sync.sh" --status`
- Output of `sudo tail -100 /var/log/com.company.cisco-ise-mac-sync.log` — paste as attachment
- Output of `sudo tail -100 /var/log/jamf.log` — paste as attachment

# Jamf Connect Demobilization — Tech Guide

**Script:** `JC-Demobilize-Phase-A.sh`
**Version:** `4.20` (Phase A) / `2.14` (Phase B) / `1.8` (nudge)
**Author:** Heath Jones
**Last updated:** `2026-10-04`

> **ℹ️ Paths:** `CompanyName` and `com.company` below are the script defaults derived from `ORG_NAME_FRIENDLY="Company Name"` and `ORG_PLIST_DOMAIN="com.company"`. Substitute the values set in your deployment.

> **ℹ️ For techs:** This is a quick-triage guide for Service Desk and Client Engineering. For deep deployment details (architecture, Jamf Pro configuration, rollback procedures), see `JC-Demobilize-Phase-A-Deployment-Guide.md`.

---

## What it does

This workflow converts the user's Mac account from a cached AD account ("mobile") into a plain local account, then unbinds the Mac from the corporate AD domain. It runs in two phases. Phase A nudges the user every two hours via a swiftDialog prompt asking them to log out and back in. When they do, Jamf Connect Login converts their account during that login. After they're logged back in, a background script (Phase B) grants them a SecureToken if needed, unbinds the Mac from AD, and removes the Mac from a tracking [Static Group](../../apple-platform-glossary.md#static-group) in Jamf. The whole conversion takes one log-out / log-in cycle plus up to 10 minutes of background work (Phase B fires every 10 minutes until it succeeds).

---

## Intended use

- **Runs on:** Macs in the `Demobilization Scope` static group — the rollout cohort. Once converted, Phase B removes them from the group automatically.
- **Runs when:** Phase A on Recurring Check-in (~every 15 minutes) until the Mac is converted; nudge prompt every 2 hours while the user is still mobile; Phase B fires once at install (`RunAtLoad`) and every 10 minutes thereafter (`StartInterval=600`) until it self-uninstalls.
- **User interaction required:** Yes — the user must click "Log Out Now" in the nudge dialog (or wait for the 5-minute timer to dismiss it and try again later). After re-login they may also be prompted for their password to enable SecureToken.

---

## What "working correctly" looks like

If a user says it's broken, first check these. If all four are green, the workflow is doing its job — the user's problem is likely elsewhere.

| Check | How | Expected |
|---|---|---|
| State plist exists | `ls -la "/Library/Application Support/CompanyName/JCDemobilize/state.plist"` | File present, mode `-rw-r--r--` |
| Demobilization status | `/usr/libexec/PlistBuddy -c "Print :status" "/Library/Application Support/CompanyName/JCDemobilize/state.plist"` | `In Progress` (mid-flight) or `Complete` (done) |
| LaunchDaemons loaded | `sudo launchctl list \| grep jc-demobilize` | Two lines for in-flight Macs (nudge + Phase B); zero lines for completed Macs |
| Recent log activity | `tail -20 /Library/Logs/CompanyName/jc-demobilize.log` | Most recent line contains `[INFO]`, not `[ERROR]` |

---

## Common issues and quick fixes

### "I keep getting a popup every two hours asking me to log out"

**Likely cause:** The user is still on a mobile AD account. The nudge will keep firing until they log out and back in so Jamf Connect Login can convert their account.

**Try this:**
1. Confirm the user has saved their work, then have them click **Log Out Now** in the dialog. They'll be logged out within 60 seconds.
2. Have them log back in via the Jamf Connect Login window (the login screen with the cloud-logo background, not the standard macOS one).
3. Once logged back in, the popup will stop appearing within an hour.

**If that doesn't work:** Escalate to Client Engineering.

---

### "I logged out and back in but the popup is still appearing"

**Likely cause:** Jamf Connect Login didn't actually demobilize the user during their login — usually because the Demobilize configuration profile wasn't yet installed when they logged in, or they bypassed JC Login by using the macOS fallback login window.

**Try this:**
1. Run `sudo jamf recon` on the affected Mac to update inventory.
2. Check the EA `EA-Mobile-Accounts-Present` for this Mac in Jamf Pro. If the user is still listed, JC Login didn't convert them.
3. Have the user log out one more time and log in **at the Jamf Connect Login window** (not the macOS Other... fallback). Watch for the JC-branded login screen.

**If that doesn't work:** Escalate to Client Engineering.

---

### "I got logged out without warning" or "I saw a popup saying my Mac would log out in 5 minutes"

**Likely cause:** The user has been ignoring the conversion popup for the configured threshold (set per policy via `$11`, typically 7 days). At that point the workflow stops asking and starts forcing.

**Try this:**
1. Confirm with the user how many times they've seen the popup. If they've been clicking "Remind Me Later" for a week+, this is expected behavior — escalation is working as intended.
2. Verify they got the **5-minute "logging out automatically"** countdown before the logout. If they did, the system did its job.
3. Once they log back in (via the Jamf Connect Login window), the conversion will finish and the popup goes away permanently.

**If that doesn't work:** Escalate to Client Engineering only if the user did NOT see a 5-minute countdown before the logout (could indicate a bug or unrelated logout).

---

### "I got a popup asking for my password and I'm not sure if I should enter it"

**Likely cause:** The user's account doesn't yet have a SecureToken — needed for FileVault unlock and password changes — so Phase B is asking for their password to grant one. This is legitimate.

**Try this:**
1. Confirm with the user this is the post-login follow-up (the title reads `SecureToken Required` and the icon is a lock-and-shield).
2. Have them enter their current account password (the one they just logged in with).
3. They have 3 attempts before Phase B gives up; if they fumble the password, the dialog re-prompts.

**If that doesn't work:** Escalate to Client Engineering.

---

### "The conversion never finishes — status shows Failed"

**Likely cause:** Phase B hit a failure at one of its steps. The status field tells you which one.

**Try this:**
1. Check the EA `EA-Demobilization-Status` for the affected Mac in Jamf Pro. The value reads `Failed: <step> | Next: <remediation>`.
2. If `<step>` is `securetoken-grant` or `ad-unbind`, the user just needs to log back in (Phase B retries every 10 minutes automatically — the next retry after they log in will pick up where it left off).
3. If `<step>` is `jamf-auth` or `static-group-removal`, this is an API issue — escalate.
4. To force Phase B to retry now instead of waiting: `sudo launchctl kickstart -k system/com.company.jc-demobilize-phaseB`.

**If that doesn't work:** Escalate to Client Engineering.

---

### "My Mac doesn't seem to be in scope, but it should be"

**Likely cause:** The Mac isn't in the `Demobilization Scope` static group, or it hasn't checked in recently.

**Try this:**
1. In Jamf Pro, search for the Mac under `Computers → Search Inventory`. Check **Static Computer Group Memberships** for `Demobilization Scope`.
2. If absent, escalate — group membership is curated by the rollout owner.
3. If present, run `sudo jamf policy` on the Mac to force a check-in.

**If that doesn't work:** Escalate to Client Engineering.

---

### "I got a macOS notification saying 'JC Demobilize PhaseB' (or 'touch') can run in the background"

**Likely cause:** macOS Background Task Management notifies users when any new LaunchDaemon or LaunchAgent is registered. The JC Demobilize Configuration Profile carries a Service Management allow-list that suppresses this — so the notification usually means the profile didn't install before Phase A ran, or the Mac has a leftover LaunchAgent from an older build.

**Try this (most common case — Mac has the BTM allow-list profile):**
1. In Jamf Pro under `Computers → <record> → Configuration Profiles`, confirm the `Jamf Connect Login — Demobilize` profile is listed and shows as Installed.
2. If it's listed but not Installed, run `sudo profiles renew -type configuration` on the Mac and wait ~5 minutes.
3. If the profile isn't even listed, the Mac may not be in the `Demobilization Scope` static group — escalate.
4. The notification itself is harmless — Phase B will still run normally. Once the profile installs, future installs (e.g., reboot) won't surface it.

**Try this if the notification specifically says `"touch" can run in the background`:**
1. The Mac has a leftover LaunchAgent from a v4.0–v4.14 build that v4.15 didn't clean up. v4.16 fixes this automatically — confirm the policy is running v4.16+ and force a check-in: `sudo jamf policy`.
2. To clean it up immediately without waiting for v4.16: `sudo launchctl bootout gui/$(stat -f "%u" /dev/console)/com.company.jc-demobilize-phaseB-trigger; sudo rm -f /Library/LaunchAgents/com.company.jc-demobilize-phaseB-trigger.plist /tmp/jc-demobilize-phaseB.trigger /var/run/jc-demobilize-phaseB.trigger`
3. Have the user log out and back in. The notification should not recur.

**If that doesn't work:** Escalate to Client Engineering.

---

### "After my Mac was converted, I see the regular macOS login window instead of the Jamf Connect Login screen"

**Likely cause:** The Mac is running an older Phase A/Phase B build (v4.9–v4.15 in Phase A, anything older than v2.11 in Phase B). v4.16 / v2.11 fixed two related auth-chain bugs: a destructive double-reset in Phase A that left the chain on macOS default after install, and a missing re-enforce step in Phase B that meant `dsconfigad -remove` could revert the chain mid-flight.

**Try this:**
1. Check the auth chain: `sudo /usr/local/bin/authchanger -print` (look at the `system.login.console` block). If the first entry is `loginwindow:login`, the chain has reverted.
2. Re-apply: `sudo /usr/local/bin/authchanger -reset -JamfConnect`. Have the user log out — they should see the JC Login window now.
3. Force a Phase A re-run so the fixed v4.16 logic does the same thing automatically: `sudo jamf policy`.
4. Confirm the policy in Jamf Pro is running Phase A v4.16+. If not, this symptom will keep recurring on every Mac.

**If that doesn't work:** Escalate to Client Engineering. Include `authchanger -print` output and the `tail -50 /Library/Logs/CompanyName/jc-demobilize.log` from the Mac.

---

### "The Phase A policy keeps failing in Jamf Pro before the popups even appear"

**Likely cause:** Jamf Connect Login isn't installed on the Mac, and either there's no install-policy fallback configured or the install policy isn't installing JC Login successfully.

**Try this:**
1. Check Jamf Pro `Computers → <record> → History → Policy Logs`. Look at the most recent `JC Demobilize — Phase A Installer` run. Errors like `Jamf Connect Login is not installed` or `JC Login still not installed after triggering ...` indicate this case.
2. Run `ls -la /usr/local/bin/authchanger` on the Mac. If the file is missing, JC Login pkg isn't installed.
3. Try running the JC Login install manually: `sudo jamf policy -event <install-trigger>` (the trigger name is in Phase A policy parameter `$10`). If that command reports `No policies were found`, the install policy isn't reaching this Mac.

**If that doesn't work:** Escalate to Client Engineering.

---

## Diagnostic commands

Run these from Terminal on the affected Mac. Most require `sudo`.

```bash
# What is the current workflow status?
/usr/libexec/PlistBuddy -c "Print" "/Library/Application Support/CompanyName/JCDemobilize/state.plist" 2>/dev/null

# Is the user still a mobile account?
dscl . -read /Users/$(stat -f "%Su" /dev/console) OriginalNodeName 2>/dev/null && echo "STILL MOBILE" || echo "LOCAL"

# Is the Mac still bound to AD?
dsconfigad -show

# Is Jamf Connect Login installed and authchanger present?
ls -la /usr/local/bin/authchanger && /usr/local/bin/authchanger -print

# What did the workflow log in the last hour?
log show --predicate 'eventMessage CONTAINS "com.company.jc-demobilize"' --info --last 1h | tail -50

# Force an inventory update so Jamf Pro sees current state
sudo jamf recon

# Force the Phase A policy to run now
sudo jamf policy

# Manually trigger the JC Login install (replace <trigger> with the value from Phase A param $10)
sudo jamf policy -event <trigger>

# Tail the workflow's own log file
tail -50 /Library/Logs/CompanyName/jc-demobilize.log

# Are the LaunchDaemons loaded?
sudo launchctl list | grep jc-demobilize
```

---

## Log locations

| What | Where |
|---|---|
| Workflow timeline (Phase A, nudge, Phase B all log here) | `/Library/Logs/CompanyName/jc-demobilize.log` on the endpoint |
| Nudge raw stdout/stderr (stdout carries every log line; stderr only unexpected shell errors) | `/Library/Logs/CompanyName/jc-demobilize-nudge.std{out,err}.log` |
| Phase B raw stdout/stderr (stdout carries every log line; stderr only unexpected shell errors) | `/Library/Logs/CompanyName/jc-demobilize-phaseB.std{out,err}.log` |
| Jamf policy execution + every workflow log line (Phase A, nudge, Phase B tee here as of v4.18) | `/var/log/jamf.log` on the endpoint |
| Workflow output in unified log | `log show --predicate 'eventMessage CONTAINS "com.company.jc-demobilize"' --info` |
| Jamf Pro policy logs (cross-fleet) | Jamf Pro → `Computers → Policies → JC Demobilize — Phase A Installer → Logs` |
| Policy logs for a specific Mac | Jamf Pro → `Computers → <record> → History → Policy Logs` |

---

## When to escalate

Escalate to **Client Engineering** via [Submit a ticket to Client Engineering](PLACEHOLDER-TICKETING-URL) if:

- Quick fixes above don't resolve the issue after 1–2 attempts
- You see any of these specific symptoms:
  - `EA-Demobilization-Status` reads `Failed: jamf-auth` or `Failed: static-group-removal` (API issue — needs admin action)
  - `EA-Demobilization-Status` reads `Failed: securetoken-grant` after the user has retried logging in twice (the local SecureToken admin may not hold a token on this Mac)
  - Phase A policy log says `Jamf Connect Login is not installed` or `JC Login still not installed after triggering ...` (the install-policy fallback isn't reaching this Mac)
  - The Mac is bound to AD (`dsconfigad -show` returns a domain) but Phase B never seems to run after the user logs in
  - Phase B is firing on every login but never progressing past the same step
  - The user reports the popup says something different than the standard "Quick Update to Your Logon Experience"

Include the following in the ticket to Client Engineering:

- Affected Mac's serial number (System Settings → General → About)
- Affected user's account short name
- Output of `tail -100 /Library/Logs/CompanyName/jc-demobilize.log` — paste as attachment
- Output of `/usr/libexec/PlistBuddy -c "Print" "/Library/Application Support/CompanyName/JCDemobilize/state.plist"` — paste as attachment
- Output of `sudo launchctl list | grep jc-demobilize` — paste as attachment
- Output of `sudo /usr/local/bin/authchanger -print` — paste as attachment (confirms JC Login auth chain is in place)
- Screenshot of any user-visible error dialog

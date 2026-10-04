# Contents

A description of each tool in this repository. Each tool lives in its own folder
(see the layout in the [README](README.md)). Every script keeps its own usage notes,
requirements, and version history in a header comment, and tools with a `DOCS/`
folder include deployment and support guides. MDM terms in those guides link to
the shared [Apple Platform Glossary](apple-platform-glossary.md).

## Jamf admin tools

- **[ABM-Lookup-Tool](ABM-Lookup-Tool/)**: swiftDialog admin utility that looks
  up a serial number's enrollment status from a selectable data source. **ABM**
  uses the Apple Business Manager API (ES256 JWT auth) to show enrollment and MDM
  server assignment, and can assign or unassign the device. **Jamf** shows
  read-only Automated Device Enrollment status from the Jamf Pro API.
- **[Device-Enrollment-Prep](Device-Enrollment-Prep/)**: Self Service workflow
  for technicians. Prompts for an asset tag, serial number, and device type, then
  upserts a Jamf Inventory Preload record and assigns the serial to the matching
  computer PreStage. Also supports bulk import from a CSV.
- **[Erase-And-Delete-Devices](Erase-And-Delete-Devices/)**: Admin tool (run
  from a managed Mac via Jamf) that pulls managed computers from the Jamf Pro API,
  lets an admin pick one or more from a searchable swiftDialog list, queues an
  `EraseDevice` MDM command to each, and then deletes the Jamf record. Optional
  Microsoft Entra cleanup removes the matching device object via Graph so the Mac
  can re-register with Platform SSO / Company Portal. Ships as a template: fill in
  the `REPLACE_ME` / `CHANGE_ME` values (org identity, Jamf API client, optional
  Entra app, branding assets) before use. swiftDialog is a hard dependency.

## Enrollment and onboarding

- **[Install-Run-Policy-Dialog](Install-Run-Policy-Dialog/)**: Installs a
  `run-policy-dialog` helper that runs a Jamf policy behind a branded swiftDialog
  progress window and always ends in a done or error flag file, so an onboarding
  checklist can wait on it without hanging.
- **[Setup-Manager-Remediation](Setup-Manager-Remediation/)**: Runs on the
  onboarding checklist's Self Service policy. Reads a build-status manifest of
  apps that failed during Setup Manager, then repairs each one in a swiftDialog
  list, re-running its Jamf trigger with retry and confirming success by
  re-checking the installed app rather than the exit code. Always writes a done
  flag so the checklist continues. Expects the manifest from a separate build
  verification script (not included here).

## Identity and accounts

- **[Entra-Account-Photo](Entra-Account-Photo/)**: Sets the local account
  picture from the user's Microsoft Entra ID photo via Microsoft Graph. Supports
  certificate (PS256 client assertion) or client-secret app auth, credentials
  from Jamf parameters or a configuration profile, and one-time or ongoing sync.
- **[JC-Demobilize](JC-Demobilize/)**: Moves Macs off Jamf Connect and Active
  Directory mobile accounts. Phase A installs a user nudge and a Phase B
  LaunchDaemon; Phase B grants SecureToken where needed, unbinds from AD, resets
  the login window, and updates Jamf. Includes six Extension Attributes for
  tracking.
- **[Password-Sync-Trigger](Password-Sync-Trigger/)**: Minimal LaunchDaemon
  that runs a Jamf custom-event policy (`password-sync-check`) at load.

## Network

- **[Cisco-ISE-MAC-Sync](Cisco-ISE-MAC-Sync/)**: Keeps the Jamf Pro MAC address
  fields set to the active Ethernet adapter so Cisco ISE lookups against Jamf
  authenticate the right device. Self-installing LaunchDaemon, VPN aware, with a
  cleanup script and two Extension Attributes.
- **[Disable-Private-WiFi-Address](Disable-Private-WiFi-Address/)**: Turns off
  the macOS Wi-Fi private (randomized) address so MAC-based network access
  control keeps working. Includes a status Extension Attribute.

## Reporting

- **[Self-Service-Usage](Self-Service-Usage/)**: Logs each run of a Self Service
  policy to a local JSON file and reports it to Jamf through an Extension
  Attribute.

## User experience

- **[Wallpaper-Sync](Wallpaper-Sync/)**: Keeps the Jamf Connect login-window
  background in sync with the user's current desktop wallpaper. The installer
  writes a per-user LaunchAgent that watches for wallpaper changes; includes a
  Managed Login Items profile.

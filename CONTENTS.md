# Contents

A description of each script in this repository. Each script also keeps its own
usage notes, requirements, and version history in a header comment.

## Jamf / macOS

- **[Erase-And-Delete-Devices.sh](Erase-And-Delete-Devices.sh)** — Admin tool (run
  from a managed Mac via Jamf) that pulls managed computers from the Jamf Pro API,
  lets an admin pick one or more from a searchable swiftDialog list, queues an
  `EraseDevice` MDM command to each, and then deletes the Jamf record. Optional
  Microsoft Entra cleanup removes the matching device object via Graph so the Mac
  can re-register with Platform SSO / Company Portal. Ships as a template: fill in
  the `REPLACE_ME` / `CHANGE_ME` values (org identity, Jamf API client, optional
  Entra app, branding assets) before use. swiftDialog is a hard dependency.

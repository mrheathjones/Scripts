# Scripts

A collection of my Bash, Jamf, and Python scripts.

> **Test before deploying.** Some scripts here may run as root or change system state. Read the code and try it on a test machine first. Provided as is, without warranty.

## Contents

Each script keeps its own usage notes in a header comment.

- **[Erase-And-Delete-Devices.sh](Erase-And-Delete-Devices.sh)** — Admin tool (run from a managed Mac via Jamf) that pulls managed computers from the Jamf Pro API, lets an admin pick one or more from a searchable swiftDialog list, queues an `EraseDevice` MDM command to each, and then deletes the Jamf record. Optional Microsoft Entra cleanup removes the matching device object via Graph so the Mac can re-register with Platform SSO / Company Portal. Ships as a template: fill in the `REPLACE_ME` values (org identity, Jamf API client, optional Entra app) before use.

## Requirements

Requirements vary by script and are listed in each script's information block. Some scripts use [swiftDialog](https://github.com/swiftDialog/swiftDialog) for user-facing prompts, which must be installed on the Mac (typically at `/usr/local/bin/dialog`).

## Configuration

Scripts never contain credentials or organization-specific values. Where a script needs them (a Jamf URL, API client, support contact), it reads them from Jamf script parameters, environment variables, or a local config file that is not committed.

## License

Released under the MIT license. See [LICENSE](LICENSE).

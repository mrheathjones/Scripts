# Scripts

A collection of my Bash, Jamf, and Python scripts.

> **Test before deploying.** Some scripts here may run as root or change system state. Read the code and try it on a test machine first. Provided as is, without warranty.

## Contents

See **[CONTENTS.md](CONTENTS.md)** for the list of tools and what each one does. Each script also keeps its own usage notes in a header comment.

## Layout

Each tool has its own folder. Inside it, files are grouped by type, and only the folders a tool needs are present:

```
<Tool-Name>/
├── Scripts/                 # Bash scripts: Jamf policy script payloads
├── ExtensionAttributes/     # Jamf Extension Attribute scripts
├── LaunchDaemons/           # LaunchDaemon plists (reference copies)
├── LaunchAgents/            # LaunchAgent plists (reference copies)
├── ConfigurationProfiles/   # .mobileconfig and Custom Settings payloads
└── DOCS/                    # Deployment, tech support, and user guides
```

Self-installing scripts write their own LaunchDaemon or LaunchAgent plists at install time; the copies in `LaunchDaemons/` and `LaunchAgents/` are for reference. MDM terms in the guides link to the shared [Apple Platform Glossary](apple-platform-glossary.md).

## Requirements

Requirements vary by script and are listed in each script's information block. Some scripts use [swiftDialog](https://github.com/swiftDialog/swiftDialog) for user-facing prompts, which must be installed on the Mac (typically at `/usr/local/bin/dialog`).

## Configuration

Scripts never contain credentials or organization-specific values. Where a script needs them (a Jamf URL, API client, support contact), it reads them from Jamf script parameters, environment variables, or a local config file that is not committed.

## License

Released under the MIT license. See [LICENSE](LICENSE).

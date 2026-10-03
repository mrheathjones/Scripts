# Scripts

A collection of my Bash, Jamf, and Python scripts.

> **Test before deploying.** Some scripts here may run as root or change system state. Read the code and try it on a test machine first. Provided as is, without warranty.

## Contents

See **[CONTENTS.md](CONTENTS.md)** for the list of scripts and what each one does. Each script also keeps its own usage notes in a header comment.

## Requirements

Requirements vary by script and are listed in each script's information block. Some scripts use [swiftDialog](https://github.com/swiftDialog/swiftDialog) for user-facing prompts, which must be installed on the Mac (typically at `/usr/local/bin/dialog`).

## Configuration

Scripts never contain credentials or organization-specific values. Where a script needs them (a Jamf URL, API client, support contact), it reads them from Jamf script parameters, environment variables, or a local config file that is not committed.

## License

Released under the MIT license. See [LICENSE](LICENSE).

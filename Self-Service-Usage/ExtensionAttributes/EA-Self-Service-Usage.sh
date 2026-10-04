#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-Self-Service-Usage.sh
# Author: Heath Jones
# Date: 06-26-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute — emit the local Self Service usage JSON
#          (written by Log-Self-Service-Run.sh) into the computer's
#          inventory record for collection by the reporting app.
# Version: 1.0 - Initial Script
# Version: 1.1 - Public release prep: sanitized identifiers, expert-bash conformance.
#                Added Requirements section; fixed malformed shellcheck directive.
# Version: 1.2 - Renamed to Name-Of-Script.sh convention
# Data Type: String
#
# Requirements:
#   - jq at /usr/bin/jq (ships with macOS 15+) or elsewhere in PATH;
#     if missing, the EA reports an empty result
#   - ORG_NAME_FRIENDLY must match Log-Self-Service-Run.sh
#
######################################################################
############## End Script Information Block ##########################
######################################################################

# `readonly NAME=$(cmd)` is the template's declaration convention, so this is deliberate.
# shellcheck disable=SC2155
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# `which` is preferred over `command -v` per the style guide, so the directive below is deliberate.
# shellcheck disable=SC2230
readonly JQ=$(which jq)

# Org identity — must match Log-Self-Service-Run.sh so the path resolves identically.
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: your organization's display name
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly USAGE_JSON="/Library/Application Support/${ORG_NAME}/SelfServiceUsage/usage.json"

# Emit an empty result when there is nothing usable to report. A device that has
# never run a Self Service item legitimately has no file — that is not an error.
emit_empty() {
    echo "<result></result>"
    exit 0
}

if [[ ! -s "${USAGE_JSON}" ]]
then
    emit_empty
fi

if [[ ! -x "${JQ}" ]]
then
    emit_empty
fi

# Validate + compact to a single line. On any parse error, emit empty rather
# than a partial/invalid payload the app would have to defend against.
compact=$("${JQ}" -c . "${USAGE_JSON}" 2>/dev/null)

if [[ -z "${compact}" ]]
then
    emit_empty
fi

echo "<result>${compact}</result>"

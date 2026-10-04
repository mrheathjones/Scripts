#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-JC-Demobilize-PLIST-Installed.sh
# Author: Heath Jones
# Date: 04-17-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute — reports whether the Jamf Connect
#          Login Demobilize managed preference is applied by reading
#          DemobilizeUsers from the shared managed preferences plist.
# Version: 1.2 - Renamed to Name-Of-Script.sh convention
# Version: 1.1 - Public release prep: sanitized identifiers, expert-bash
#                conformance (ShellCheck directives, comment cleanup)
# Version: 1.0 - Initial Script
# Data Type: String
#
######################################################################
############## End Script Information Block ##########################
######################################################################

# readonly NAME=$(which ...) is the house template pattern; masking the
# return value is intentional.
# shellcheck disable=SC2155
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck disable=SC2230
readonly DEFAULTS=$(which defaults)

readonly MANAGED_PREFS_PLIST="/Library/Managed Preferences/com.jamf.connect.login.plist"
readonly DEMOBILIZE_KEY="DemobilizeUsers"

detect() {
    local value

    if [[ ! -f "${MANAGED_PREFS_PLIST}" ]]
    then
        printf '%s' "Not Installed"
        return
    fi

    if ! value=$("${DEFAULTS}" read "${MANAGED_PREFS_PLIST}" "${DEMOBILIZE_KEY}" 2>/dev/null)
    then
        printf '%s' "Not Installed"
        return
    fi

    if [[ "${value}" == "1" || "${value}" == "true" ]]
    then
        printf '%s' "Installed"
        return
    fi

    printf 'Installed (DemobilizeUsers=%s)' "${value}"
}

RESULT=$(detect)
echo "<result>${RESULT}</result>"

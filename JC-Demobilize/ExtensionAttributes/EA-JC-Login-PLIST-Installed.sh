#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-JC-Login-PLIST-Installed.sh
# Author: Heath Jones
# Date: 04-17-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute — reports whether the Jamf Connect
#          Login configuration profile is delivering its managed
#          preferences. Detection is based on the existence of the
#          managed preferences plist (the standard JC Login
#          preference domain), NOT the profile's payload identifier
#          (which varies per org and almost never matches the
#          preference domain).
# Version: 1.3 - Renamed to Name-Of-Script.sh convention
# Version: 1.2 - Public release prep: sanitized identifiers, expert-bash
#                conformance (ShellCheck directives, comment cleanup)
# Version: 1.1 - Bug fix: switched from `profiles show | grep
#                <profile-identifier>` to a direct check on the
#                managed preferences plist. The previous version was
#                grep'ing for the preference domain `com.jamf.connect.login`
#                inside the output of `profiles show`, which lists
#                profiles by their payload identifier — those rarely
#                match the preference domain. Result: every Mac was
#                falsely reporting "Not Installed" even when the
#                profile was correctly delivering preferences. The
#                managed preferences plist exists if and only if a
#                profile is delivering settings for that domain, so
#                this check is both correct and resilient to
#                org-specific profile naming.
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

readonly MANAGED_PREFS_PLIST="/Library/Managed Preferences/com.jamf.connect.login.plist"

detect() {
    if [[ -f "${MANAGED_PREFS_PLIST}" ]]
    then
        printf '%s' "Installed"
        return
    fi

    printf '%s' "Not Installed"
}

RESULT=$(detect)
echo "<result>${RESULT}</result>"

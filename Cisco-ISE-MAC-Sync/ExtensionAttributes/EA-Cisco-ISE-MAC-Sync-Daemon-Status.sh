#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-Cisco-ISE-MAC-Sync-Daemon-Status.sh
# Author: Heath Jones
# Date: 04-20-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute - reports whether the Cisco ISE MAC SYNC
#          LaunchDaemon is installed and loaded into launchd.
#          Result values:
#            Loaded      - plist present AND registered with launchctl
#            NotLoaded   - plist present but not registered
#            Missing     - plist file is not installed
#            Unknown     - unable to determine (launchctl error)
# Version: 1.3 - Renamed to Name-Of-Script.sh convention
# Version: 1.2 - Public release prep: sanitized identifiers/credentials, expert-bash conformance
#                - BUNDLE_ID now derived from ORG_PLIST_DOMAIN + PROJECT_SLUG
#                  (same as the main script)
#                - ShellCheck directive fixed (was malformed / ignored)
# Version: 1.1 - Project rename from ise-mac-keeper to Cisco_ISE_MAC_SYNC
# Version: 1.0 - Initial Script
# Data Type: String
#
######################################################################
############## End Script Information Block ##########################
######################################################################

# `which` is preferred over `command -v` per the style guide (SC2230), and
# `readonly VAR=$(which ...)` is the template's binary-path convention (SC2155).
# This directive sits before the first command, so it applies file-wide.
# shellcheck disable=SC2230,SC2155
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly LAUNCHCTL=$(which launchctl)

# NOTE: ORG_PLIST_DOMAIN and PROJECT_SLUG must match Cisco-ISE-MAC-Sync.sh;
# BUNDLE_ID is the LaunchDaemon label and plist filename.
readonly ORG_PLIST_DOMAIN="com.company"    # CHANGE_ME: must match Cisco-ISE-MAC-Sync.sh
readonly PROJECT_SLUG="cisco-ise-mac-sync"
readonly BUNDLE_ID="${ORG_PLIST_DOMAIN}.${PROJECT_SLUG}"
readonly DAEMON_PLIST="/Library/LaunchDaemons/${BUNDLE_ID}.plist"

RESULT="Unknown"

if [[ ! -f "${DAEMON_PLIST}" ]]
then
    RESULT="Missing"
else
    if "${LAUNCHCTL}" print "system/${BUNDLE_ID}" >/dev/null 2>&1
    then
        RESULT="Loaded"
    else
        RESULT="NotLoaded"
    fi
fi

echo "<result>${RESULT}</result>"

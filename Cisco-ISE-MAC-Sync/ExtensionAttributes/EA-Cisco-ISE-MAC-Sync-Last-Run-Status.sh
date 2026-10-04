#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-Cisco-ISE-MAC-Sync-Last-Run-Status.sh
# Author: Heath Jones
# Date: 04-20-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute - reports the outcome of the most
#          recent Cisco ISE MAC SYNC run by reading the state plist
#          the main script maintains.
#          Output format: "<status> | <mac> | <iface> | <timestamp>"
#          Status values written by the main script:
#            success                 - PUT succeeded
#            success_nochange        - record already correct, no write
#            no_ethernet             - no active Ethernet, skipped
#            jamf_unreachable        - could not reach Jamf (even w/o VPN)
#            jamf_unreachable_vpn_up - Jamf down while VPN connected
#            vpn_stop_failed         - couldn't stop Cisco VPN agent
#            oauth_failed            - OAuth token request failed
#            get_failed              - GET computer record failed
#            put_failed              - all PUT retries failed
#            creds_missing           - script still has REPLACE-WITH-* placeholders
#            jamf_url_missing        - Mac is not Jamf-enrolled
#            serial_missing          - couldn't read serial number
#            NotRunYet               - state plist does not exist
# Version: 1.4 - Renamed to Name-Of-Script.sh convention
# Version: 1.3 - Public release prep: sanitized identifiers/credentials, expert-bash conformance
#                - ORG_NAME_FRIENDLY / derived ORG_NAME set to generic
#                  template defaults (same derivation as the main script)
#                - FIX: STATE_PLIST path was missing the "_SCRIPTS" segment
#                  the main script installs under, so the EA always
#                  reported NotRunYet
#                - ShellCheck directive fixed (was malformed / ignored)
# Version: 1.2 - Updated status enum: creds_missing replaces
#                config_missing / config_invalid (no longer using
#                Configuration Profile for credential delivery)
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

readonly DEFAULTS=$(which defaults)

# NOTE: ORG_NAME_FRIENDLY, SCRIPT_DIR and PROJECT_NAME must match
# Cisco-ISE-MAC-Sync.sh. ORG_NAME is derived (spaces stripped).
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: must match Cisco-ISE-MAC-Sync.sh
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly SCRIPT_DIR="_SCRIPTS"
readonly PROJECT_NAME="Cisco_ISE_MAC_SYNC"
readonly STATE_PLIST="/Library/Application Support/${ORG_NAME}/${SCRIPT_DIR}/${PROJECT_NAME}/state.plist"

RESULT="NotRunYet"

if [[ -f "${STATE_PLIST}" ]]
then
    status=$("${DEFAULTS}" read "${STATE_PLIST}" LastRunStatus 2>/dev/null || echo "Unknown")
    mac=$("${DEFAULTS}" read "${STATE_PLIST}" LastRunMAC 2>/dev/null || echo "")
    iface=$("${DEFAULTS}" read "${STATE_PLIST}" LastRunInterface 2>/dev/null || echo "")
    ts=$("${DEFAULTS}" read "${STATE_PLIST}" LastRunTimestamp 2>/dev/null || echo "")

    RESULT="${status} | ${mac} | ${iface} | ${ts}"
fi

echo "<result>${RESULT}</result>"

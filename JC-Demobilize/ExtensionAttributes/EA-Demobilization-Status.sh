#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-Demobilization-Status.sh
# Author: Heath Jones
# Date: 04-17-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute — reports where this Mac is in the JC
#          demobilization workflow. Values:
#            - "N/A"          : no demobilize profile installed and
#                               no workflow receipt (out of scope)
#            - "Not Started"  : demobilize profile installed but
#                               Phase A has not yet run
#            - "In Progress"  : Phase A receipt written, awaiting
#                               Phase B to complete
#            - "Complete"     : Phase B finished successfully
#            - "Failed: <step> | Next: <remediation>"
#                             : Phase B aborted at <step>; <remediation>
#                               describes what to do next
# Version: 1.3 - Renamed to Name-Of-Script.sh convention
# Version: 1.2 - Public release prep: sanitized identifiers, expert-bash
#                conformance (ShellCheck directives, comment cleanup)
# Version: 1.1 - Bug fix: state.plist path was hardcoded to the
#                placeholder org folder ("/Library/Application
#                Support/IT/...") which doesn't match the deployed
#                path under the real ORG_NAME folder.
#                EAs falsely reported "Not Started" on every Mac.
#                The EA now discovers the state.plist by globbing
#                /Library/Application Support/*/JCDemobilize/, which
#                is resilient to any ORG_NAME change without needing
#                to re-upload the EA.
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
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"

readonly MANAGED_PREFS_PLIST="/Library/Managed Preferences/com.jamf.connect.login.plist"
readonly DEMOBILIZE_KEY="DemobilizeUsers"

# Discover the workflow's state.plist by scanning for any JCDemobilize
# directory under /Library/Application Support/. This works regardless
# of ORG_NAME (ExampleCorp, IT, …) so the EA never needs to be
# re-uploaded if the org folder name changes.
STATE_PLIST=""
for candidate in /Library/Application\ Support/*/JCDemobilize/state.plist
do
    if [[ -f "${candidate}" ]]
    then
        STATE_PLIST="${candidate}"
        break
    fi
done

is_demobilize_profile_installed() {
    local value

    if [[ ! -f "${MANAGED_PREFS_PLIST}" ]]
    then
        return 1
    fi

    if ! value=$("${DEFAULTS}" read "${MANAGED_PREFS_PLIST}" "${DEMOBILIZE_KEY}" 2>/dev/null)
    then
        return 1
    fi

    if [[ "${value}" == "1" || "${value}" == "true" ]]
    then
        return 0
    fi

    return 1
}

read_state_value() {
    local key="$1"
    "${PLIST_BUDDY}" -c "Print :${key}" "${STATE_PLIST}" 2>/dev/null
}

detect() {
    local status
    local step
    local next_steps

    if [[ -z "${STATE_PLIST}" || ! -f "${STATE_PLIST}" ]]
    then
        if is_demobilize_profile_installed
        then
            printf '%s' "Not Started"
            return
        fi
        printf '%s' "N/A"
        return
    fi

    status=$(read_state_value "status")
    step=$(read_state_value "step")
    next_steps=$(read_state_value "next_steps")

    case "${status}" in
        Complete)
            printf '%s' "Complete"
            ;;
        "In Progress")
            printf 'In Progress (%s)' "${step:-unknown step}"
            ;;
        Failed)
            if [[ -n "${next_steps}" ]]
            then
                printf 'Failed: %s | Next: %s' "${step:-unknown step}" "${next_steps}"
            else
                printf 'Failed: %s' "${step:-unknown step}"
            fi
            ;;
        "")
            if is_demobilize_profile_installed
            then
                printf '%s' "Not Started"
            else
                printf '%s' "N/A"
            fi
            ;;
        *)
            printf 'Unknown status: %s' "${status}"
            ;;
    esac
}

RESULT=$(detect)
echo "<result>${RESULT}</result>"

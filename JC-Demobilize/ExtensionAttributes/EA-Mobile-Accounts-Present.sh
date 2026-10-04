#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-Mobile-Accounts-Present.sh
# Author: Heath Jones
# Date: 04-17-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute — lists all mobile accounts present on
#          the Mac by detecting users with an OriginalNodeName (the
#          canonical marker of a cached AD/mobile account). Returns
#          "None" if no mobile accounts are found.
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
readonly DSCL=$(which dscl)
readonly AWK=$(which awk)

list_mobile_accounts() {
    local user
    local original_node
    local -a mobile_users=()
    local users

    if ! users=$("${DSCL}" . -list /Users OriginalNodeName 2>/dev/null)
    then
        printf '%s' "None"
        return
    fi

    while IFS= read -r line
    do
        # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
        user=$("${AWK}" '{ print $1 }' <<< "${line}")
        # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
        original_node=$("${AWK}" '{ $1=""; print substr($0,2) }' <<< "${line}")

        if [[ -z "${user}" || -z "${original_node}" ]]
        then
            continue
        fi

        case "${user}" in
            _*|daemon|nobody|root)
                continue
                ;;
        esac

        mobile_users+=("${user}")
    done <<< "${users}"

    if [[ ${#mobile_users[@]} -eq 0 ]]
    then
        printf '%s' "None"
        return
    fi

    local IFS=","
    printf '%s' "${mobile_users[*]}"
}

RESULT=$(list_mobile_accounts)
echo "<result>${RESULT}</result>"

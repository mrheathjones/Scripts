#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-SecureToken-Holders.sh
# Author: Heath Jones
# Date: 04-17-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute — lists all local/visible user accounts
#          that currently hold a SecureToken. Returns "None" if no
#          SecureToken holders are found. Useful for verifying the
#          local admin scoped for JC demobilization still holds a
#          token before the conversion policy runs.
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
readonly SYSADMINCTL=$(which sysadminctl)
readonly GREP=$(which grep)
readonly AWK=$(which awk)

list_holders() {
    local user
    local uid
    local -a holders=()
    local users

    if ! users=$("${DSCL}" . -list /Users UniqueID 2>/dev/null)
    then
        printf '%s' "None"
        return
    fi

    while IFS= read -r line
    do
        # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
        user=$("${AWK}" '{ print $1 }' <<< "${line}")
        # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
        uid=$("${AWK}" '{ print $2 }' <<< "${line}")

        if [[ -z "${user}" || -z "${uid}" ]]
        then
            continue
        fi

        # Skip system/hidden accounts
        case "${user}" in
            _*|daemon|nobody|root)
                continue
                ;;
        esac

        if [[ "${uid}" -lt 500 ]]
        then
            continue
        fi

        if "${SYSADMINCTL}" -secureTokenStatus "${user}" 2>&1 \
            | "${GREP}" -q -i "ENABLED"
        then
            holders+=("${user}")
        fi
    done <<< "${users}"

    if [[ ${#holders[@]} -eq 0 ]]
    then
        printf '%s' "None"
        return
    fi

    local IFS=","
    printf '%s' "${holders[*]}"
}

RESULT=$(list_holders)
echo "<result>${RESULT}</result>"

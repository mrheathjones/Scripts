#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-AD-Bind-Status.sh
# Author: Heath Jones
# Date: 04-17-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute — reports the Mac's Active Directory
#          bind status. Returns "Bound: <domain>" when bound, or
#          "Not Bound" when no AD binding is present.
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
readonly DSCONFIGAD=$(which dsconfigad)
readonly AWK=$(which awk)
readonly SED=$(which sed)

detect() {
    local domain

    # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
    if ! domain=$("${DSCONFIGAD}" -show 2>/dev/null \
        | "${AWK}" -F'= ' '/Active Directory Domain/ { print $2 }' \
        | "${SED}" -e 's/[[:space:]]*$//')
    then
        printf '%s' "Not Bound"
        return
    fi

    if [[ -z "${domain}" ]]
    then
        printf '%s' "Not Bound"
        return
    fi

    printf 'Bound: %s' "${domain}"
}

RESULT=$(detect)
echo "<result>${RESULT}</result>"

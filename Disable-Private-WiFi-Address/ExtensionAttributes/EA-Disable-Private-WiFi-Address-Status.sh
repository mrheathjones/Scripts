#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: EA-Disable-Private-WiFi-Address-Status.sh
# Author: Heath Jones
# Date: 07-09-2026
# Modified: 10-04-2026
# Purpose: Extension Attribute — reports Private Wi-Fi Address compliance:
#          the system-wide PrivateMACAddressModeSystemSetting value and whether
#          the live Wi-Fi MAC matches the hardware MAC (i.e. randomization off).
# Version: 1.0 - Initial Script
# Version: 1.1 - Renamed to match disable-private-wifi-address runtime identity
# Version: 2.0 - Rearchitected: no LaunchDaemon/install to track anymore. Now
#                reports the system-wide setting + hardware-vs-live MAC compliance.
# Version: 2.1 - Public release prep: sanitized identifiers, expert-bash conformance.
#                Fixed result wrapper: Jamf only parses <result></result>, the
#                previous short tag left the EA value unparsed.
# Version: 2.2 - Renamed to Name-Of-Script.sh convention
# Data Type: String
#
######################################################################
############## End Script Information Block ##########################
######################################################################

# `readonly NAME=$(cmd)` is the template's declaration convention (SC2155) and
# awk programs are intentionally single-quoted (SC2016); both are deliberate.
# shellcheck disable=SC2155,SC2016

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# `which` is preferred over `command -v` per the style guide, so the directive below is deliberate.
# shellcheck disable=SC2230
readonly AWK=$(which awk)
readonly DEFAULTS=$(which defaults)
readonly NETWORKSETUP=$(which networksetup)
readonly IFCONFIG=$(which ifconfig)

readonly AIRPORT_PREFS_DOMAIN="/Library/Preferences/SystemConfiguration/com.apple.airport.preferences"
readonly SYSTEM_SETTING_KEY="PrivateMACAddressModeSystemSetting"

# EA logic — fast, side-effect-free, no `set -e` (must always print a result).
# Reads only: the airport prefs are world-readable, so this works without FDA.

# System-wide default (1 = randomization disabled by default, 0 = on)
sys_default=$("${DEFAULTS}" read "${AIRPORT_PREFS_DOMAIN}" "${SYSTEM_SETTING_KEY}" 2>/dev/null)
case "${sys_default}" in
    1)
        sys_label="off"
        ;;
    0)
        sys_label="on"
        ;;
    *)
        sys_label="unset"
        ;;
esac

# Determine the Wi-Fi interface (fall back to en0)
wifi_interface=$("${NETWORKSETUP}" -listallhardwareports 2>/dev/null \
    | "${AWK}" '/Hardware Port: Wi-Fi/{getline; print $2; exit}')
if [[ -z "${wifi_interface}" ]]
then
    wifi_interface="en0"
fi

# Hardware (burned-in) MAC vs current live MAC
hardware_mac=$("${NETWORKSETUP}" -getmacaddress "${wifi_interface}" 2>/dev/null | "${AWK}" '{print $3; exit}')
current_mac=$("${IFCONFIG}" "${wifi_interface}" 2>/dev/null | "${AWK}" '/ether/{print $2; exit}')

if [[ -z "${hardware_mac}" ]] || [[ -z "${current_mac}" ]]
then
    mac_label="unknown"
elif [[ "${current_mac}" == "${hardware_mac}" ]]
then
    mac_label="hardware"
else
    mac_label="randomized"
fi

echo "<result>SysDefault=${sys_label} | MAC=${mac_label}</result>"
exit 0

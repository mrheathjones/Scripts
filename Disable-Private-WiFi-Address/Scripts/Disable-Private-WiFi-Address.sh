#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Disable-Private-WiFi-Address.sh
# Author: Heath Jones
# Date: 07-09-2026
# Modified: 10-04-2026
# Purpose: Disable macOS Private Wi-Fi Address (MAC randomization) fleet-wide so
#          MAC-based NAC works. Sets PrivateMACAddressModeSystemSetting=1 in the
#          system airport preferences, which disables the private address for
#          existing AND newly-joined networks (verified on macOS 26.5.1). Verifies
#          the write landed and optionally cycles Wi-Fi so it applies immediately.
# Version: 1.0 - Initial Script
# Version: 1.1 - Renamed deployable to install-disable-private-wifi-address.sh;
#                runtime identity (PROJECT_NAME) set to disable-private-wifi-address
# Version: 2.0 - Rearchitected: Apple protects the per-SSID known-networks store
#                behind TCC on macOS 15.6+/26, but the single system-wide default
#                key covers existing + new networks. Dropped the self-installing
#                LaunchDaemon, WatchPaths watcher, and known-networks enumeration.
#                Now a simple Jamf policy script (requires Full Disk Access for the
#                Jamf agent, granted separately via PPPC). Fixed unchecked defaults
#                write; now verifies via read-back and fails loudly if FDA missing.
# Version: 2.1 - Renamed deployable to disable-private-wifi-address.sh (no longer
#                an installer — the self-installing model was dropped in 2.0)
# Version: 2.2 - Public release prep: sanitized identifiers, expert-bash conformance.
#                Added ORG_NAME_FRIENDLY/ORG_NAME template identity, Requirements
#                section + preflight (macOS version, param 4 validation), default
#                case branch, removed unused binary vars (ipconfig, system_profiler),
#                fixed malformed shellcheck directive.
# Version: 2.3 - Renamed to Name-Of-Script.sh convention
#
# Requirements:
#   - Runs as root (Jamf policy)
#   - macOS 15 or later (exits 0 with a warning on older macOS; no-op there)
#   - Full Disk Access for the Jamf agent via a PPPC Configuration Profile
#     (the airport preferences are TCC-protected; verified by read-back, exit 1 if missing)
#   - Jamf parameter $4 (optional): Restart Wi-Fi to apply immediately, 1=yes / 0=no (default 1)
#
######################################################################
############## End Script Information Block ##########################
######################################################################

####################################################################
############## Begin Define Variables Block ########################
####################################################################
##############################
### Core Defined Variables ###
### MODIFY AT YOUR OWN RISK ##
##############################

# `readonly NAME=$(cmd)` is the template's declaration convention (SC2155) and
# awk programs are intentionally single-quoted (SC2016); both are deliberate.
# shellcheck disable=SC2155,SC2016

set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
# `which` is preferred over `command -v` per the style guide, so the directive below is deliberate.
# shellcheck disable=SC2230
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
# shellcheck disable=SC2034  # template core binary, unused by this script
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment. This script writes no files of its
# own, so only ORG_PLIST_DOMAIN is used (for the log label).
# ORG_NAME_FRIENDLY: human-readable display name, e.g. "Example Corp".
# ORG_NAME: path-safe form (spaces stripped), derived — never set by hand.
# ORG_PLIST_DOMAIN: reverse-DNS used for LOG_LABEL, e.g. "com.example".
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: your organization's display name
# shellcheck disable=SC2034  # template identity, unused by this script
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"      # CHANGE_ME: your organization's reverse-DNS domain

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="2.3"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.disable-private-wifi-address"
# shellcheck disable=SC2034  # template core variable, unused by this script
readonly TIMESTAMP=$("${DATE}" +%Y%m%d_%H%M%S)
readonly JAMF_LOG="/var/log/jamf.log"

declare -a TEMP_FILES=()

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# Task-specific binary paths
readonly DEFAULTS=$(which defaults)
readonly SW_VERS=$(which sw_vers)
readonly NETWORKSETUP=$(which networksetup)
readonly IFCONFIG=$(which ifconfig)
readonly PGREP=$(which pgrep)
readonly KILLALL=$(which killall)
readonly SLEEP=$(which sleep)

# The system-wide Private Wi-Fi Address store and key.
# NOTE: this file is TCC-protected on macOS 15.6+/26 — the process writing it needs
# Full Disk Access (granted to the Jamf agent via a separate PPPC profile). Without
# it, the write silently fails ("Could not write domain ... exiting") and this
# script will detect that via read-back and exit non-zero.
readonly AIRPORT_PREFS_DOMAIN="/Library/Preferences/SystemConfiguration/com.apple.airport.preferences"
readonly SYSTEM_SETTING_KEY="PrivateMACAddressModeSystemSetting"
# 1 = disable Private Wi-Fi Address by default (use hardware MAC). 0 = randomize.
readonly TARGET_VALUE="1"

# Minimum macOS major version where PrivateMACAddressModeSystemSetting applies
readonly MIN_OS_MAJOR=15

# Jamf parameters ($1-$3 reserved by Jamf: mount point, computer name, username)
# Parameter 4: Restart Wi-Fi to apply immediately (1) or leave for next
# connect/reboot (0). Default 1.
readonly PARAM_RESTART_WIFI="${4:-1}"
# Seconds to wait for reassociation after cycling Wi-Fi power
readonly RECONNECT_WAIT_SEC="7"

# Runtime globals (populated by helpers; never captured from logging-function stdout)
OS_MAJOR=0
WIFI_INTERFACE=""
HARDWARE_MAC=""
CURRENT_MAC=""

##################################
### End User Defined Variables ###
##################################
####################################################################
############## End Define Variables Block ##########################
####################################################################

###################################################################################
############## Begin Function Block ###############################################
###################################################################################
##############################
### Core Defined Functions ###
### MODIFY AT YOUR OWN RISK ##
##############################

# ── Logging ──────────────────────────────────────────────────────────────────
log_info() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_debug() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
cleanup() {
    local exit_code=$?
    local f
    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -f "${f}" ]]
        then
            "${RM}" -f "${f}"
        fi
    done
    log_info "${SCRIPT_NAME} exiting with code ${exit_code}"
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ── Preflight ────────────────────────────────────────────────────────────────
require_root() {
    if [[ "$("${ID}" -u)" -ne 0 ]]
    then
        log_error "Must run as root"
        exit 1
    fi
}

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

# Populate OS_MAJOR (global; never captured from function stdout).
populate_os_major() {
    local major
    major=$("${SW_VERS}" -productVersion 2>/dev/null | "${AWK}" -F. '{print $1}' || true)
    if [[ "${major}" =~ ^[0-9]+$ ]]
    then
        OS_MAJOR="${major}"
    else
        OS_MAJOR=0
    fi
}

# Requirement: macOS 15+. Older macOS is a documented no-op (exit 0), not a failure.
require_min_os() {
    populate_os_major
    if [[ "${OS_MAJOR}" -lt "${MIN_OS_MAJOR}" ]]
    then
        log_warn "macOS ${OS_MAJOR} detected; ${SYSTEM_SETTING_KEY} only applies to macOS ${MIN_OS_MAJOR}+. Nothing to do."
        exit 0
    fi
}

# Requirement: param 4 is optional; warn on an unexpected value. Any value other
# than "1" leaves Wi-Fi alone (unchanged behavior).
validate_restart_param() {
    if [[ "${PARAM_RESTART_WIFI}" != "1" && "${PARAM_RESTART_WIFI}" != "0" ]]
    then
        log_warn "Parameter 4 (Restart Wi-Fi) is '${PARAM_RESTART_WIFI}', expected 1 or 0; Wi-Fi will not be restarted"
    fi
}

# ── Wi-Fi interface + MAC helpers (set globals; not captured from log stdout) ─
populate_wifi_interface() {
    WIFI_INTERFACE=$("${NETWORKSETUP}" -listallhardwareports 2>/dev/null \
        | "${AWK}" '/Hardware Port: Wi-Fi/{getline; print $2; exit}' || true)
    if [[ -z "${WIFI_INTERFACE}" ]]
    then
        WIFI_INTERFACE="en0"
    fi
}

# Hardware (burned-in) MAC — what NAC should see once randomization is off.
populate_hardware_mac() {
    HARDWARE_MAC=$("${NETWORKSETUP}" -getmacaddress "${WIFI_INTERFACE}" 2>/dev/null \
        | "${AWK}" '{print $3; exit}' || true)
}

# Current live MAC on the interface (randomized until the setting applies).
populate_current_mac() {
    CURRENT_MAC=$("${IFCONFIG}" "${WIFI_INTERFACE}" 2>/dev/null \
        | "${AWK}" '/ether/{print $2; exit}' || true)
}

# ── Assert the system-wide setting, then VERIFY via read-back ─────────────────
# Return: 0 changed+verified, 1 already correct, 2 write did not take (likely FDA).
assert_system_setting() {
    local current
    current=$("${DEFAULTS}" read "${AIRPORT_PREFS_DOMAIN}" "${SYSTEM_SETTING_KEY}" 2>/dev/null || true)

    if [[ "${current}" == "${TARGET_VALUE}" ]]
    then
        log_info "${SYSTEM_SETTING_KEY} already ${TARGET_VALUE}; no change needed"
        return 1
    fi

    log_info "Setting ${SYSTEM_SETTING_KEY}=${TARGET_VALUE} (was: ${current:-<unset>})"
    "${DEFAULTS}" write "${AIRPORT_PREFS_DOMAIN}" "${SYSTEM_SETTING_KEY}" -int "${TARGET_VALUE}" 2>/dev/null || true

    # The defaults exit code is unreliable for this domain — verify by read-back.
    local verify
    verify=$("${DEFAULTS}" read "${AIRPORT_PREFS_DOMAIN}" "${SYSTEM_SETTING_KEY}" 2>/dev/null || true)
    if [[ "${verify}" != "${TARGET_VALUE}" ]]
    then
        log_error "Write did NOT take (read-back=${verify:-<unset>}). The airport preferences are TCC-protected on macOS 15.6+/26 — the Jamf agent needs Full Disk Access (PPPC). Deploy that profile, then re-run."
        return 2
    fi

    log_info "Verified ${SYSTEM_SETTING_KEY}=${verify}"
    return 0
}

# ── Cycle Wi-Fi so the hardware MAC takes effect immediately ─────────────────
reconnect_wifi() {
    log_info "Restarting Wi-Fi on ${WIFI_INTERFACE} to apply the setting now"

    # Make cfprefsd/airportd read the freshly-written preference before cycling.
    if "${PGREP}" -x -q "cfprefsd"
    then
        "${KILLALL}" "cfprefsd" 2>/dev/null || true
        "${SLEEP}" 0.5
    fi
    if "${PGREP}" -x -q "airportd"
    then
        "${KILLALL}" "airportd" 2>/dev/null || true
        "${SLEEP}" 0.5
    fi

    log_info "Powering ${WIFI_INTERFACE} OFF"
    "${NETWORKSETUP}" -setairportpower "${WIFI_INTERFACE}" off 2>/dev/null || true
    "${SLEEP}" 1
    log_info "Powering ${WIFI_INTERFACE} ON, waiting ${RECONNECT_WAIT_SEC}s for reassociation"
    "${NETWORKSETUP}" -setairportpower "${WIFI_INTERFACE}" on 2>/dev/null || true
    "${SLEEP}" "${RECONNECT_WAIT_SEC}"
}

# ── Report whether the live MAC now matches the hardware MAC ──────────────────
report_compliance() {
    populate_current_mac
    log_info "Hardware MAC: ${HARDWARE_MAC:-unknown} | Current MAC (${WIFI_INTERFACE}): ${CURRENT_MAC:-unknown}"

    if [[ -z "${HARDWARE_MAC}" ]] || [[ -z "${CURRENT_MAC}" ]]
    then
        log_warn "Could not read both MACs to confirm compliance (Wi-Fi may be disconnected)"
        return 0
    fi

    if [[ "${CURRENT_MAC}" == "${HARDWARE_MAC}" ]]
    then
        log_info "COMPLIANT: interface is using the hardware MAC (private address off)"
    else
        log_warn "Interface MAC still differs from hardware MAC — will resolve on next reconnect/reboot"
    fi
}

##################################
### End User Defined Functions ###
##################################
###################################################################################
############## End Function Block #################################################
###################################################################################

#####################################################
################## Run Script Block #################
#####################################################

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting"

require_root
require_min_os
validate_restart_param

populate_wifi_interface
populate_hardware_mac
populate_current_mac
log_info "Wi-Fi interface: ${WIFI_INTERFACE} | Hardware MAC: ${HARDWARE_MAC:-unknown} | Current MAC: ${CURRENT_MAC:-unknown}"

setting_result=0
if assert_system_setting
then
    setting_result=0
else
    setting_result=$?
fi

case "${setting_result}" in
    0)
        # Changed and verified — apply immediately if requested.
        if [[ "${PARAM_RESTART_WIFI}" == "1" ]]
        then
            reconnect_wifi
        else
            log_info "Restart Wi-Fi disabled (param 4 is not 1); setting applies on next connect/reboot"
        fi
        report_compliance
        ;;
    1)
        # Already compliant — confirm the live MAC, no disruptive reconnect.
        report_compliance
        ;;
    2)
        # Write did not take (FDA missing) — already logged; fail the policy.
        exit 1
        ;;
    *)
        log_error "Unexpected result ${setting_result} from assert_system_setting"
        exit 1
        ;;
esac

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

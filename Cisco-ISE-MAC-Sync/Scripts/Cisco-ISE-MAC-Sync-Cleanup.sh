#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Cisco-ISE-MAC-Sync-Cleanup.sh
# Author: Heath Jones
# Date: 05-06-2026
# Modified: 10-04-2026
# Purpose: Standalone cleanup / uninstall for the Cisco_ISE_MAC_SYNC
#          deployment. Boots out the LaunchDaemon, kills any lingering
#          script processes, and removes every on-disk artifact the
#          project deploys. Self-contained — does NOT depend on the
#          main script being installed. Safe to run repeatedly and on
#          an already-clean Mac.
# Version: 1.2 - Renamed to Name-Of-Script.sh convention; targets the renamed
#                installed copy (and pre-2.11 copies) under INSTALL_DIR
# Version: 1.1 - Public release prep: sanitized identifiers/credentials, expert-bash conformance
#                - ORG_NAME_FRIENDLY / derived ORG_NAME / ORG_PLIST_DOMAIN
#                  set to generic template defaults
#                - FIX: INSTALL_DIR was missing the SCRIPT_DIR ("_SCRIPTS")
#                  segment the main script installs under, so the install
#                  directory was never removed and pgrep never matched
#                  lingering --run processes
#                - Dual-log: unified log + /var/log/jamf.log via tee
#                - FIX: pids=$(pgrep ...) aborted the script under set -e
#                  if the process exited between the check and the
#                  capture; capture now tolerates no-match
#                - ShellCheck directive fixed (was malformed / ignored)
#                - Added Requirements section
# Version: 1.0 - Initial Script
#                - launchctl bootout by label (works even if the
#                  plist file is missing as long as the label is
#                  registered)
#                - pgrep -f match against INSTALL_SCRIPT_PATH to
#                  catch any lingering --run process; SIGTERM with
#                  a grace period, then SIGKILL stragglers
#                - Removes: LaunchDaemon plist, install directory
#                  (script + state.plist), dedicated log file, lock
#                  file, debounce file
#                - Logs every action to the unified log via logger;
#                  exits 0 on success and on already-clean no-op
#
# Requirements:
#   - Runs as root (Jamf policy)
#   - ORG_NAME_FRIENDLY / ORG_PLIST_DOMAIN must match Cisco-ISE-MAC-Sync.sh
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

# `which` is preferred over `command -v` per the style guide (SC2230), and
# `readonly VAR=$(which ...)` is the template's binary-path convention (SC2155).
# This directive sits before the first command, so it applies file-wide.
# shellcheck disable=SC2230,SC2155
set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly KILL=$(which kill)
readonly LAUNCHCTL=$(which launchctl)
readonly LOGGER=$(which logger)
readonly PGREP=$(which pgrep)
readonly RM=$(which rm)
readonly SLEEP=$(which sleep)
readonly TEE=$(which tee)

# Org identity — must match Cisco-ISE-MAC-Sync.sh.
# ORG_NAME is derived (spaces stripped) for filesystem paths.
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: must match Cisco-ISE-MAC-Sync.sh
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"      # CHANGE_ME: must match Cisco-ISE-MAC-Sync.sh
readonly SCRIPT_DIR="_SCRIPTS"

# Project identity — must match Cisco-ISE-MAC-Sync.sh.
readonly PROJECT_NAME="Cisco_ISE_MAC_SYNC"
readonly PROJECT_SLUG="cisco-ise-mac-sync"

readonly SCRIPT_NAME=$("${BASENAME}" "${0}")
readonly SCRIPT_VERSION="1.2"
readonly JAMF_LOG="/var/log/jamf.log"

# Bundle / labels — must match Cisco-ISE-MAC-Sync.sh.
readonly BUNDLE_ID="${ORG_PLIST_DOMAIN}.${PROJECT_SLUG}"
readonly DAEMON_LABEL="${BUNDLE_ID}"
# Use a distinct LOG_LABEL suffix so cleanup actions are easy to filter
# in the unified log even after the main script's log file is removed.
readonly LOG_LABEL="${BUNDLE_ID}.cleanup"

declare -a TEMP_FILES=()

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# --- Artifact paths (must match Cisco-ISE-MAC-Sync.sh) ----------------------
readonly INSTALL_DIR="/Library/Application Support/${ORG_NAME}/${SCRIPT_DIR}/${PROJECT_NAME}"
readonly DAEMON_PLIST_PATH="/Library/LaunchDaemons/${BUNDLE_ID}.plist"
readonly LOG_FILE="/var/log/${BUNDLE_ID}.log"
readonly LOCK_FILE="/var/run/${BUNDLE_ID}.pid"
readonly DEBOUNCE_FILE="/var/run/${BUNDLE_ID}.debounce"

# --- Behavior tuning ---------------------------------------------------------
readonly DAEMON_BOOTOUT_GRACE_SECONDS=3
readonly PROCESS_KILL_GRACE_SECONDS=2

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

# ── Logging (unified log + /var/log/jamf.log) ────────────────────────────────
# The main script's dedicated log file is one of the things we delete, so we
# never write to it here.
log_info() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    echo -e "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

log_debug() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    echo -e "${log_msg}" | "${TEE}" -ai "${JAMF_LOG}"
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
cleanup() {
    local exit_code=$?
    local f
    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -n "${f}" && -f "${f}" ]]
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

# ── Stop the LaunchDaemon ────────────────────────────────────────────────────
stop_daemon() {
    if "${LAUNCHCTL}" print "system/${DAEMON_LABEL}" >/dev/null 2>&1
    then
        log_info "LaunchDaemon ${DAEMON_LABEL} is loaded; issuing bootout"
        if "${LAUNCHCTL}" bootout "system/${DAEMON_LABEL}" 2>/dev/null
        then
            log_info "  bootout succeeded"
        else
            log_warn "  bootout returned non-zero (label may already be unloaded)"
        fi
        "${SLEEP}" "${DAEMON_BOOTOUT_GRACE_SECONDS}"
    else
        log_info "LaunchDaemon ${DAEMON_LABEL} not loaded; skipping bootout"
    fi
}

# ── Kill any lingering script processes ──────────────────────────────────────
# Matches against the canonical install path so we only target processes
# spawned from /Library/Application Support/.../_SCRIPTS/Cisco_ISE_MAC_SYNC/ — never
# this cleanup script itself (which runs from a Jamf temp path).
kill_lingering_processes() {
    # INSTALL_DIR matches both the current and the pre-2.11 installed filename.
    local match_pattern="${INSTALL_DIR}/"

    if ! "${PGREP}" -f "${match_pattern}" >/dev/null 2>&1
    then
        log_info "No lingering ${PROJECT_NAME} processes found"
        return 0
    fi

    local pids
    pids=$("${PGREP}" -f "${match_pattern}" 2>/dev/null || true)
    log_warn "Lingering ${PROJECT_NAME} process(es) detected; sending SIGTERM"

    local pid
    while IFS= read -r pid
    do
        if [[ -n "${pid}" && "${pid}" != "$$" ]]
        then
            log_info "  TERM PID ${pid}"
            "${KILL}" -TERM "${pid}" 2>/dev/null || true
        fi
    done <<< "${pids}"

    "${SLEEP}" "${PROCESS_KILL_GRACE_SECONDS}"

    # Recheck and SIGKILL anything still alive
    if "${PGREP}" -f "${match_pattern}" >/dev/null 2>&1
    then
        pids=$("${PGREP}" -f "${match_pattern}" 2>/dev/null || true)
        log_warn "Process(es) did not exit on TERM; sending SIGKILL"
        while IFS= read -r pid
        do
            if [[ -n "${pid}" && "${pid}" != "$$" ]]
            then
                log_warn "  KILL PID ${pid}"
                "${KILL}" -KILL "${pid}" 2>/dev/null || true
            fi
        done <<< "${pids}"
    else
        log_debug "All targeted processes exited cleanly on TERM"
    fi
}

# ── File / directory removal helpers ─────────────────────────────────────────
remove_file() {
    local path="$1"
    local label="$2"

    if [[ -e "${path}" ]]
    then
        if "${RM}" -f "${path}"
        then
            log_info "Removed ${label}: ${path}"
        else
            log_warn "Failed to remove ${label}: ${path}"
        fi
    else
        log_debug "${label} not present: ${path}"
    fi
}

remove_directory() {
    local path="$1"
    local label="$2"

    if [[ -d "${path}" ]]
    then
        if "${RM}" -rf "${path}"
        then
            log_info "Removed ${label}: ${path}"
        else
            log_warn "Failed to remove ${label}: ${path}"
        fi
    else
        log_debug "${label} not present: ${path}"
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

# Jamf Script payload positional args ($1=mount, $2=computer, $3=user,
# $4-11=custom params) are intentionally ignored — this script has no
# modes. It always performs the same cleanup sequence.

require_root

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting cleanup of ${BUNDLE_ID}"

# 1. Stop the LaunchDaemon FIRST — prevents launchd from re-spawning the
#    script while we're removing files.
stop_daemon

# 2. Kill any lingering --run processes (e.g., one mid-flight when the
#    daemon was bootout'd).
kill_lingering_processes

# 3. Remove the LaunchDaemon plist (after bootout so launchd doesn't
#    notice the file disappear and complain).
remove_file "${DAEMON_PLIST_PATH}" "LaunchDaemon plist"

# 4. Remove the install directory (main script + state.plist + anything
#    else the project may have written under it).
remove_directory "${INSTALL_DIR}" "install directory"

# 5. Remove the dedicated log file.
remove_file "${LOG_FILE}" "log file"

# 6. Remove transient runtime files.
remove_file "${LOCK_FILE}" "lock file"
remove_file "${DEBOUNCE_FILE}" "debounce file"

log_info "Cleanup complete. ${BUNDLE_ID} fully removed."

###########################################################
################## End Script Block #######################
###########################################################

#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Cisco-ISE-MAC-Sync.sh
# Author: Heath Jones
# Date: 04-20-2026
# Modified: 10-04-2026
# Purpose: Maintains Jamf Pro primary & alternate MAC address as the
#          currently active Ethernet adapter MAC so Cisco ISE -> Jamf
#          lookups authenticate the correct device for VPN. Re-asserts
#          the MAC after every jamf recon (which would otherwise revert
#          it to the built-in MAC). Handles Cisco Secure Client
#          Always-On fail-closed state by stopping and restarting the
#          VPN agent around the update when Jamf is unreachable.
# Version: 2.11 - Renamed to Name-Of-Script.sh convention; installed copy is now
#                Cisco-ISE-MAC-Sync.sh (pre-2.11 copy removed on --install)
# Version: 2.10 - Public release prep: sanitized identifiers/credentials, expert-bash conformance
#                - Embedded OAuth CLIENT_ID / CLIENT_SECRET replaced with
#                  REPLACE-WITH-* placeholders; load_config() refuses to
#                  run until they are replaced (state creds_missing)
#                - ORG_NAME_FRIENDLY / derived ORG_NAME / ORG_PLIST_DOMAIN
#                  set to generic template defaults
#                - Added Requirements section + require_jq preflight
#                - Logging now also tees to /var/log/jamf.log in
#                  --install / --uninstall (Jamf policy) modes. --run mode
#                  deliberately does NOT write jamf.log: the LaunchDaemon
#                  WatchPaths jamf.log, so doing so would retrigger itself
#                - Mapped Jamf $4 to PARAM_MODE
#                - ShellCheck directive fixed (was malformed / ignored)
#                - FIX: get_active_ethernet_mac() was called via $(...),
#                  so ACTIVE_INTERFACE_DEVICE / _PORT / _POSITION were set
#                  in a subshell and lost. Slot selection always fell back
#                  to primary and state.plist never recorded the interface.
#                  Function now sets ACTIVE_INTERFACE_MAC as a global and
#                  is called directly.
#                - get_vpn_state() now sets VPN_STATE as a global instead
#                  of being captured via $(...) (it logs)
#                - FIX: log file append printed "Permission denied" when
#                  run non-root (e.g. --status); stderr now redirected first
# Version: 2.9 - Cisco watchdog-respawn workaround
#                - stop_cisco_vpn() now tries graceful CLI disconnect
#                  (/opt/cisco/secureclient/bin/vpn disconnect) FIRST.
#                  The agent stays running, the tunnel drops, Always-On
#                  fail-closed lifts. Watchdog has nothing to respawn.
#                  launchctl bootout is now a fallback for cases where
#                  the CLI disconnect itself fails.
#                - start_cisco_vpn() now reconnects via "vpn connect"
#                  when the agent is still alive (the disconnect path),
#                  and only uses launchctl bootstrap when the agent
#                  was actually killed (the bootout fallback path).
#                - get_vpn_state() logs the raw CLI state-line text
#                  when it doesn't match any known pattern, so
#                  "unknown" results are diagnoseable.
# Version: 2.8 - Ethernet-adapter detection hardening
#                - Reframed get_active_ethernet_mac() docs around the
#                  EXCLUSION model: any service that is not Wi-Fi, a
#                  virtual interface, iPhone/Bluetooth/Thunderbolt
#                  bridge, or cellular is treated as Ethernet. This
#                  is name-agnostic — Belkin, Realtek, Anker, Apple
#                  USB-C, "USB 10/100/1000 LAN", and any other
#                  vendor naming all pass through.
#                - Per-candidate debug logging: every service-order
#                  entry now logs SKIP / SELECTED with reason. Makes
#                  it trivial to see why a dongle wasn't picked up
#                  on a specific Mac.
#                - Added defensive exclusions: vmnet*, ipsec*,
#                  pktap* devices; *WWAN*, *Cellular*, *Modem*,
#                  *AirPort* port names.
# Version: 2.7 - Service-order-aware slot selection
#                - get_active_ethernet_mac() now captures the active
#                  Ethernet adapter's position in
#                  `networksetup -listnetworkserviceorder`
#                  (ACTIVE_INTERFACE_POSITION).
#                - do_update() maps that position to the target Jamf
#                  field: position 1 -> mac_address (primary);
#                  position 2+ -> alt_mac_address.
#                - put_macs() takes a slot argument and emits the
#                  matching <mac_address> or <alt_mac_address> field
#                  only. The other slot is preserved by Jamf.
#                - Drift comparison reads only the slot we plan to
#                  write, so an unmanaged-slot value never triggers
#                  a PUT.
# Version: 2.6 - Stop modifying alt_mac_address
#                - put_macs now writes only mac_address (primary).
#                  alt_mac_address is left untouched on the Jamf
#                  record. Avoids any uniqueness conflict between the
#                  two slots when both held the same value.
#                - Drift comparison checks primary only; alt is read
#                  and logged for awareness but not acted on.
# Version: 2.5 - MAC case normalization + PUT 409 diagnostics
#                - Uppercase the active Ethernet MAC at capture
#                  (ifconfig outputs lowercase; Jamf stores uppercase)
#                - Uppercase Jamf-returned primary/alt before drift
#                  comparison (case-insensitive match avoids spurious
#                  PUTs when only the case differs)
#                - put_macs now logs the HTTP response body when the
#                  request fails, so 409 / 4xx rejections show Jamf's
#                  actual error message instead of just the status code
#                - Re-added TR readonly binary path (needed by the new
#                  response-body logging in put_macs)
# Version: 2.4 - Cleanup + dead-code removal
#                - Dropped unused readonly declarations: SCUTIL, TR,
#                  TEE binary paths and the TIMESTAMP constant
#                - Removed dead `[[ -n "${LOG_FILE}" ]]` check in
#                  log_write (LOG_FILE is always set)
#                - Simplified silent-curl pattern: dropped redundant
#                  `--output /dev/null` paired with `>/dev/null 2>&1`
#                - Explicit `return 0` on start_cisco_vpn
# Version: 2.3 - Removed Configuration Profile dependency
#                - OAuth credentials now hardcoded in this script
#                  (see "OAuth credentials" block in Core Defined
#                  Variables) — eliminates managed-prefs delivery as
#                  a failure mode
#                - load_config() simplified: validates hardcoded creds,
#                  reads JSS URL + serial; no longer touches
#                  /Library/Managed Preferences
#                - Removed config_missing / config_invalid state values;
#                  added creds_missing for the unreplaced-placeholder case
# Version: 2.2 - Self-contained install
#                - Script now writes its own LaunchDaemon plist via
#                  heredoc; no external plist deployment required
#                - Script self-installs to INSTALL_SCRIPT_PATH on first
#                  run (deployable as a single Jamf Script payload —
#                  no .pkg, no separate plist file, no wrapper)
#                - Mode dispatch detects Jamf invocation ($1 = mount
#                  point) and defaults to --install in that context
# Version: 2.1 - Project rename from ise-mac-keeper to Cisco_ISE_MAC_SYNC
#                - Adopt ORG_NAME / ORG_PLIST_DOMAIN convention
#                - Add PROJECT_NAME constant; derive paths/labels from it
#                - Hoist cleanup trap to global scope
# Version: 2.0 - Full rewrite
#                - LaunchDaemon-driven (WatchPaths jamf.log + network)
#                - OAuth 2.0 client credentials (no Basic Auth)
#                - Classic API PUT (MAC fields are not writable via
#                  modern API); Bearer token on Classic endpoints
#                - GET-then-PUT: skip write when record already correct
#                - Cisco Secure Client VPN aware (kill/restart only
#                  when Jamf unreachable AND VPN is not connected)
#                - Managed Preferences (Configuration Profile) for
#                  OAuth client secret storage
#                - State plist + dedicated log file for Extension
#                  Attribute visibility
#                - --uninstall for Self Service remediation
#
# Requirements:
#   - Runs as root (Jamf policy for --install/--uninstall; LaunchDaemon for --run)
#   - Mac enrolled in Jamf Pro (jss_url in com.jamfsoftware.jamf.plist)
#   - jq in PATH (ships with macOS 15+; install separately on older macOS)
#   - Jamf Pro API Client (Read Computers + Update Computers); its ID and
#     secret replace the REPLACE-WITH-* placeholders in this script
#   - Jamf parameter $4 (optional): mode override (install, uninstall);
#     defaults to install when run as a Jamf Script payload
#   - Cisco Secure Client / AnyConnect (optional; VPN-aware logic is
#     disabled when absent)
#   - Network: HTTPS to the Jamf Pro server (e.g. https://your-instance.jamfcloud.com)
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
# awk programs are invoked through "${AWK}", so ShellCheck cannot tell that
# their single-quoted $fields are awk syntax, not shell (SC2016).
# This directive sits before the first command, so it applies file-wide.
# shellcheck disable=SC2230,SC2155,SC2016
set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly CAT=$(which cat)
readonly CHMOD=$(which chmod)
readonly CHOWN=$(which chown)
readonly CP=$(which cp)
readonly CURL=$(which curl)
readonly DATE=$(which date)
readonly DEFAULTS=$(which defaults)
readonly GREP=$(which grep)
readonly HEAD=$(which head)
readonly ID=$(which id)
readonly IFCONFIG=$(which ifconfig)
readonly JQ=$(which jq)
readonly KILL=$(which kill)
readonly LAUNCHCTL=$(which launchctl)
readonly LOGGER=$(which logger)
readonly MKDIR=$(which mkdir)
readonly MKTEMP=$(which mktemp)
readonly NETWORKSETUP=$(which networksetup)
readonly PGREP=$(which pgrep)
readonly PLUTIL=$(which plutil)
readonly RM=$(which rm)
readonly SED=$(which sed)
readonly SLEEP=$(which sleep)
readonly SYSTEM_PROFILER=$(which system_profiler)
readonly TEE=$(which tee)
readonly TR=$(which tr)
readonly XMLLINT=$(which xmllint)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY: human-readable display name; MAY contain spaces.
# ORG_NAME: path-safe — ORG_NAME_FRIENDLY with spaces removed — used in
#   /Library/Application Support/${ORG_NAME}/... (derived, never set by hand).
# ORG_PLIST_DOMAIN: reverse-DNS — used for the LaunchDaemon label and the
#   unified-log tag. e.g. "com.example".
# These MUST match the Cleanup script and both Extension Attributes.
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: your organization's display name
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"      # CHANGE_ME: your reverse-DNS domain
readonly SCRIPT_DIR="_SCRIPTS"
# Project identity
readonly PROJECT_NAME="Cisco_ISE_MAC_SYNC"
readonly PROJECT_SLUG="cisco-ise-mac-sync"

readonly SCRIPT_NAME=$("${BASENAME}" "${0}")
readonly SCRIPT_VERSION="2.11"
readonly JAMF_LOG="/var/log/jamf.log"

# Bundle / labels — shared between this script, the LaunchDaemon plist
# Label, the unified-log tag, and the Extension Attributes. Hardcoded
# as a single source of truth.
readonly BUNDLE_ID="${ORG_PLIST_DOMAIN}.${PROJECT_SLUG}"
readonly DAEMON_LABEL="${BUNDLE_ID}"
readonly LOG_LABEL="${BUNDLE_ID}"

declare -a TEMP_FILES=()

# Set to "true" only in --install / --uninstall (Jamf policy context).
# --run must never write jamf.log: the LaunchDaemon WatchPaths it.
LOG_TO_JAMF="false"

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# --- Install layout ----------------------------------------------------------
readonly INSTALL_DIR="/Library/Application Support/${ORG_NAME}/${SCRIPT_DIR}/${PROJECT_NAME}"
readonly INSTALL_SCRIPT_NAME="Cisco-ISE-MAC-Sync.sh"
readonly INSTALL_SCRIPT_PATH="${INSTALL_DIR}/${INSTALL_SCRIPT_NAME}"
# Pre-2.11 installs used ${PROJECT_NAME}.sh; --install removes that copy on upgrade.
readonly LEGACY_INSTALL_SCRIPT_PATH="${INSTALL_DIR}/${PROJECT_NAME}.sh"
readonly STATE_PLIST="${INSTALL_DIR}/state.plist"
readonly DAEMON_PLIST_PATH="/Library/LaunchDaemons/${BUNDLE_ID}.plist"
readonly LOG_FILE="/var/log/${BUNDLE_ID}.log"
readonly LOCK_FILE="/var/run/${BUNDLE_ID}.pid"
readonly DEBOUNCE_FILE="/var/run/${BUNDLE_ID}.debounce"

# --- Jamf parameters ---------------------------------------------------------
# $1-$3 are reserved by Jamf (mount point, computer name, username).
# $4 (optional): mode override when run as a Jamf Script payload.
readonly PARAM_MODE="${4:-}"

# --- OAuth credentials -------------------------------------------------------
# !!! SECURITY NOTICE !!!
# Jamf script parameters are not available to the LaunchDaemon --run
# context, so this script uses the "embedded credentials" pattern: the
# committed source carries placeholders only, and load_config() refuses
# to run (state creds_missing) until they are replaced at deployment.
#
# Once replaced, these credentials are baked into the script body. Anyone with "Read
# Scripts" permission in Jamf Pro can read them. Restrict that role
# accordingly. The credentials are also written to disk at
# INSTALL_SCRIPT_PATH (mode 0755, owner root:wheel) — local users with
# `cat` access to that path will see them.
#
# To rotate:
#   1. Generate a new client secret in Jamf Pro
#      (Settings → System → API roles and clients → <your API client>
#      → Generate Client Secret).
#   2. Replace CLIENT_SECRET below.
#   3. Re-deploy the install policy. The install function will overwrite
#      the on-disk copy with the new credentials and reload the daemon.
#
# The dedicated API Client should be restricted to an API Role with only
# "Read Computers" + "Update Computers" privileges.
readonly CLIENT_ID="REPLACE-WITH-JAMF-API-CLIENT-ID"            # CHANGE_ME: Jamf Pro API client ID
readonly CLIENT_SECRET="REPLACE-WITH-JAMF-API-CLIENT-SECRET"    # CHANGE_ME: Jamf Pro API client secret

# --- Behavior tuning ---------------------------------------------------------
readonly DEBOUNCE_SECONDS=10
readonly SETTLE_SECONDS=5
readonly CURL_CONNECT_TIMEOUT=10
readonly CURL_MAX_TIME=30
readonly PROBE_CONNECT_TIMEOUT=3
readonly PROBE_MAX_TIME=5
readonly PUT_MAX_ATTEMPTS=3
readonly VPN_RECONNECT_WAIT_SECONDS=60
readonly JAMF_IDLE_WAIT_SECONDS=150
readonly JAMF_IDLE_POLL_SECONDS=5

# --- Cisco Secure Client paths (detected at runtime) -------------------------
CISCO_VPN_CLI=""
CISCO_DAEMON_LABEL=""
CISCO_DAEMON_PLIST=""

# --- Runtime state -----------------------------------------------------------
ACCESS_TOKEN=""
JAMF_URL=""
SERIAL=""
CURRENT_PRIMARY=""
CURRENT_ALT=""
ACTIVE_INTERFACE_MAC=""
ACTIVE_INTERFACE_DEVICE=""
ACTIVE_INTERFACE_PORT=""
ACTIVE_INTERFACE_POSITION=""
VPN_STATE=""
LOCK_ACQUIRED="false"
VPN_KILLED="false"

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

# ── Logging (unified log + dedicated file, + jamf.log in policy modes) ──────
# Writes to the unified log and the dedicated LOG_FILE. When LOG_TO_JAMF is
# "true" (--install / --uninstall, i.e. Jamf policy context) the line is also
# tee'd to /var/log/jamf.log and stdout so it shows in the Jamf policy log.
# In --run mode nothing goes to stdout (the LaunchDaemon redirects stdout to
# LOG_FILE, which would duplicate lines) and nothing goes to jamf.log.
log_write() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$("${DATE}" +"%Y-%m-%d %H:%M:%S")
    local level_upper=""
    local syslog_pri=""

    case "${level}" in
        info)
            level_upper="INFO"
            syslog_pri="user.info"
            ;;
        warn)
            level_upper="WARN"
            syslog_pri="user.warning"
            ;;
        error)
            level_upper="ERROR"
            syslog_pri="user.err"
            ;;
        debug)
            level_upper="DEBUG"
            syslog_pri="user.debug"
            ;;
        *)
            level_upper="INFO"
            syslog_pri="user.info"
            ;;
    esac

    "${LOGGER}" -t "${LOG_LABEL}" -p "${syslog_pri}" "[${level_upper}] ${msg}"

    # Append to dedicated file log; tolerate write failure (e.g. log
    # rotation in flight) so logging never aborts the run.
    # stderr is redirected first so a failed open (e.g. non-root --status)
    # is silenced too.
    printf '%s [%s] %s\n' "${ts}" "${level_upper}" "${msg}" 2>/dev/null >> "${LOG_FILE}" || true

    if [[ "${LOG_TO_JAMF}" == "true" ]]
    then
        printf '%s %s[%s]: [%s] %s\n' "${ts}" "${SCRIPT_NAME}" "$$" "${level_upper}" "${msg}" \
            | "${TEE}" -ai "${JAMF_LOG}" 2>/dev/null || true
    fi
}

log_info() {
    log_write info "$@"
}

log_warn() {
    log_write warn "$@"
}

log_error() {
    log_write error "$@"
}

log_debug() {
    log_write debug "$@"
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
cleanup() {
    local exit_code=$?

    invalidate_access_token

    local f
    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -n "${f}" && -f "${f}" ]]
        then
            "${RM}" -f "${f}"
        fi
    done

    release_lock

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

require_jq() {
    if [[ -z "${JQ}" || ! -x "${JQ}" ]]
    then
        log_error "jq is required but not found in PATH"
        exit 1
    fi
}

ensure_directories() {
    if [[ ! -d "${INSTALL_DIR}" ]]
    then
        "${MKDIR}" -p "${INSTALL_DIR}"
        "${CHOWN}" root:wheel "${INSTALL_DIR}"
        "${CHMOD}" 755 "${INSTALL_DIR}"
    fi

    if [[ ! -f "${LOG_FILE}" ]]
    then
        : > "${LOG_FILE}"
        "${CHOWN}" root:wheel "${LOG_FILE}"
        "${CHMOD}" 644 "${LOG_FILE}"
    fi
}

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

# ── Lock / debounce ──────────────────────────────────────────────────────────
acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]
    then
        local existing_pid
        existing_pid=$("${CAT}" "${LOCK_FILE}" 2>/dev/null || echo "")
        if [[ -n "${existing_pid}" ]]
        then
            if "${KILL}" -0 "${existing_pid}" 2>/dev/null
            then
                log_info "Another instance already running (PID ${existing_pid}); exiting"
                exit 0
            fi
        fi
    fi

    printf '%s' "$$" > "${LOCK_FILE}"
    "${CHMOD}" 644 "${LOCK_FILE}"
    LOCK_ACQUIRED="true"
}

release_lock() {
    if [[ "${LOCK_ACQUIRED}" == "true" ]]
    then
        "${RM}" -f "${LOCK_FILE}"
        LOCK_ACQUIRED="false"
    fi
}

check_debounce() {
    local now
    now=$("${DATE}" +%s)

    if [[ -f "${DEBOUNCE_FILE}" ]]
    then
        local last
        last=$("${CAT}" "${DEBOUNCE_FILE}" 2>/dev/null || echo "0")
        if [[ -n "${last}" && "${last}" =~ ^[0-9]+$ ]]
        then
            local delta=$((now - last))
            if [[ "${delta}" -lt "${DEBOUNCE_SECONDS}" ]]
            then
                log_debug "Debounce window active (${delta}s < ${DEBOUNCE_SECONDS}s); exiting"
                exit 0
            fi
        fi
    fi

    printf '%s' "${now}" > "${DEBOUNCE_FILE}"
    "${CHMOD}" 644 "${DEBOUNCE_FILE}"
}

# ── Wait for jamf binary to finish ───────────────────────────────────────────
# When WatchPaths triggers us on a jamf.log write during an in-progress recon,
# we must wait for the recon to post its data to the server (which includes
# the revert to built-in MAC) before we GET-and-fix. Otherwise we'd read the
# pre-revert state, see "already correct," skip the PUT, and leave Jamf in
# the wrong state until the next trigger. This is critical because ISE is
# also gating the wired LAN via MAC -> Jamf lookup — every second Jamf is
# wrong is a second the switch can drop the user.
wait_for_jamf_idle() {
    if ! "${PGREP}" -x "jamf" >/dev/null 2>&1
    then
        log_debug "jamf process not running; proceeding"
        return 0
    fi

    log_info "jamf process is running; waiting up to ${JAMF_IDLE_WAIT_SECONDS}s for it to finish"

    local elapsed=0
    while [[ "${elapsed}" -lt "${JAMF_IDLE_WAIT_SECONDS}" ]]
    do
        "${SLEEP}" "${JAMF_IDLE_POLL_SECONDS}"
        elapsed=$((elapsed + JAMF_IDLE_POLL_SECONDS))

        if ! "${PGREP}" -x "jamf" >/dev/null 2>&1
        then
            log_info "jamf process exited after ${elapsed}s"
            # Give the server a beat to commit the revert before we GET.
            "${SLEEP}" 3
            return 0
        fi
    done

    log_warn "jamf process still running after ${JAMF_IDLE_WAIT_SECONDS}s; proceeding anyway"
    return 0
}

# ── Config loading ───────────────────────────────────────────────────────────
load_config() {
    # Validate hardcoded OAuth credentials have been replaced from
    # placeholder values before deployment. CLIENT_ID and CLIENT_SECRET
    # are readonly constants set in Core Defined Variables.
    if [[ "${CLIENT_ID}" == REPLACE-* || "${CLIENT_SECRET}" == REPLACE-* || -z "${CLIENT_ID}" || -z "${CLIENT_SECRET}" ]]
    then
        log_error "OAuth credentials not configured: CLIENT_ID and/or CLIENT_SECRET still hold placeholder values"
        log_error "Edit ${SCRIPT_NAME} and replace CLIENT_ID / CLIENT_SECRET with real values, then re-deploy"
        write_state "creds_missing" "" "" ""
        exit 1
    fi

    JAMF_URL=$("${DEFAULTS}" read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null | "${SED}" -e 's#/$##' || echo "")

    if [[ -z "${JAMF_URL}" ]]
    then
        log_error "Unable to read Jamf URL from com.jamfsoftware.jamf.plist; is this Mac enrolled?"
        write_state "jamf_url_missing" "" "" ""
        exit 1
    fi

    SERIAL=$("${SYSTEM_PROFILER}" SPHardwareDataType 2>/dev/null \
        | "${AWK}" '/Serial Number \(system\)/ {print $NF; exit}')

    if [[ -z "${SERIAL}" ]]
    then
        log_error "Unable to determine system serial number"
        write_state "serial_missing" "" "" ""
        exit 1
    fi

    log_info "Loaded config: jamf_url=${JAMF_URL}, serial=${SERIAL}"
}

# ── Cisco Secure Client detection ───────────────────────────────────────────
detect_cisco_paths() {
    local candidate_cli_new="/opt/cisco/secureclient/bin/vpn"
    local candidate_cli_old="/opt/cisco/anyconnect/bin/vpn"
    local candidate_daemon_new="/Library/LaunchDaemons/com.cisco.secureclient.vpnagentd.plist"
    local candidate_daemon_old="/Library/LaunchDaemons/com.cisco.anyconnect.vpnagentd.plist"

    if [[ -x "${candidate_cli_new}" ]]
    then
        CISCO_VPN_CLI="${candidate_cli_new}"
        CISCO_DAEMON_LABEL="com.cisco.secureclient.vpnagentd"
        CISCO_DAEMON_PLIST="${candidate_daemon_new}"
    elif [[ -x "${candidate_cli_old}" ]]
    then
        CISCO_VPN_CLI="${candidate_cli_old}"
        CISCO_DAEMON_LABEL="com.cisco.anyconnect.vpnagentd"
        CISCO_DAEMON_PLIST="${candidate_daemon_old}"
    else
        log_warn "Cisco Secure Client / AnyConnect CLI not found; VPN-aware logic disabled"
    fi
}

# ── Interface selection ──────────────────────────────────────────────────────
# Walks `networksetup -listnetworkserviceorder` and picks the first service
# whose underlying interface has `status: active` and a valid MAC, after
# filtering out everything that ISN'T a wired Ethernet adapter.
#
# Detection strategy: EXCLUSION MODEL.
# We never enumerate vendor names — there are too many. Instead we drop
# everything that's known not to be a wired adapter and treat what's left
# as Ethernet. This means any USB / USB-C / Thunderbolt Ethernet dongle
# is auto-supported regardless of vendor. Confirmed working: Belkin
# USB-C LAN, Realtek USB GBE, Apple USB-C to Ethernet Adapter, Anker
# USB-C Ethernet, OWC Thunderbolt Ethernet, generic "USB 10/100/1000 LAN".
# New vendor naming will work without code change.
#
# What gets EXCLUDED:
#   By BSD device name (regex):
#     bridge*  utun*  ppp*  tap*  tun*  gif*  stf*  lo*  awdl*  llw*
#     anpi*  vmnet*  ipsec*  pktap*
#   By Hardware Port name (substring, case-sensitive):
#     Wi-Fi, AirPort, Bluetooth, iPhone, USB Tether, Personal Hotspot,
#     Thunderbolt Bridge, WWAN, Cellular, Modem
#
# Link-state requirement: `status: active`. We do NOT require an IP —
# an ISE-blocked dongle will have link up and no DHCP lease, but we
# still want its MAC pushed to Jamf so the record is correct when the
# dongle is later added to ISE's allowlist. Connectivity to Jamf itself
# comes from whatever default route works (Wi-Fi, VPN, other Ethernet),
# not this interface.
#
# Per-candidate decisions are emitted as DEBUG log entries — review the
# script's log to see exactly which adapters were considered and why
# any were skipped.
#
# Sets ACTIVE_INTERFACE_MAC, ACTIVE_INTERFACE_DEVICE, ACTIVE_INTERFACE_PORT,
# and ACTIVE_INTERFACE_POSITION as globals. The position is the
# 1-indexed rank in the service order and drives Jamf-slot selection
# in do_update (position 1 -> mac_address; position 2+ -> alt_mac_address).
# Returns 0 when an adapter is selected; 1 otherwise. It logs, so it must be
# called directly — never captured via $(...), which would run it in a
# subshell and lose the globals.
get_active_ethernet_mac() {
    ACTIVE_INTERFACE_MAC=""
    ACTIVE_INTERFACE_DEVICE=""
    ACTIVE_INTERFACE_PORT=""
    ACTIVE_INTERFACE_POSITION=""

    local wifi_device=""
    wifi_device=$("${NETWORKSETUP}" -listallhardwareports 2>/dev/null \
        | "${AWK}" 'BEGIN{RS=""} /Hardware Port: Wi-Fi/ { for (i=1; i<=NF; i++) if ($i=="Device:") { print $(i+1); exit } }')

    local service_order
    service_order=$("${NETWORKSETUP}" -listnetworkserviceorder 2>/dev/null || echo "")

    if [[ -z "${service_order}" ]]
    then
        log_warn "networksetup -listnetworkserviceorder returned nothing"
        return 1
    fi

    log_debug "Walking service order to find active Ethernet adapter (wifi_device=${wifi_device:-none})"

    local line=""
    # Service-order position of the most recently seen "(N) Service Name"
    # line. The networksetup output pairs each "(N) Name" line with the
    # following "(Hardware Port: ..., Device: ...)" line, so we capture
    # N when we see it and apply it when we hit the matching hardware
    # port line.
    local current_position=0

    while IFS= read -r line
    do
        # Position marker line, e.g. "(2) USB 10/100/1000 LAN"
        if [[ "${line}" =~ ^\(([0-9]+)\)[[:space:]] ]]
        then
            current_position="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "${line}" =~ ^\(Hardware[[:space:]]Port:[[:space:]](.+),[[:space:]]Device:[[:space:]]([^\)]+)\) ]]
        then
            local port="${BASH_REMATCH[1]}"
            local dev="${BASH_REMATCH[2]}"
            local prefix="  pos=${current_position} dev=${dev} port=\"${port}\""

            if [[ -n "${wifi_device}" && "${dev}" == "${wifi_device}" ]]
            then
                log_debug "${prefix} -> SKIP (Wi-Fi device per -listallhardwareports)"
                continue
            fi

            case "${dev}" in
                bridge*|utun*|ppp*|tap*|tun*|gif*|stf*|lo*|awdl*|llw*|anpi*|vmnet*|ipsec*|pktap*)
                    log_debug "${prefix} -> SKIP (excluded device prefix)"
                    continue
                    ;;
            esac

            case "${port}" in
                *Wi-Fi*|*AirPort*|*Bluetooth*|*iPhone*|*"USB Tether"*|*"Personal Hotspot"*|*"Thunderbolt Bridge"*|*WWAN*|*Cellular*|*Modem*)
                    log_debug "${prefix} -> SKIP (excluded port name pattern)"
                    continue
                    ;;
            esac

            local ifout
            ifout=$("${IFCONFIG}" "${dev}" 2>/dev/null || echo "")

            if [[ -z "${ifout}" ]]
            then
                log_debug "${prefix} -> SKIP (ifconfig produced no output)"
                continue
            fi

            # Require link up; do NOT require an IP. An ISE-blocked dongle
            # will have link up and no DHCP lease — we still want its MAC.
            if ! printf '%s\n' "${ifout}" | "${GREP}" -q "status: active"
            then
                log_debug "${prefix} -> SKIP (link not active)"
                continue
            fi

            # Capture and uppercase. ifconfig emits lowercase MACs; Jamf
            # stores and validates them as uppercase. Using uppercase here
            # makes the drift comparison case-aligned with Jamf's record
            # and avoids Jamf rejecting the PUT on strict format checks.
            local mac
            mac=$(printf '%s\n' "${ifout}" | "${AWK}" '/^[[:space:]]*ether /{print toupper($2); exit}')

            if [[ -z "${mac}" || "${mac}" == "00:00:00:00:00:00" ]]
            then
                log_debug "${prefix} -> SKIP (no valid MAC in ifconfig output)"
                continue
            fi

            local has_ip="no"
            if printf '%s\n' "${ifout}" | "${GREP}" -qE "^[[:space:]]*inet "
            then
                has_ip="yes"
            fi

            ACTIVE_INTERFACE_MAC="${mac}"
            ACTIVE_INTERFACE_DEVICE="${dev}"
            ACTIVE_INTERFACE_PORT="${port}"
            ACTIVE_INTERFACE_POSITION="${current_position}"
            log_info "${prefix} -> SELECTED mac=${mac} has_ip=${has_ip}"
            return 0
        fi
    done <<< "${service_order}"

    log_debug "Walked entire service order; no active Ethernet adapter selected"
    return 1
}

# ── VPN state / control ──────────────────────────────────────────────────────
# Sets VPN_STATE (connected / disconnected / connecting / reconnecting /
# disconnecting / unknown). Call directly; do not capture via $(...).
get_vpn_state() {
    VPN_STATE="unknown"

    if [[ -z "${CISCO_VPN_CLI}" || ! -x "${CISCO_VPN_CLI}" ]]
    then
        VPN_STATE="unknown"
        return 0
    fi

    local state_output
    state_output=$("${CISCO_VPN_CLI}" state 2>/dev/null || echo "")

    if [[ -z "${state_output}" ]]
    then
        log_debug "vpn state returned no output"
        VPN_STATE="unknown"
        return 0
    fi

    local state_line
    state_line=$(printf '%s\n' "${state_output}" \
        | "${GREP}" -iE "^[[:space:]]*(>>[[:space:]])?state:" \
        | "${HEAD}" -n 1 \
        | "${AWK}" -F ':' '{ gsub(/^[ \t]+|[ \t]+$/, "", $NF); print tolower($NF) }')

    case "${state_line}" in
        *connected*)
            if [[ "${state_line}" == *"disconnected"* ]]
            then
                VPN_STATE="disconnected"
            elif [[ "${state_line}" == *"reconnecting"* ]]
            then
                VPN_STATE="reconnecting"
            elif [[ "${state_line}" == *"disconnecting"* ]]
            then
                VPN_STATE="disconnecting"
            elif [[ "${state_line}" == *"connecting"* ]]
            then
                VPN_STATE="connecting"
            else
                VPN_STATE="connected"
            fi
            ;;
        *)
            log_debug "vpn state did not match known patterns; state_line=\"${state_line}\""
            VPN_STATE="unknown"
            ;;
    esac
}

# Tracks how the VPN was suspended so start_cisco_vpn knows how to restore.
# "disconnect" = agent still alive; reconnect via `vpn connect`.
# "bootout"    = agent killed; restart via launchctl bootstrap.
VPN_SUSPEND_METHOD=""

stop_cisco_vpn() {
    if [[ -z "${CISCO_DAEMON_LABEL}" ]]
    then
        log_warn "Cisco daemon label not set; cannot stop VPN agent"
        return 1
    fi

    # PHASE 1: graceful CLI disconnect.
    # On Macs where the Cisco watchdog respawns vpnagentd after launchctl
    # bootout, this is the only approach that works. The agent stays
    # running, the tunnel drops, and Always-On fail-closed lifts —
    # restoring the local default route long enough for the Jamf API
    # call. Watchdog has nothing to respawn since the agent never died.
    if [[ -n "${CISCO_VPN_CLI}" && -x "${CISCO_VPN_CLI}" ]]
    then
        log_info "Disconnecting Cisco VPN tunnel via ${CISCO_VPN_CLI} disconnect"
        if "${CISCO_VPN_CLI}" disconnect >/dev/null 2>&1
        then
            "${SLEEP}" 3
            VPN_KILLED="true"
            VPN_SUSPEND_METHOD="disconnect"
            log_info "VPN tunnel disconnected; agent left running"
            return 0
        else
            log_warn "vpn disconnect returned non-zero; falling back to launchctl bootout"
        fi
    else
        log_warn "Cisco VPN CLI not available; using launchctl bootout directly"
    fi

    # PHASE 2: launchctl bootout fallback.
    # Used when the CLI disconnect is unavailable or fails. May not work
    # on Macs whose Cisco config has watchdog protection enabled — those
    # will see vpnagentd respawn within ~1s and we'll fail back out.
    log_warn "Stopping Cisco VPN agent (${CISCO_DAEMON_LABEL}) via launchctl bootout"

    if "${LAUNCHCTL}" print "system/${CISCO_DAEMON_LABEL}" >/dev/null 2>&1
    then
        "${LAUNCHCTL}" bootout "system/${CISCO_DAEMON_LABEL}" 2>/dev/null || true
    fi

    "${SLEEP}" 3

    if "${PGREP}" -x "vpnagentd" >/dev/null 2>&1
    then
        log_warn "vpnagentd still running after bootout; Cisco watchdog may be respawning it"
        return 1
    fi

    VPN_KILLED="true"
    VPN_SUSPEND_METHOD="bootout"
    return 0
}

start_cisco_vpn() {
    # If we used the graceful disconnect path, the agent is still alive
    # — just tell it to reconnect. Always-On profiles will pick up the
    # last-used host automatically.
    if [[ "${VPN_SUSPEND_METHOD}" == "disconnect" ]]
    then
        if [[ -n "${CISCO_VPN_CLI}" && -x "${CISCO_VPN_CLI}" ]]
        then
            log_info "Reconnecting Cisco VPN tunnel via ${CISCO_VPN_CLI} connect"
            "${CISCO_VPN_CLI}" connect >/dev/null 2>&1 || true
        else
            log_warn "VPN was disconnected but CLI is now unavailable; relying on Always-On auto-reconnect"
        fi
        VPN_KILLED="false"
        VPN_SUSPEND_METHOD=""
        return 0
    fi

    # Bootout path: the agent was actually killed, so we have to bring
    # the daemon back up via launchctl bootstrap.
    if [[ -z "${CISCO_DAEMON_PLIST}" ]]
    then
        return 1
    fi

    if [[ ! -f "${CISCO_DAEMON_PLIST}" ]]
    then
        log_error "Cisco daemon plist missing: ${CISCO_DAEMON_PLIST}"
        return 1
    fi

    log_info "Restarting Cisco VPN agent via launchctl bootstrap"
    "${LAUNCHCTL}" bootstrap system "${CISCO_DAEMON_PLIST}" 2>/dev/null || true
    VPN_KILLED="false"
    VPN_SUSPEND_METHOD=""
    return 0
}

wait_for_vpn_reconnect() {
    local max_wait="${VPN_RECONNECT_WAIT_SECONDS}"
    local elapsed=0

    while [[ "${elapsed}" -lt "${max_wait}" ]]
    do
        get_vpn_state
        if [[ "${VPN_STATE}" == "connected" ]]
        then
            log_info "VPN reached connected state after ${elapsed}s"
            return 0
        fi
        "${SLEEP}" 5
        elapsed=$((elapsed + 5))
    done

    get_vpn_state
    log_warn "VPN did not reach connected state within ${max_wait}s (final state: ${VPN_STATE})"
    return 1
}

# ── Network probe ────────────────────────────────────────────────────────────
probe_jamf_reachable() {
    "${CURL}" -sS \
        --connect-timeout "${PROBE_CONNECT_TIMEOUT}" \
        --max-time "${PROBE_MAX_TIME}" \
        --head \
        "${JAMF_URL}/" >/dev/null 2>&1
}

# ── OAuth ────────────────────────────────────────────────────────────────────
get_access_token() {
    local response_file
    response_file=$("${MKTEMP}")
    TEMP_FILES+=("${response_file}")

    local http_code
    http_code=$("${CURL}" -sS \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "client_secret=${CLIENT_SECRET}" \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        --output "${response_file}" \
        --write-out "%{http_code}" \
        "${JAMF_URL}/api/oauth/token" 2>/dev/null || echo "000")

    if [[ "${http_code}" != "200" ]]
    then
        log_error "OAuth token request failed: HTTP ${http_code}"
        return 1
    fi

    ACCESS_TOKEN=$("${JQ}" -r '.access_token // empty' "${response_file}" 2>/dev/null || echo "")

    if [[ -z "${ACCESS_TOKEN}" ]]
    then
        log_error "OAuth response missing access_token"
        return 1
    fi

    log_debug "OAuth token acquired"
    return 0
}

invalidate_access_token() {
    if [[ -z "${ACCESS_TOKEN}" || -z "${JAMF_URL}" ]]
    then
        return 0
    fi

    "${CURL}" -sS \
        -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        "${JAMF_URL}/api/v1/auth/invalidate-token" >/dev/null 2>&1 || true

    ACCESS_TOKEN=""
    log_debug "OAuth token invalidated"
}

# ── Jamf Classic API (GET-then-PUT) ──────────────────────────────────────────
get_current_macs() {
    local response_file
    response_file=$("${MKTEMP}")
    TEMP_FILES+=("${response_file}")

    local http_code
    http_code=$("${CURL}" -sS \
        -X GET \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/xml" \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        --output "${response_file}" \
        --write-out "%{http_code}" \
        "${JAMF_URL}/JSSResource/computers/serialnumber/${SERIAL}/subset/general" 2>/dev/null || echo "000")

    if [[ "${http_code}" != "200" ]]
    then
        log_error "GET computer record failed: HTTP ${http_code}"
        return 1
    fi

    # Normalize to uppercase so the drift comparison is case-insensitive
    # against the active Ethernet MAC (also uppercase per
    # get_active_ethernet_mac).
    CURRENT_PRIMARY=$("${XMLLINT}" --xpath "string(//computer/general/mac_address)" "${response_file}" 2>/dev/null \
        | "${AWK}" '{print toupper($0)}' || echo "")
    CURRENT_ALT=$("${XMLLINT}" --xpath "string(//computer/general/alt_mac_address)" "${response_file}" 2>/dev/null \
        | "${AWK}" '{print toupper($0)}' || echo "")

    log_debug "Current Jamf record: primary=${CURRENT_PRIMARY}, alt=${CURRENT_ALT}"
    return 0
}

put_macs() {
    local target_mac="$1"
    local target_slot="$2"   # "primary" or "alt"

    local field_name
    case "${target_slot}" in
        primary)
            field_name="mac_address"
            ;;
        alt)
            field_name="alt_mac_address"
            ;;
        *)
            log_error "put_macs called with invalid slot: ${target_slot}"
            return 1
            ;;
    esac

    local payload_file
    payload_file=$("${MKTEMP}")
    TEMP_FILES+=("${payload_file}")

    # Emit only the chosen slot. The omitted slot is preserved by Jamf —
    # Classic API PUT only updates fields included in the payload.
    printf '<computer><general><%s>%s</%s></general></computer>' \
        "${field_name}" "${target_mac}" "${field_name}" > "${payload_file}"

    local response_file
    response_file=$("${MKTEMP}")
    TEMP_FILES+=("${response_file}")

    local http_code
    http_code=$("${CURL}" -sS \
        -X PUT \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/xml" \
        --data-binary "@${payload_file}" \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        --output "${response_file}" \
        --write-out "%{http_code}" \
        "${JAMF_URL}/JSSResource/computers/serialnumber/${SERIAL}/subset/general" 2>/dev/null || echo "000")

    if [[ "${http_code}" != "201" && "${http_code}" != "200" ]]
    then
        # Read up to 1KB of the response body so 4xx/5xx rejections
        # surface Jamf's actual error string (e.g. "Conflict — The MAC
        # Address is already in use") in the log instead of just the
        # status code.
        local body
        body=$("${HEAD}" -c 1024 "${response_file}" 2>/dev/null \
            | "${TR}" -d '\n\r' || echo "")
        log_error "PUT computer record failed: HTTP ${http_code} body=${body}"
        return 1
    fi

    return 0
}

# ── State plist (consumed by Extension Attributes) ───────────────────────────
write_state() {
    local status="$1"
    local mac="$2"
    local iface="$3"
    local port="$4"
    local now
    now=$("${DATE}" -u +%Y-%m-%dT%H:%M:%SZ)

    "${DEFAULTS}" write "${STATE_PLIST}" LastRunStatus -string "${status}"
    "${DEFAULTS}" write "${STATE_PLIST}" LastRunTimestamp -string "${now}"
    "${DEFAULTS}" write "${STATE_PLIST}" LastRunMAC -string "${mac}"
    "${DEFAULTS}" write "${STATE_PLIST}" LastRunInterface -string "${iface}"
    "${DEFAULTS}" write "${STATE_PLIST}" LastRunPort -string "${port}"
    "${DEFAULTS}" write "${STATE_PLIST}" ScriptVersion -string "${SCRIPT_VERSION}"

    "${PLUTIL}" -convert xml1 "${STATE_PLIST}" >/dev/null 2>&1 || true
    "${CHOWN}" root:wheel "${STATE_PLIST}" 2>/dev/null || true
    "${CHMOD}" 644 "${STATE_PLIST}" 2>/dev/null || true
}

# ── Core update flow ─────────────────────────────────────────────────────────
do_update() {
    local target_mac=""

    if ! get_active_ethernet_mac
    then
        log_info "No active Ethernet interface detected; nothing to do"
        write_state "no_ethernet" "" "" ""
        return 0
    fi
    target_mac="${ACTIVE_INTERFACE_MAC}"

    # Try Jamf first WITHOUT touching VPN.
    # Kill VPN only if Jamf is unreachable AND VPN is not in a connected state.
    if ! probe_jamf_reachable
    then
        get_vpn_state
        local vpn_state="${VPN_STATE}"
        log_warn "Jamf unreachable on initial probe (VPN state: ${vpn_state})"

        if [[ "${vpn_state}" == "connected" ]]
        then
            log_error "VPN reports connected but Jamf is unreachable; skipping update this cycle"
            write_state "jamf_unreachable_vpn_up" "${target_mac}" "${ACTIVE_INTERFACE_DEVICE}" "${ACTIVE_INTERFACE_PORT}"
            return 1
        fi

        if ! stop_cisco_vpn
        then
            log_error "Could not stop Cisco VPN agent; giving up this cycle"
            write_state "vpn_stop_failed" "${target_mac}" "${ACTIVE_INTERFACE_DEVICE}" "${ACTIVE_INTERFACE_PORT}"
            return 1
        fi

        "${SLEEP}" 3

        if ! probe_jamf_reachable
        then
            log_error "Jamf still unreachable after stopping Cisco VPN agent"
            start_cisco_vpn || true
            write_state "jamf_unreachable" "${target_mac}" "${ACTIVE_INTERFACE_DEVICE}" "${ACTIVE_INTERFACE_PORT}"
            return 1
        fi
    fi

    if ! get_access_token
    then
        log_error "OAuth failed; aborting"
        if [[ "${VPN_KILLED}" == "true" ]]
        then
            start_cisco_vpn || true
        fi
        write_state "oauth_failed" "${target_mac}" "${ACTIVE_INTERFACE_DEVICE}" "${ACTIVE_INTERFACE_PORT}"
        return 1
    fi

    if ! get_current_macs
    then
        log_error "Unable to read current Jamf record; aborting"
        if [[ "${VPN_KILLED}" == "true" ]]
        then
            start_cisco_vpn || true
        fi
        write_state "get_failed" "${target_mac}" "${ACTIVE_INTERFACE_DEVICE}" "${ACTIVE_INTERFACE_PORT}"
        return 1
    fi

    # Map the interface's service-order position to the Jamf slot.
    # Position 1 -> mac_address (Jamf treats as primary).
    # Position 2+ -> alt_mac_address.
    # This matches Jamf's recon convention of recording the
    # first-service-order interface in the primary slot.
    local target_slot="primary"
    local current_in_slot="${CURRENT_PRIMARY}"
    local other_label="alt=${CURRENT_ALT}"

    if [[ -n "${ACTIVE_INTERFACE_POSITION}" && "${ACTIVE_INTERFACE_POSITION}" -gt 1 ]]
    then
        target_slot="alt"
        current_in_slot="${CURRENT_ALT}"
        other_label="primary=${CURRENT_PRIMARY}"
    fi

    log_info "Service-order position=${ACTIVE_INTERFACE_POSITION} -> targeting Jamf ${target_slot} slot"

    if [[ "${current_in_slot}" == "${target_mac}" ]]
    then
        log_info "Jamf ${target_slot} slot already correct (${target_mac}); ${other_label} not managed; skipping PUT"
        if [[ "${VPN_KILLED}" == "true" ]]
        then
            start_cisco_vpn || true
            wait_for_vpn_reconnect || true
        fi
        write_state "success_nochange" "${target_mac}" "${ACTIVE_INTERFACE_DEVICE}" "${ACTIVE_INTERFACE_PORT}"
        return 0
    fi

    log_info "MAC drift detected: jamf_${target_slot}=${current_in_slot}, target=${target_mac} (${other_label} will be left untouched)"

    local attempt=1
    local success="false"
    while [[ "${attempt}" -le "${PUT_MAX_ATTEMPTS}" ]]
    do
        if put_macs "${target_mac}" "${target_slot}"
        then
            success="true"
            break
        fi

        if [[ "${attempt}" -lt "${PUT_MAX_ATTEMPTS}" ]]
        then
            local backoff=$((2 ** attempt))
            log_warn "PUT attempt ${attempt} failed; retrying in ${backoff}s"
            "${SLEEP}" "${backoff}"
        fi

        attempt=$((attempt + 1))
    done

    if [[ "${success}" != "true" ]]
    then
        log_error "All ${PUT_MAX_ATTEMPTS} PUT attempts failed"
        if [[ "${VPN_KILLED}" == "true" ]]
        then
            start_cisco_vpn || true
        fi
        write_state "put_failed" "${target_mac}" "${ACTIVE_INTERFACE_DEVICE}" "${ACTIVE_INTERFACE_PORT}"
        return 1
    fi

    log_info "Jamf record updated: ${target_slot}=${target_mac} (${other_label} left untouched)"
    write_state "success" "${target_mac}" "${ACTIVE_INTERFACE_DEVICE}" "${ACTIVE_INTERFACE_PORT}"

    if [[ "${VPN_KILLED}" == "true" ]]
    then
        start_cisco_vpn || true
        wait_for_vpn_reconnect || true
    fi

    return 0
}

# ── Install (self-contained) ─────────────────────────────────────────────────
# Copies this script to INSTALL_SCRIPT_PATH, writes the LaunchDaemon plist
# via heredoc, and bootstraps the daemon. Idempotent — safe to re-run on
# upgrade. Designed to be invoked directly as a Jamf Script payload with
# no additional files to deploy.
write_daemon_plist() {
    "${CAT}" > "${DAEMON_PLIST_PATH}" <<DAEMON_PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_SCRIPT_PATH}</string>
        <string>--run</string>
    </array>

    <key>UserName</key>
    <string>root</string>
    <key>GroupName</key>
    <string>wheel</string>

    <key>WatchPaths</key>
    <array>
        <string>/var/log/jamf.log</string>
        <string>/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist</string>
    </array>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>KeepAlive</key>
    <false/>
    <key>RunAtLoad</key>
    <false/>

    <key>ProcessType</key>
    <string>Background</string>
    <key>Nice</key>
    <integer>5</integer>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>ExitTimeOut</key>
    <integer>30</integer>

    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
DAEMON_PLIST_EOF

    "${CHOWN}" root:wheel "${DAEMON_PLIST_PATH}"
    "${CHMOD}" 644 "${DAEMON_PLIST_PATH}"

    if ! "${PLUTIL}" -lint "${DAEMON_PLIST_PATH}" >/dev/null 2>&1
    then
        log_error "LaunchDaemon plist failed plutil -lint after write: ${DAEMON_PLIST_PATH}"
        return 1
    fi

    return 0
}

do_install() {
    log_info "Installing ${BUNDLE_ID} v${SCRIPT_VERSION}"

    "${MKDIR}" -p "${INSTALL_DIR}"
    "${CHOWN}" root:wheel "${INSTALL_DIR}"
    "${CHMOD}" 755 "${INSTALL_DIR}"

    # Copy self to the canonical install path. $0 is the path of the
    # currently-executing script — typically a Jamf temp path on first
    # install, INSTALL_SCRIPT_PATH on a re-bootstrap.
    local source_path="$0"

    if [[ "${source_path}" != "${INSTALL_SCRIPT_PATH}" ]]
    then
        log_info "Copying script: ${source_path} -> ${INSTALL_SCRIPT_PATH}"
        "${CP}" "${source_path}" "${INSTALL_SCRIPT_PATH}"
    else
        log_debug "Script already at install path; skipping copy"
    fi

    "${CHOWN}" root:wheel "${INSTALL_SCRIPT_PATH}"
    "${CHMOD}" 755 "${INSTALL_SCRIPT_PATH}"

    if [[ -f "${LEGACY_INSTALL_SCRIPT_PATH}" && "${LEGACY_INSTALL_SCRIPT_PATH}" != "${INSTALL_SCRIPT_PATH}" ]]
    then
        log_info "Removing pre-2.11 installed copy: ${LEGACY_INSTALL_SCRIPT_PATH}"
        "${RM}" -f "${LEGACY_INSTALL_SCRIPT_PATH}"
    fi

    if ! write_daemon_plist
    then
        log_error "Failed to write LaunchDaemon plist; aborting install"
        return 1
    fi

    # If the daemon is already loaded (upgrade scenario), bootout first
    # so bootstrap picks up plist or script changes.
    if "${LAUNCHCTL}" print "system/${DAEMON_LABEL}" >/dev/null 2>&1
    then
        log_info "LaunchDaemon already loaded; reloading to pick up changes"
        "${LAUNCHCTL}" bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
        "${SLEEP}" 1
    fi

    if ! "${LAUNCHCTL}" bootstrap system "${DAEMON_PLIST_PATH}" 2>/dev/null
    then
        log_error "launchctl bootstrap failed for ${DAEMON_PLIST_PATH}"
        return 1
    fi

    log_info "Install complete. LaunchDaemon ${DAEMON_LABEL} is loaded; first run will fire on next jamf.log write, network change, or within 5 min via StartInterval."
    return 0
}

# ── Uninstall ────────────────────────────────────────────────────────────────
do_uninstall() {
    log_info "Uninstalling ${BUNDLE_ID}"

    if "${LAUNCHCTL}" print "system/${DAEMON_LABEL}" >/dev/null 2>&1
    then
        "${LAUNCHCTL}" bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
    fi

    if [[ -f "${DAEMON_PLIST_PATH}" ]]
    then
        "${RM}" -f "${DAEMON_PLIST_PATH}"
    fi

    "${RM}" -f "${LOCK_FILE}" "${DEBOUNCE_FILE}"

    if [[ -d "${INSTALL_DIR}" ]]
    then
        "${RM}" -rf "${INSTALL_DIR}"
    fi

    "${RM}" -f "${LOG_FILE}"

    log_info "Uninstall complete"
}

# ── Status ───────────────────────────────────────────────────────────────────
do_status() {
    if [[ ! -f "${STATE_PLIST}" ]]
    then
        printf 'No state file found at %s\n' "${STATE_PLIST}"
        return 0
    fi

    "${DEFAULTS}" read "${STATE_PLIST}"
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

# Mode dispatch handles three invocation contexts:
#   1. Jamf Script payload — $1 is the mount point (e.g. "/"). Custom
#      params start at $4. Default to --install.
#   2. LaunchDaemon — ProgramArguments passes "--run" as $1.
#   3. Direct CLI — $1 is the mode flag (--install, --run, --uninstall,
#      --status), or empty (we infer from $0 location).
MODE=""

case "${1:-}" in
    --install|--run|--uninstall|--status)
        MODE="$1"
        ;;
    /*)
        # Jamf Script payload: $1 is the mount point. Look at $4 for an
        # explicit mode override; otherwise default to --install.
        MODE="${PARAM_MODE:---install}"
        if [[ "${MODE}" != --* ]]
        then
            MODE="--${MODE}"
        fi
        ;;
    "")
        # No argument provided. Infer by location: if we are already at
        # the canonical install path, the caller is the LaunchDaemon
        # (misconfigured to omit --run) — default to --run. Otherwise
        # treat as a fresh deployment and install.
        if [[ "$0" == "${INSTALL_SCRIPT_PATH}" ]]
        then
            MODE="--run"
        else
            MODE="--install"
        fi
        ;;
    *)
        printf 'Usage: %s [--install|--run|--uninstall|--status]\n' "${SCRIPT_NAME}" >&2
        exit 1
        ;;
esac

case "${MODE}" in
    --install)
        LOG_TO_JAMF="true"
        require_root
        log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} install starting"
        do_install
        ;;

    --uninstall)
        LOG_TO_JAMF="true"
        require_root
        log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} uninstall starting"
        do_uninstall
        ;;

    --status)
        do_status
        ;;

    --run)
        require_root
        require_jq
        ensure_directories

        log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting (PID $$)"

        check_debounce
        acquire_lock

        "${SLEEP}" "${SETTLE_SECONDS}"

        wait_for_jamf_idle

        load_config
        detect_cisco_paths

        do_update
        ;;

    *)
        printf 'Usage: %s [--install|--run|--uninstall|--status]\n' "${SCRIPT_NAME}" >&2
        exit 1
        ;;
esac

###########################################################
################## End Script Block #######################
###########################################################

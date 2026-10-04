#! /bin/bash
# SC2155: readonly/local + $(...) is the house template declaration style.
# SC2034: template-core values (AWK, MKTEMP, TIMESTAMP) unused by this installer.
# shellcheck disable=SC2155,SC2034

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Install-Run-Policy-Dialog.sh
# Author: Heath Jones
# Date: 07-07-2026
# Modified: 10-04-2026
# Purpose: Installs the Enrollment Checklist progress helper (run-policy-dialog.zsh)
#          to disk (root:wheel, 0755) via heredoc, for use by Jamf Setup Checklist.
# Version: 1.0 - Initial Script
# Version: 1.1 - Parameterized the embedded helper via injected config variables
# Version: 1.2 - Added cisco/zscaler connect modes (hold dialog until tunnel is up) + banner debug log
# Version: 1.3 - Injected configurable dialog window height/width
# Version: 1.4 - Zscaler completes on app launch (not sign-in); cisco still waits for VPN connect
# Version: 1.5 - Configurable poll interval (faster detection) + optional --hide-app (quit an app UI on completion)
# Version: 1.6 - Removed --bannertext (banner image already contains the company logo/branding)
# Version: 1.7 - Re-added configurable --bannertext (default single space) to suppress the banner divider line
# Version: 1.8 - Added "hold" mode: show the branded dialog + fire a policy, then wait (used by the reboot step)
# Version: 1.9 - Dialog window size 640x1000
# Version: 2.0 - Messaging overhaul: helper now narrates jamf.log activity live via
#                progresstext, drives a determinate progress bar, shows an infobox
#                (elapsed/policy/support), nudges the user at the halfway + late marks,
#                and ALWAYS lands on a definite outcome — success (done-flag) or
#                stalled (error-flag + enabled Continue + optional setupchecklist
#                canContinue). Adds --policy-name (stops an unrelated background recon
#                from completing a step early), --step-id, --error-flag,
#                --expected-events; adds HOLD_TIMEOUT and supportText config.
# Version: 2.1 - Added "--layout list": app-install modes (app/cisco/zscaler) can now
#                render swiftDialog list rows (pending -> installing -> installed/failed)
#                for visual consistency with remediate-failed-policies.sh. recon/hold
#                stay on the progress+narration layout. List helpers are no-ops in
#                progress mode, so mode logic stays single-path.
# Version: 2.2 - Emitted helper now (a) WAITS up to DIALOG_WAIT_MAX seconds for
#                swiftDialog to become usable before falling back to headless, and logs
#                WHY on each miss (dangling symlink vs non-executable target), so a
#                concurrent SwiftDialog (re)install can no longer silently force every
#                step headless; and (b) is reformatted to the house script template
#                (banner blocks, multi-line control structures, no statement semicolons,
#                binary-path variables, single-instance lock freed via a cleanup trap).
#                Adds HELPER_DIALOG_WAIT_MAX / HELPER_DIALOG_WAIT_INTERVAL config.
# Version: 2.3 - Cisco step: swap the post-install message via a swiftDialog REPLACE
#                (message:) instead of an APPEND (message: +), so the "installed,
#                connecting" text replaces the intro copy cleanly rather than stacking
#                below it and clipping above the list rows.
# Version: 2.4 - Message block is now ALWAYS a full replace, never an append. The two
#                reassurance nudges still used `message: +`, so a slow VPN connect stacked
#                the intro + installed + halfway + late text into a fixed-height window and
#                forced scrolling. Adds MSG_BASE/MSG_NOTE + render_message/set_message_base/
#                set_message_note: the block is base plus AT MOST one note, re-rendered
#                whole on every change, so it can never grow unbounded.
# Version: 2.5 - Cisco step: added an ONSITE (corporate-network) bypass. On the corporate
#                LAN the VPN intentionally will not connect, so the "wait for the tunnel"
#                phase used to hang until timeout. The helper now pings a configurable
#                internal host (HELPER_ONSITE_PING_HOSTS — e.g. the AD domain) once, up
#                front, with a few retries; if it answers, the Mac is on-network and the
#                step completes immediately WITHOUT waiting for the VPN. Empty host list =
#                bypass disabled = behavior unchanged (always wait for the VPN). Adds
#                on_corporate_network() + HELPER_ONSITE_* config and PING binary.
# Version: 2.6 - Public release prep: sanitized identifiers, expert-bash conformance.
#                Org identity reset to generic defaults; branding asset paths and the
#                icon fallback URL are now CHANGE_ME placeholders; added Requirements +
#                require_zsh preflight; documented template ShellCheck disables. Fix:
#                the emitted helper now sanitizes --timeout / --expected-events (a 0 or
#                non-numeric value caused a zsh division-by-zero that killed the helper
#                before it wrote the done/error flag, breaking the always-an-outcome
#                contract).
# Version: 2.7 - Renamed to Name-Of-Script.sh convention
#
# Requirements:
#   - Runs as root (Jamf policy); writes under /Library/Application Support
#   - zsh at /bin/zsh (stock macOS) to syntax-check the generated helper
#   - Helper runtime (not checked here): swiftDialog at /usr/local/bin/dialog
#     (helper waits, then falls back to headless) and Setup Checklist's
#     setupchecklist CLI (optional; used only when --step-id is passed)
#   - Set ORG_NAME_FRIENDLY / ORG_PLIST_DOMAIN and the HELPER_* branding values
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

set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
# `which` preferred over `command -v` per style guide
# shellcheck disable=SC2230
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
readonly ORG_NAME_FRIENDLY="Company Name"         # CHANGE_ME: display name (may contain spaces)
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"           # CHANGE_ME: reverse-DNS prefix, e.g. com.example

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="2.7"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"
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
# shellcheck disable=SC2230
readonly CAT=$(which cat)
# shellcheck disable=SC2230
readonly CHMOD=$(which chmod)
# shellcheck disable=SC2230
readonly CHOWN=$(which chown)
# shellcheck disable=SC2230
readonly MKDIR=$(which mkdir)
# shellcheck disable=SC2230
readonly ZSH=$(which zsh)

# Install target for the progress helper
readonly PROJECT_NAME="Enrollment Checklist"
readonly INSTALL_DIR="/Library/Application Support/${ORG_NAME}/${PROJECT_NAME}/bin"
readonly HELPER_PATH="${INSTALL_DIR}/run-policy-dialog.zsh"

# ─────────────────────────────────────────────────────────────────────────────
# HELPER CONFIGURATION — the values below are injected into run-policy-dialog.zsh
# at install time. Edit them HERE; you never need to touch the embedded helper.
# ─────────────────────────────────────────────────────────────────────────────
readonly HELPER_APP_NAME="Enrollment Checklist"
readonly HELPER_DIALOG_BIN="/usr/local/bin/dialog"

# Branding (local path first; URL used only if the local file is missing)
readonly HELPER_BRANDING_BANNER_LOCAL="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/banner.png"    # CHANGE_ME: local banner image
readonly HELPER_BRANDING_BANNER_URL="https://img.freepik.com/premium-vector/abstract-techno-background-with-flowing-cyber-particles_1048-15244.jpg"
readonly HELPER_APP_ICON_LOCAL="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/icon.png"    # CHANGE_ME: local app icon
readonly HELPER_APP_ICON_URL="https://your-instance.example.com/YOUR_ICON_PATH/icon.png"    # CHANGE_ME: public URL fallback for the app icon
readonly HELPER_ICON_SIZE="125"
readonly HELPER_OVERLAY_ICON="SF=arrow.triangle.2.circlepath,colour=teal"
# Banner text over the banner image. A single space shows NO visible text but still
# suppresses swiftDialog's divider line under the banner (the line only appears when
# bannertext is absent). Set to real text if you ever want a text banner.
readonly HELPER_BANNER_TEXT=" "

# Dialog window size (swiftDialog --height / --width; pixels)
readonly HELPER_DIALOG_HEIGHT="640"
readonly HELPER_DIALOG_WIDTH="1000"

# Behavior
readonly HELPER_DEFAULT_TIMEOUT="1200"          # seconds to wait for a policy
readonly HELPER_HOLD_TIMEOUT="300"              # seconds to hold for a reboot policy before saying so
readonly HELPER_POLL_INTERVAL="1"               # seconds between completion checks (lower = snappier)
readonly HELPER_SS_BUNDLE_ID="com.jamf.selfserviceplus"
readonly HELPER_SS_PROC_NAME="Self Service+"
readonly HELPER_LOG_BASENAME="EnrollmentChecklist-dialog.log"

# swiftDialog readiness — the helper waits this long for /usr/local/bin/dialog to
# become USABLE before falling back to headless. swiftDialog can be (re)installed by a
# concurrent enrollment policy in the same window the helper fires, briefly leaving the
# symlink dangling or its target non-executable. Bump WAIT_MAX if your build races harder.
readonly HELPER_DIALOG_WAIT_MAX="30"            # total seconds to wait for a usable dialog
readonly HELPER_DIALOG_WAIT_INTERVAL="2"        # seconds between readiness checks

# Shown in the dialog infobox and in every "didn't finish" message. Keep it short —
# it is the only thing a stuck user has to go on.
readonly HELPER_SUPPORT_TEXT="Need help? Contact the Service Desk."

# ─────────────────────────────────────────────────────────────────────────────
# ONSITE (corporate-network) DETECTION — cisco mode only.
# On the corporate network the Cisco VPN intentionally will NOT connect (the
# protected resources are already reachable), so the helper's "wait for the tunnel"
# phase would hang until DEFAULT_TIMEOUT and then stall the step. To fix that, the
# helper pings the host(s) below ONCE, up front (with a few retries to ride out a
# network that is still settling right after enrollment). If ANY host answers, the
# Mac is treated as on-network and the Cisco step completes IMMEDIATELY — the VPN
# wait is skipped. Off-network, none answer and the helper waits for the VPN exactly
# as before.
#
# HELPER_ONSITE_PING_HOSTS: space-separated. Use an internal-only name that resolves
#   and answers ICMP ONLY on the corporate network — the AD domain is a good choice
#   (e.g. "corp.example.com"). Leave EMPTY to DISABLE the bypass entirely
#   (behavior then identical to v2.4: always wait for the VPN).
readonly HELPER_ONSITE_PING_HOSTS=""            # CHANGE_ME (optional): e.g. "corp.example.com"
readonly HELPER_ONSITE_PING_COUNT="1"           # ICMP echoes sent per host per attempt
readonly HELPER_ONSITE_PING_TIMEOUT="2"         # seconds a single ping waits before giving up
readonly HELPER_ONSITE_RETRIES="3"              # onsite checks before falling back to the VPN wait
readonly HELPER_ONSITE_RETRY_DELAY="2"          # seconds between onsite checks

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

# Preflight: zsh is needed to syntax-check the generated helper (and to run it).
require_zsh() {
    if [[ -z "${ZSH}" || ! -x "${ZSH}" ]]
    then
        log_error "zsh not found; cannot validate the generated helper"
        exit 1
    fi
}

# Write run-policy-dialog.zsh to disk in two parts:
#   1) UNQUOTED heredoc -> the script head: information block + "Core Defined
#      Variables" (binary paths, literal) + "User Defined Variables" (the managed
#      configuration, with the HELPER_* values from the installer expanded in — edit
#      them above, not in the helper). Runtime $VARs that must survive to the helper
#      are escaped as \${...}.
#   2) SINGLE-QUOTED heredoc -> the literal helper logic (functions + run block),
#      appended verbatim.
install_helper() {
    log_info "Creating install directory: ${INSTALL_DIR}"
    "${MKDIR}" -p "${INSTALL_DIR}"
    "${CHOWN}" root:wheel "${INSTALL_DIR}"
    "${CHMOD}" 755 "${INSTALL_DIR}"

    log_info "Writing helper (head + config): ${HELPER_PATH}"
    "${CAT}" > "${HELPER_PATH}" <<HELPER_HEAD_EOF
#! /bin/zsh

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: run-policy-dialog.zsh
# Author: Heath Jones
# Date: 07-07-2026
# Modified: 10-04-2026
# Purpose: Runs a Jamf Self Service policy "hidden" and shows a branded swiftDialog
#          progress window in its place. The window narrates /var/log/jamf.log in real
#          time and ALWAYS lands on a definite outcome: success (done-flag) or stalled
#          (error-flag + an enabled Continue button), so a user is never left staring
#          at a frozen "Please wait…".
# Version: ${SCRIPT_VERSION} - GENERATED by ${SCRIPT_NAME}. Do NOT hand-edit — change the
#          HELPER_* configuration in ${SCRIPT_NAME} and re-run the install policy.
#
# CONTEXT: runs in the logged-in USER's session (launched by Setup Checklist), so it
#          calls the dialog binary directly and quits Self Service with killall (TCC-free).
#
######################################################################
############## End Script Information Block ##########################
######################################################################

emulate -L zsh
setopt no_nomatch

####################################################################
############## Begin Define Variables Block ########################
####################################################################
##############################
### Core Defined Variables ###
### MODIFY AT YOUR OWN RISK ##
##############################

# Ensure PATH is set so binaries resolve in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths — explicit absolutes. zsh has builtins named 'kill'/'print', so we
# never resolve these via 'which'; hardcoded paths guarantee the real binaries.
readonly CAT="/bin/cat"
readonly DATE="/bin/date"
readonly KILL="/bin/kill"
readonly RM="/bin/rm"
readonly SLEEP="/bin/sleep"
readonly GREP="/usr/bin/grep"
readonly KILLALL="/usr/bin/killall"
readonly OPEN="/usr/bin/open"
readonly PGREP="/usr/bin/pgrep"
readonly PING="/sbin/ping"
readonly READLINK="/usr/bin/readlink"
readonly STAT="/usr/bin/stat"
readonly TAIL="/usr/bin/tail"
readonly TOUCH="/usr/bin/touch"

readonly JAMF_LOG="/var/log/jamf.log"
readonly SC_CLI="/usr/local/bin/setupchecklist"

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Managed configuration — INJECTED by ${SCRIPT_NAME} at write time. ###
### Edit these in ${SCRIPT_NAME}, NOT here. ###
########################################

readonly APP_NAME="${HELPER_APP_NAME}"
readonly ORG_NAME_FRIENDLY="${ORG_NAME_FRIENDLY}"
readonly ORG_NAME="${ORG_NAME}"
readonly DIALOG_BIN="${HELPER_DIALOG_BIN}"
readonly APP_DIR="/Library/Application Support/\${ORG_NAME}/\${APP_NAME}"

readonly brandingBanner_local="${HELPER_BRANDING_BANNER_LOCAL}"
readonly brandingBanner_url="${HELPER_BRANDING_BANNER_URL}"
readonly appIcon_local="${HELPER_APP_ICON_LOCAL}"
readonly appIcon_url="${HELPER_APP_ICON_URL}"
readonly appIconSize=${HELPER_ICON_SIZE}
readonly appOverlayIcon="${HELPER_OVERLAY_ICON}"
readonly bannerText="${HELPER_BANNER_TEXT}"
readonly dialogHeight=${HELPER_DIALOG_HEIGHT}
readonly dialogWidth=${HELPER_DIALOG_WIDTH}

readonly DEFAULT_TIMEOUT=${HELPER_DEFAULT_TIMEOUT}
readonly HOLD_TIMEOUT=${HELPER_HOLD_TIMEOUT}
readonly pollInterval=${HELPER_POLL_INTERVAL}
readonly SS_BUNDLE_ID="${HELPER_SS_BUNDLE_ID}"
readonly SS_PROC_NAME="${HELPER_SS_PROC_NAME}"
readonly supportText="${HELPER_SUPPORT_TEXT}"
readonly USER_LOG="\${HOME}/Library/Logs/${HELPER_LOG_BASENAME}"

# How long to wait for swiftDialog to become USABLE before falling back to headless.
readonly DIALOG_WAIT_MAX=${HELPER_DIALOG_WAIT_MAX}
readonly DIALOG_WAIT_INTERVAL=${HELPER_DIALOG_WAIT_INTERVAL}

# Onsite (corporate-network) detection — cisco mode. Empty ONSITE_PING_HOSTS disables
# the bypass (always wait for the VPN). See HELPER_ONSITE_* in the installer.
readonly ONSITE_PING_HOSTS="${HELPER_ONSITE_PING_HOSTS}"
readonly ONSITE_PING_COUNT=${HELPER_ONSITE_PING_COUNT}
readonly ONSITE_PING_TIMEOUT=${HELPER_ONSITE_PING_TIMEOUT}
readonly ONSITE_RETRIES=${HELPER_ONSITE_RETRIES}
readonly ONSITE_RETRY_DELAY=${HELPER_ONSITE_RETRY_DELAY}
HELPER_HEAD_EOF

    log_info "Writing helper (logic block): ${HELPER_PATH}"
    "${CAT}" >> "${HELPER_PATH}" <<'RUN_POLICY_DIALOG_ZSH'

# ── Derived branding (local path first, URL fallback) ────────────────────────
brandingBanner="${brandingBanner_local}"
if [[ ! -f "${brandingBanner}" ]]
then
    brandingBanner="${brandingBanner_url}"
fi

appIcon="${appIcon_local}"
if [[ ! -f "${appIcon}" ]]
then
    appIcon="${appIcon_url}"
fi

appName="${ORG_NAME_FRIENDLY} - ${APP_NAME}"

# ── Dialog size constants ────────────────────────────────────────────────────
appSizeXSmall=250
appSizeSmall=500
appSizeMedium=650
appSizeLarge=800
appSizeXLarge=1000

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

# ── Logging (user context: appends to the per-user dialog log) ───────────────
log() {
    printf '%s %s\n' "$("${DATE}" '+%Y-%m-%d %H:%M:%S')" "$*" >> "${USER_LOG}" 2>/dev/null
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
# Only remove the single-instance lock if THIS process created it — never delete a
# lock owned by an already-running helper we deliberately yielded to.
LOCK_OWNED=false
cleanup() {
    if [[ "${LOCK_OWNED}" == true ]]
    then
        "${RM}" -f "${LOCK_FILE}" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

usage() {
    print -r -- "Usage: $0 --policy-id <id> --mode <recon|app|cisco|zscaler|hold> --done-flag <path>
    [--layout <progress|list>] [--app-path <path>] [--policy-name <name>]
    [--step-id <checklist step id>] [--title <t>] [--message <m>]
    [--icon <SF=..|path|url>] [--error-flag <path>] [--expected-events <n>]
    [--hide-app <proc>] [--timeout <sec>]"
    exit 64
}

# Send a command to the running dialog via its command file.
dcmd() {
    print -r -- "$1" >> "${CMD_FILE}" 2>/dev/null
}

# Quit Self Service+ without Apple Events (TCC-free).
quit_selfservice() {
    "${KILLALL}" "${SS_PROC_NAME}" 2>/dev/null
}

# True while the swiftDialog process we launched is still alive (user may close it).
dialog_alive() {
    if [[ -z "${DIALOG_PID}" ]]
    then
        return 1
    fi
    "${KILL}" -0 "${DIALOG_PID}" 2>/dev/null
}

# Elapsed seconds -> m:ss for the infobox.
fmt_elapsed() {
    printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 ))
}

# Ask Setup Checklist to move a step out of the "stuck" state so the user is never
# trapped on a step whose policy failed. No-op when --step-id was not supplied.
set_step_status() {
    if [[ -z "${STEP_ID}" || ! -x "${SC_CLI}" ]]
    then
        return 0
    fi
    "${SC_CLI}" status "${STEP_ID}" "$1" >/dev/null 2>&1
    log "setupchecklist status ${STEP_ID} $1"
}

#####################################################################
######## List-layout helpers ########################################
#####################################################################
# When --layout list is used (app/cisco/zscaler), each phase of the install is a row
# in a swiftDialog list. All three are no-ops in progress layout, so the mode logic
# below stays single-path. swiftDialog list rows are 0-indexed in the order added.

LIST_DONE=0

# Update a row's spinner/status. Statuses: pending, wait (spinner), success, error.
list_set() {
    if [[ "${LAYOUT}" != list ]]
    then
        return 0
    fi
    dcmd "listitem: index: $1, status: $2, statustext: $3"
}

# Mark a row finished (green check) and advance the progress bar by one row.
list_done() {   # $1 = row index, $2 = status text (default "Installed")
    list_set "$1" success "${2:-Installed}"
    if [[ "${LAYOUT}" == list ]]
    then
        (( LIST_DONE += 1 ))
        dcmd "progress: ${LIST_DONE}"
    fi
}

# Mark a row failed (red X).
list_fail() {   # $1 = row index, $2 = status text (default "Failed")
    list_set "$1" error "${2:-Failed}"
}

#####################################################################
######## jamf.log watching ##########################################
#####################################################################
# We read only the bytes appended to jamf.log since the helper started, translate each
# meaningful jamf line into a sentence a new hire can understand, and feed it to the
# dialog's progresstext — informative instead of a spinner that says "Please wait".

LOG_OFFSET=0
NEW_LINES=""
CURRENT_ACTIVITY=""
LAST_ACTIVITY=""
EVENT_COUNT=0
POLICY_STARTED=false
RECON_DONE=false
FAILED=false
FAIL_REASON=""

# "Google Chrome.pkg..." -> "Google Chrome". Trailing ellipsis/period, then the
# installer extension, then any version suffix a package name carries.
pretty_name() {
    local n="$1"
    n="${n%...}"
    n="${n%.}"
    n="${n%.pkg}"
    n="${n%.dmg}"
    n="${n%.app}"
    # Only strip a trailing "-1.2.3"-style version, never a hyphen that's part of the
    # name itself ("Cisco-Secure-Client" must survive intact).
    if [[ "${n}" == *-[0-9]* ]]
    then
        n="${n%-[0-9]*}"
    fi
    print -r -- "${n}"
}

# Capture the new bytes into the NEW_LINES global. (Never `VAR=$(read_new_log)` — the
# function also logs, and capturing stdout would pollute the data.)
read_new_log() {
    NEW_LINES=""
    local size
    size=$("${STAT}" -f %z "${JAMF_LOG}" 2>/dev/null || print -r -- 0)
    if (( size < LOG_OFFSET ))       # log was rotated out from under us
    then
        LOG_OFFSET=0
    fi
    if (( size <= LOG_OFFSET ))
    then
        return 1
    fi
    NEW_LINES=$("${TAIL}" -c +$(( LOG_OFFSET + 1 )) "${JAMF_LOG}" 2>/dev/null)
    LOG_OFFSET=${size}
    return 0
}

# Translate the new jamf.log lines into user-facing activity + completion state.
scan_log() {
    if ! read_new_log
    then
        return 0
    fi
    local line body friendly
    while IFS= read -r line
    do
        if [[ -z "${line}" ]]
        then
            continue
        fi
        body="${line#*]: }"                # strip "Tue Jul 14 09:12:01 mac jamf[123]: "
        friendly=""
        case "${body}" in
            "Executing Policy "*)
                # With --policy-name set we only accept OUR policy, so a background
                # check-in policy running at the same time can't complete this step.
                if [[ -z "${POLICY_NAME}" || "${body}" == *"${POLICY_NAME}"* ]]
                then
                    POLICY_STARTED=true
                fi
                friendly="Starting ${body#Executing Policy }"
                ;;
            "Installing "*)
                friendly="Installing $(pretty_name "${body#Installing }")…"
                ;;
            "Successfully installed "*)
                friendly="Installed $(pretty_name "${body#Successfully installed }")"
                ;;
            "Running script "*)
                # Script filenames mean nothing to a new hire (and "remediate-failed-
                # policies.sh" actively worries them) — keep this one generic.
                friendly="Applying configuration…"
                ;;
            "Running Recon"*|"Retrieving inventory"*)
                friendly="Updating your device record…"
                ;;
            "Submitting data to"*)
                if [[ "${POLICY_STARTED}" == true ]]
                then
                    RECON_DONE=true
                fi
                friendly="Finishing up…"
                ;;
            *"Installation failed"*|*"There was an error"*|*"Error running"*|*"could not be found"*)
                # Recorded, NOT acted on immediately — a stray error line from an
                # unrelated policy must not abort an install that is still succeeding.
                # It is only surfaced if we go on to time out.
                FAILED=true
                FAIL_REASON="${body}"
                log "possible failure: ${body}"
                ;;
        esac
        if [[ -n "${friendly}" ]]
        then
            (( EVENT_COUNT += 1 ))
            CURRENT_ACTIVITY="${friendly}"
        fi
    done <<< "${NEW_LINES}"
}

#####################################################################
######## swiftDialog readiness ######################################
#####################################################################
# swiftDialog may be (re)installed by a concurrent enrollment policy in the same window
# this helper fires, so a single -x check at launch is racy: the symlink can resolve to
# a target that is missing or not yet executable. Wait briefly for the binary to become
# usable before committing to a headless run, and log WHY on each miss so a headless run
# is never a silent mystery again.
wait_for_dialog() {   # 0 = usable, 1 = gave up
    local waited=0
    local target=""
    while (( waited < DIALOG_WAIT_MAX ))
    do
        if [[ -x "${DIALOG_BIN}" ]]
        then
            if (( waited > 0 ))
            then
                log "swiftDialog became usable after ${waited}s"
            fi
            return 0
        fi
        target=$("${READLINK}" "${DIALOG_BIN}" 2>/dev/null)
        if [[ -z "${target}" ]]
        then
            target="${DIALOG_BIN}"
        fi
        if [[ -e "${target}" ]]
        then
            log "waiting for swiftDialog: target present but not executable (${target}); ${waited}/${DIALOG_WAIT_MAX}s"
        else
            log "waiting for swiftDialog: symlink target missing (${target}); ${waited}/${DIALOG_WAIT_MAX}s"
        fi
        "${SLEEP}" "${DIALOG_WAIT_INTERVAL}"
        (( waited += DIALOG_WAIT_INTERVAL ))
    done
    return 1
}

#####################################################################
######## Dialog updates #############################################
#####################################################################

# The message block is ALWAYS written as a full replace (swiftDialog `message:`), never
# an append (`message: +`). Appends grow the block without bound — the install->installed
# swap plus the halfway and late nudges stacked four paragraphs into a fixed-height
# window and forced the user to scroll. Instead we hold the current base message plus AT
# MOST one reassurance note, and re-render the whole block on every change.
MSG_BASE=""
MSG_NOTE=""

render_message() {
    dcmd "message: ${MSG_BASE}${MSG_NOTE}"
}

# Swap the phase message (e.g. installing -> installed). Clears any stale note so a new
# phase never inherits the previous phase's reassurance text.
set_message_base() {
    MSG_BASE="$1"
    MSG_NOTE=""
    render_message
}

# Set the single reassurance note. REPLACES any previous note rather than stacking.
set_message_note() {
    MSG_NOTE="<br><br>$1"
    render_message
}

# Progress bar takes the HIGHER of "how much of the timeout has burned" and "how many
# jamf events we've seen" — so the bar always creeps forward even when jamf.log is
# quiet, and jumps ahead when real work lands. Capped at 95% until we're done.
refresh_ui() {
    if ! dialog_alive
    then
        return 0
    fi
    # In list layout the rows themselves show activity (spinner per phase) and the
    # progress bar advances as rows complete, so we only keep the infobox clock live.
    if [[ "${LAYOUT}" != list ]]
    then
        local pct time_pct evt_pct
        time_pct=$(( elapsed * 100 / TIMEOUT ))
        evt_pct=$(( EVENT_COUNT * 100 / EXPECTED_EVENTS ))
        pct=${time_pct}
        if (( evt_pct > pct ))
        then
            pct=${evt_pct}
        fi
        if (( pct > 95 ))
        then
            pct=95
        fi
        dcmd "progress: ${pct}"
        if [[ -n "${CURRENT_ACTIVITY}" && "${CURRENT_ACTIVITY}" != "${LAST_ACTIVITY}" ]]
        then
            dcmd "progresstext: ${CURRENT_ACTIVITY}"
            log "activity: ${CURRENT_ACTIVITY}"
            LAST_ACTIVITY="${CURRENT_ACTIVITY}"
        fi
    fi
    dcmd "infobox: **${TITLE}**<br><br>Elapsed  $(fmt_elapsed ${elapsed})<br>Policy  ${POLICY_ID}<br><br>${supportText}"
}

# Reassure the user at the halfway and three-quarter marks rather than saying nothing
# for 20 minutes and then giving up.
NUDGED_HALF=false
NUDGED_LATE=false
nudge_user() {
    if [[ "${NUDGED_HALF}" == false ]] && (( elapsed >= TIMEOUT / 2 ))
    then
        NUDGED_HALF=true
        set_message_note "_This is taking a little longer than usual — large apps and slow networks can do that. It's still running; you can leave this window open._"
        log "halfway nudge at ${elapsed}s"
    fi
    if [[ "${NUDGED_LATE}" == false ]] && (( elapsed >= (TIMEOUT * 3) / 4 ))
    then
        NUDGED_LATE=true
        dcmd "overlayicon: SF=clock.badge.exclamationmark.fill,colour=orange"
        set_message_note "_Still going. If this doesn't finish in the next few minutes we'll let you move on and finish the install in the background._"
        log "late nudge at ${elapsed}s"
    fi
}

# Watch until the named completion test passes. 0 = complete, 1 = timed out.
watch_until() {
    local test_fn="$1"
    while (( elapsed < TIMEOUT ))
    do
        scan_log
        if "${test_fn}"
        then
            return 0
        fi
        refresh_ui
        nudge_user
        "${SLEEP}" "${pollInterval}"
        (( elapsed += pollInterval ))
    done
    return 1
}

#####################################################################
######## Completion tests ###########################################
#####################################################################

# recon: the policy's FINAL recon submitted its data. Gated on POLICY_STARTED so an
# unrelated check-in recon can't satisfy this step early.
recon_complete() {
    [[ "${POLICY_STARTED}" == true && "${RECON_DONE}" == true ]]
}

app_installed() {
    [[ -n "${APP_PATH}" && -d "${APP_PATH}" ]]
}

# Cisco: the VPN tunnel reports Connected.
vpn_connected() {
    local vpn_bin="/opt/cisco/secureclient/bin/vpn"
    if [[ ! -x "${vpn_bin}" ]]
    then
        return 1
    fi
    local st
    st="$(printf 'state\nquit\n' | "${vpn_bin}" -s 2>/dev/null)"
    print -r -- "${st}" | "${GREP}" -Eiq "state:[[:space:]]*Connected"
}

# Cisco onsite bypass: true when we are demonstrably ON the corporate network, where the
# VPN will not (and need not) connect. Pings each configured internal-only host (e.g. the
# AD domain) — a host that resolves and answers ICMP only on the corporate LAN. Any single
# reply is enough. Unconfigured (empty ONSITE_PING_HOSTS) always returns 1, so the default
# behavior — wait for the tunnel — is unchanged.
on_corporate_network() {
    if [[ -z "${ONSITE_PING_HOSTS}" ]]
    then
        return 1
    fi
    local host
    # zsh does not word-split unquoted parameters by default; ${=..} forces it so a
    # space-separated ONSITE_PING_HOSTS iterates as multiple hosts.
    for host in ${=ONSITE_PING_HOSTS}
    do
        if "${PING}" -c "${ONSITE_PING_COUNT}" -t "${ONSITE_PING_TIMEOUT}" "${host}" >/dev/null 2>&1
        then
            log "onsite: ${host} answered ping — on corporate network, skipping VPN wait"
            return 0
        fi
    done
    return 1
}

# Zscaler: the app's UI process (launched from APP_PATH) is running.
app_running() {
    if [[ -z "${APP_PATH}" ]]
    then
        return 1
    fi
    "${PGREP}" -f "${APP_PATH}/Contents/MacOS/" >/dev/null 2>&1
}

never_complete() {
    return 1
}

#####################################################################
######## Outcomes ###################################################
#####################################################################

finish_success() {
    dcmd "progresstext: ${TITLE} complete."
    dcmd "progress: complete"
    dcmd "overlayicon: SF=checkmark.circle.fill,colour=green"
    # Optionally tuck away an app's UI (e.g. quit the Cisco Secure Client window; the
    # VPN tunnel keeps running via its background agent). TCC-free — killall is a
    # signal, not Apple Events.
    if [[ -n "${HIDE_APP}" ]]
    then
        "${KILLALL}" "${HIDE_APP}" 2>/dev/null
    fi
    "${SLEEP}" 2
    dcmd "quit:"
    quit_selfservice
    "${TOUCH}" "${DONE_FLAG}" 2>/dev/null
    "${RM}" -f "${ERROR_FLAG}" 2>/dev/null
    log "policy ${POLICY_ID} completed in ${elapsed}s; done-flag written"
}

# Timed out (or the policy reported an error and never recovered). Say so plainly, hand
# the user a working button, drop an error flag for Support, and let the checklist step
# continue rather than trapping them on a dead step.
finish_stalled() {
    local detail="${1}"
    dcmd "progress: hide"
    dcmd "progresstext: "
    dcmd "overlayicon: SF=exclamationmark.triangle.fill,colour=orange"
    dcmd "icon: SF=exclamationmark.triangle.fill"
    set_message_base "### ${TITLE} didn't finish in time<br><br>${detail}<br><br>You can move on — this keeps running in the background. If **${TITLE}** still isn't ready in 30 minutes, contact the Service Desk and quote policy **${POLICY_ID}**.<br><br>${supportText}"
    dcmd "button1text: Continue"
    dcmd "button1: enable"
    quit_selfservice
    "${TOUCH}" "${ERROR_FLAG}" 2>/dev/null
    set_step_status "canContinue"
    log "policy ${POLICY_ID} did NOT complete after ${elapsed}s (${detail}); error-flag written"
}

##################################
### End User Defined Functions ###
##################################
###################################################################################
############## End Function Block #################################################
###################################################################################

#####################################################################
######## Argument Parsing ###########################################
#####################################################################

POLICY_ID="" MODE="" APP_PATH="" TITLE="" MESSAGE="" ICON="" DONE_FLAG=""
ERROR_FLAG="" STEP_ID="" POLICY_NAME="" HIDE_APP="" TIMEOUT="" EXPECTED_EVENTS=""
LAYOUT="progress"

while (( $# ))
do
    case "$1" in
        --policy-id)
            POLICY_ID="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --layout)
            LAYOUT="$2"
            shift 2
            ;;
        --app-path)
            APP_PATH="$2"
            shift 2
            ;;
        --title)
            TITLE="$2"
            shift 2
            ;;
        --message)
            MESSAGE="$2"
            shift 2
            ;;
        --icon)
            ICON="$2"
            shift 2
            ;;
        --done-flag)
            DONE_FLAG="$2"
            shift 2
            ;;
        --error-flag)
            ERROR_FLAG="$2"
            shift 2
            ;;
        --step-id)
            STEP_ID="$2"
            shift 2
            ;;
        --policy-name)
            POLICY_NAME="$2"
            shift 2
            ;;
        --hide-app)
            HIDE_APP="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --expected-events)
            EXPECTED_EVENTS="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "${POLICY_ID}" || -z "${MODE}" || -z "${DONE_FLAG}" ]]
then
    usage
fi
if [[ "${MODE}" == (app|cisco|zscaler) && -z "${APP_PATH}" ]]
then
    usage
fi
if [[ "${LAYOUT}" != (progress|list) ]]
then
    usage
fi
# The list layout is an app-install visualization; recon (informational) and hold
# (reboot) always use the progress+narration layout.
if [[ "${MODE}" == (recon|hold) ]]
then
    LAYOUT="progress"
fi
if [[ -z "${ICON}" ]]
then
    ICON="${appIcon}"
fi
if [[ -z "${TITLE}" ]]
then
    TITLE="Setup"
fi
if [[ -z "${ERROR_FLAG}" ]]
then
    ERROR_FLAG="${DONE_FLAG}.error"
fi
if [[ -z "${TIMEOUT}" ]]
then
    if [[ "${MODE}" == "hold" ]]
    then
        TIMEOUT="${HOLD_TIMEOUT}"
    else
        TIMEOUT="${DEFAULT_TIMEOUT}"
    fi
fi
# A zero or non-numeric timeout would make refresh_ui divide by zero (zsh aborts the
# helper before any flag is written), so fall back to the mode default.
if [[ "${TIMEOUT}" != <-> ]] || (( TIMEOUT < 1 ))
then
    log "invalid --timeout '${TIMEOUT}'; using default"
    if [[ "${MODE}" == "hold" ]]
    then
        TIMEOUT="${HOLD_TIMEOUT}"
    else
        TIMEOUT="${DEFAULT_TIMEOUT}"
    fi
fi
# How many jamf.log events we expect this policy to emit — only used to pace the
# progress bar, so a rough number is fine. Zero/non-numeric is treated as unset.
if [[ "${EXPECTED_EVENTS}" != <-> ]] || (( EXPECTED_EVENTS < 1 ))
then
    EXPECTED_EVENTS=""
fi
if [[ -z "${EXPECTED_EVENTS}" ]]
then
    case "${MODE}" in
        recon)
            EXPECTED_EVENTS=12
            ;;
        cisco)
            EXPECTED_EVENTS=6
            ;;
        zscaler)
            EXPECTED_EVENTS=6
            ;;
        *)
            EXPECTED_EVENTS=4
            ;;
    esac
fi

CMD_FILE="/var/tmp/sc-dialog-${POLICY_ID}.log"
LOCK_FILE="/var/tmp/sc-dialog-${POLICY_ID}.lock"

#####################################################
################## Run Script Block #################
#####################################################

# Single-instance guard: if a helper for this policy is already running, bail WITHOUT
# touching its lock (the cleanup trap only removes a lock this process owns).
if [[ -f "${LOCK_FILE}" ]] && "${KILL}" -0 "$("${CAT}" "${LOCK_FILE}" 2>/dev/null)" 2>/dev/null
then
    log "helper for policy ${POLICY_ID} already running; exiting"
    exit 0
fi
print -r -- "$$" > "${LOCK_FILE}"
LOCK_OWNED=true
: > "${CMD_FILE}"                                        # fresh command file
"${RM}" -f "${DONE_FLAG}" "${ERROR_FLAG}" 2>/dev/null    # clear stale flags

# Start reading jamf.log from where it is NOW, so we only ever see THIS run.
LOG_OFFSET=$("${STAT}" -f %z "${JAMF_LOG}" 2>/dev/null || print -r -- 0)

log "policy=${POLICY_ID} mode=${MODE} layout=${LAYOUT} title=${TITLE} timeout=${TIMEOUT}s step=${STEP_ID:-none}"

# For the list layout, define one row per install phase (0-indexed in this order).
# The row titles/icons are derived from the mode + --title/--icon the step passed.
typeset -a LIST_TITLES LIST_ICONS
if [[ "${LAYOUT}" == list ]]
then
    case "${MODE}" in
        cisco)
            LIST_TITLES=("Install ${TITLE}" "Connect to the VPN")
            LIST_ICONS=("${ICON}" "SF=lock.shield.fill")
            ;;
        zscaler)
            LIST_TITLES=("Install ${TITLE}" "Start ${TITLE}")
            LIST_ICONS=("${ICON}" "SF=bolt.horizontal.circle.fill")
            ;;
        app)
            LIST_TITLES=("Install ${TITLE}")
            LIST_ICONS=("${ICON}")
            ;;
    esac
fi

# Launch the branded progress dialog (backgrounded). swiftDialog can be mid-(re)install
# during enrollment, so wait briefly for a USABLE binary before falling back to headless
# — and if we still can't get one, we run the policy anyway so the checklist proceeds.
if wait_for_dialog
then
    typeset -a dargs
    dargs=(
        --height "${dialogHeight}"
        --width "${dialogWidth}"
        --icon "${ICON}"
        --iconsize "${appIconSize}"
        --overlayicon "${appOverlayIcon}"
        --bannerimage "${brandingBanner}"
        --bannertext "${bannerText}"
        --message "${MESSAGE}"
        --infobox "**${TITLE}**<br><br>Starting…"
        --button1text "Please wait…"
        --button1disabled
        --ontop --moveable
        --commandfile "${CMD_FILE}"
    )
    if [[ "${LAYOUT}" == list && ${#LIST_TITLES} -gt 0 ]]
    then
        # Determinate bar sized to the number of phases; one pending row per phase.
        dargs+=( --progress "${#LIST_TITLES}" --progresstext "Starting…" )
        row=1
        while (( row <= ${#LIST_TITLES} ))
        do
            dargs+=( --listitem "title=${LIST_TITLES[row]},icon=${LIST_ICONS[row]},status=pending,statustext=Waiting" )
            (( row += 1 ))
        done
    else
        dargs+=( --progress 100 --progresstext "Starting ${TITLE}…" )
    fi
    "${DIALOG_BIN}" "${dargs[@]}" >/dev/null 2>&1 &
    DIALOG_PID=$!
    "${SLEEP}" 0.3                                  # let dialog open its command file
    log "launched dialog pid ${DIALOG_PID}"
else
    DIALOG_PID=""
    log "swiftDialog not usable at ${DIALOG_BIN} after ${DIALOG_WAIT_MAX}s; running headless"
fi

# Seed the rendered message with exactly what the dialog launched with, so every later
# update replaces a known block instead of appending to an unknown one.
MSG_BASE="${MESSAGE}"

# Kick off the policy HIDDEN: -g = don't foreground, -j = launch hidden.
"${OPEN}" -g -j "jamfselfservice://content?entity=policy&id=${POLICY_ID}&action=execute"
dcmd "progresstext: Contacting Jamf…"

elapsed=0
outcome=1

case "${MODE}" in
    hold)
        # Fire the policy and hold the branded dialog until the policy ends the session
        # (a reboot policy). If the reboot never comes, we say so instead of hanging.
        dcmd "progresstext: Preparing to restart…"
        watch_until never_complete
        finish_stalled "The restart didn't begin on its own."
        set_message_base "### Restart didn't begin<br><br>Please restart your Mac manually (Apple menu → Restart) to finish single sign-on setup."
        exit 1
        ;;
    cisco)
        # Phase 1 — wait for the app to land, then close the (hidden) Self Service.
        list_set 0 wait "Installing…"
        dcmd "progresstext: Installing ${TITLE}…"
        if watch_until app_installed
        then
            list_done 0 "Installed"
            quit_selfservice
            # Phase 2 — but FIRST short-circuit if we're already on the corporate network:
            # the VPN won't connect there by design, so don't wait for a tunnel that will
            # never come up. Check once up front, retried a few times to ride out a network
            # still settling right after enrollment. Skipped entirely when the bypass is
            # unconfigured (empty ONSITE_PING_HOSTS) — then we wait for the VPN as before.
            onsite=false
            if [[ -n "${ONSITE_PING_HOSTS}" ]]
            then
                list_set 1 wait "Checking network…"
                dcmd "progresstext: Checking the network…"
                onsite_try=1
                while (( onsite_try <= ONSITE_RETRIES ))
                do
                    if on_corporate_network
                    then
                        onsite=true
                        break
                    fi
                    (( onsite_try += 1 ))
                    if (( onsite_try <= ONSITE_RETRIES ))
                    then
                        "${SLEEP}" "${ONSITE_RETRY_DELAY}"
                    fi
                done
            fi
            if [[ "${onsite}" == true ]]
            then
                # On the corporate LAN — done, no VPN required.
                set_message_base "**${TITLE} is installed.** You're on the ${ORG_NAME_FRIENDLY} network, so the VPN isn't needed here — this step is complete."
                list_done 1 "On corporate network"
                outcome=0
            else
                # Off-network — hold the dialog until the tunnel is actually up, as before.
                dcmd "progresstext: Connecting to the VPN…"
                # REPLACE (not append) so the intro copy swaps cleanly to the "installed,
                # connecting" state instead of stacking below it and clipping above the list.
                set_message_base "**${TITLE} is installed.** It will open and connect on its own. If it asks you to sign in, use your ${ORG_NAME_FRIENDLY} credentials — this step finishes as soon as the VPN connects."
                list_set 1 wait "Connecting…"
                if watch_until vpn_connected
                then
                    list_done 1 "Connected"
                    outcome=0
                else
                    list_fail 1 "Not connected"
                fi
            fi
        else
            list_fail 0 "Not installed"
        fi
        ;;
    zscaler)
        # Phase 1 — install; Phase 2 — the app launches itself.
        list_set 0 wait "Installing…"
        dcmd "progresstext: Installing ${TITLE}…"
        if watch_until app_installed
        then
            list_done 0 "Installed"
            list_set 1 wait "Starting…"
            dcmd "progresstext: Starting ${TITLE}…"
            if watch_until app_running
            then
                list_done 1 "Running"
                outcome=0
            else
                list_fail 1 "Didn't start"
            fi
        else
            list_fail 0 "Not installed"
        fi
        ;;
    app)
        list_set 0 wait "Installing…"
        dcmd "progresstext: Installing ${TITLE}…"
        if watch_until app_installed
        then
            list_done 0 "Installed"
            outcome=0
        else
            list_fail 0 "Not installed"
        fi
        ;;
    recon)
        if watch_until recon_complete
        then
            outcome=0
        fi
        ;;
    *)
        usage
        ;;
esac

if (( outcome == 0 ))
then
    finish_success
    exit 0
fi

# Not complete. Lead with the real reason when jamf.log gave us one.
if [[ "${FAILED}" == true && -n "${FAIL_REASON}" ]]
then
    finish_stalled "Jamf reported: \`${FAIL_REASON}\`"
else
    finish_stalled "We stopped waiting after $(fmt_elapsed ${elapsed})."
fi
exit 1

###########################################################
################## End Script Block #######################
###########################################################
RUN_POLICY_DIALOG_ZSH

    "${CHOWN}" root:wheel "${HELPER_PATH}"
    "${CHMOD}" 755 "${HELPER_PATH}"

    if ! "${ZSH}" -n "${HELPER_PATH}"
    then
        log_error "Helper failed zsh -n syntax check: ${HELPER_PATH}"
        return 1
    fi

    if [[ ! -x "${HELPER_PATH}" ]]
    then
        log_error "Helper not executable after install: ${HELPER_PATH}"
        return 1
    fi

    log_info "Helper installed OK: ${HELPER_PATH}"
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
require_zsh

if ! install_helper
then
    log_error "Helper installation failed"
    exit 1
fi

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

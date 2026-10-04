#! /bin/bash
# File-wide: `which` is preferred over `command -v` per the style guide,
# `readonly NAME=$(which ...)` is the template's declaration style, and jq/awk
# programs are deliberately single-quoted (their $vars are jq/awk variables).
# shellcheck disable=SC2230,SC2155,SC2016

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Remediate-Failed-Policies.sh
# Author: Heath Jones
# Date: 07-09-2026
# Modified: 10-04-2026
# Purpose: Detection-gated remediation for the Enrollment Checklist, intended to
#          run as an additional script payload on the Enrollment Checklist's
#          Self Service policy (the "checklist policy" below).
#          Reads the manifest written by build-verify.sh (build-status.plist):
#            - if it is missing or nothing failed, it exits cleanly (with an
#              optional brief "all installed" confirmation);
#            - if apps failed during Setup Manager, it shows a branded Setup
#              Your Mac-style swiftDialog LIST and repairs each one inline —
#              flipping its row Pending -> Installing -> Installed/Not installed
#              as it re-runs the app's Jamf trigger with retry/backoff.
#          The Setup Manager 503 is transient and `jamf policy -event` returns 0
#          even when it no-ops, so success is confirmed by RE-VERIFYING the
#          artifact, never by exit code. Continue-with-warning: the done-flag is
#          always written so the Checklist proceeds; persistent failures are
#          left red on the list and logged for support.
# Version: 1.0 - Initial Script (headless payload, manifest status updates only)
# Version: 2.0 - Integrated Setup Your Mac-style swiftDialog list (root-driven
#                via launchctl asuser); detection gate + graceful exit; drives
#                each row inline while remediating
# Version: 2.1 - Re-run triggers with -forceNoRecon (the checklist policy's final
#                recon covers the installs); runs as the checklist policy's
#                last script payload behind Checklist step 2
# Version: 2.2 - Suppress the "all installed" confirmation dialog. swiftDialog now
#                appears ONLY when Setup Manager actually missed apps that need
#                installing; when nothing was missed the script exits silently.
# Version: 2.3 - Public release prep: sanitized identifiers/credentials,
#                expert-bash conformance. Dialog command file is now a mktemp
#                file (was a fixed, world-writable /var/tmp path that root
#                truncated: symlink-clobber risk); manifest rows are parsed with
#                a non-whitespace delimiter so an empty field no longer shifts
#                the following columns; added jamf binary preflight (still writes
#                the done-flag); touch via binary var.
# Version: 2.4 - Renamed to Name-Of-Script.sh convention
#
# Requirements:
#   - Runs as root (Jamf policy script payload)
#   - jq (ships with macOS 15+; install it on older macOS)
#   - Jamf binary at /usr/local/jamf/bin/jamf (re-runs the app triggers)
#   - Manifest written by build-verify.sh at
#     /Library/Application Support/${ORG_NAME}/Enrollment Checklist/build-status.plist
#     (absent manifest = nothing to remediate, graceful exit)
#   - Jamf parameter $4: done-flag path (optional; default
#     /Users/Shared/.sc-remediation-done)
#   - swiftDialog at /usr/local/bin/dialog (optional; remediates headless
#     without it or without a logged-in user)
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
# `which` is preferred over `command -v` per the style guide, so the directive below is deliberate.
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
readonly ORG_NAME_FRIENDLY="Company Name"
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="2.4"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"
# shellcheck disable=SC2034  # template metadata, kept for consistency
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
readonly JQ=$(which jq)
readonly PKGUTIL=$(which pkgutil)
readonly SYSCTL=$(which sysctl)
readonly PLUTIL=$(which plutil)
readonly MV=$(which mv)
readonly CHMOD=$(which chmod)
readonly SLEEP=$(which sleep)
readonly SCUTIL=$(which scutil)
readonly LAUNCHCTL=$(which launchctl)
readonly SUDO=$(which sudo)
readonly TOUCH=$(which touch)
readonly JAMF="/usr/local/jamf/bin/jamf"
readonly DIALOG_BIN="/usr/local/bin/dialog"

# Jamf parameters ($1-$3 reserved: mount point, computer name, username)
readonly PARAM_DONE_FLAG="${4:-/Users/Shared/.sc-remediation-done}"

# The manifest written by build-verify.sh — the detection source of truth.
readonly PROJECT_NAME="Enrollment Checklist"
readonly MANIFEST="/Library/Application Support/${ORG_NAME}/${PROJECT_NAME}/build-status.plist"

# Retry policy for each failed trigger. jamf policy -event returns 0 even when
# the JSS is unreachable, so success is confirmed by re-verifying the artifact.
readonly MAX_ATTEMPTS=3
readonly BACKOFF_BASE=15          # seconds; attempt N waits (N * BACKOFF_BASE)

# swiftDialog is shown ONLY when Setup Manager missed apps that need installing.
# When nothing was missed, the script exits silently (no confirmation dialog).
readonly SUCCESS_LINGER=3         # seconds after all rows finish (no failures)
readonly WARN_LINGER=8            # seconds after finishing (some failures)

# ── swiftDialog branding (see swiftdialog skill) ─────────────────────────────
APP_NAME="Enrollment Checklist"
# local branding banner path; online fallback if missing
brandingBanner="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/banner.png"    # CHANGE_ME: local banner image path
if [[ ! -f "${brandingBanner}" ]]
then
    brandingBanner="https://img.freepik.com/premium-vector/abstract-techno-background-with-flowing-cyber-particles_1048-15244.jpg"
fi
# local app icon path; built-in SF Symbol fallback if missing (no network needed)
appIcon="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/icon.png"    # CHANGE_ME: local app icon path
if [[ ! -f "${appIcon}" ]]
then
    appIcon="SF=gearshape.2.fill,colour=teal"
fi
appIconSize=125
appOverlayIcon="SF=wrench.and.screwdriver.fill,colour=teal"
# Single space suppresses swiftDialog's banner divider line (banner art carries the logo).
bannerText=" "
# shellcheck disable=SC2034  # kept for parity with sibling scripts (banner uses bannerText)
appName="${ORG_NAME_FRIENDLY} - ${APP_NAME}"

# Dialog command file (created with mktemp in the Run Script Block)
CMD_FILE=""
DIALOG_PID=""

# Field delimiter for manifest rows: ASCII Unit Separator. Non-whitespace, so
# `read` keeps empty fields instead of collapsing them like it does with tabs.
readonly FIELD_SEP=$'\x1f'

# Dialog window size (pixels)
dialogHeight=640
dialogWidth=1000

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
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_warn() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_error() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_debug() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
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

# ── User-context resolution (swiftDialog must draw in the user's session) ────
get_current_user() {
    local console_user
    console_user=$("${SCUTIL}" <<< "show State:/Users/ConsoleUser" \
        | "${AWK}" '/Name :/ && !/loginwindow/ { print $3 }')
    if [[ -z "${console_user}" || "${console_user}" == "root" ]]
    then
        return 1
    fi
    printf '%s' "${console_user}"
}

get_current_user_uid() {
    "${ID}" -u "$1"
}

# EVERY dialog call goes through this wrapper — runs dialog in the user session.
run_dialog() {
    "${LAUNCHCTL}" asuser "${CONSOLE_UID}" "${SUDO}" -u "${CURRENT_USER}" \
        "${DIALOG_BIN}" "$@" 2>/dev/null
}

# Send a live command to the running list dialog via its command file.
dcmd() {
    printf '%s\n' "$1" >> "${CMD_FILE}" 2>/dev/null || true
}

# ── Presence-only install check (mirrors build-verify.sh) ────────────────────
is_apple_silicon() {
    [[ "$("${SYSCTL}" -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]
}

verify_installed() {
    local vtype="$1"
    local varg="$2"

    case "${vtype}" in
        app)
            [[ -d "${varg}" ]]
            ;;
        pkg)
            "${PKGUTIL}" --pkg-info "${varg}" >/dev/null 2>&1
            ;;
        pkgmatch)
            [[ -n "$("${PKGUTIL}" --pkgs="${varg}" 2>/dev/null)" ]]
            ;;
        path)
            [[ -e "${varg}" ]]
            ;;
        rosetta)
            if ! is_apple_silicon
            then
                return 0
            fi
            [[ -e "/Library/Apple/usr/share/rosetta/rosetta" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# ── Preflight: jq ────────────────────────────────────────────────────────────
require_jq() {
    if [[ -z "${JQ}" || ! -x "${JQ}" ]]
    then
        log_error "jq is required but not found in PATH"
        finish
        exit 1
    fi
}

# ── Preflight: Jamf binary (needed to re-run app triggers) ───────────────────
# The done-flag is still written so the Checklist is never left hanging.
require_jamf_binary() {
    if [[ ! -x "${JAMF}" ]]
    then
        log_error "Jamf binary not found at ${JAMF}; cannot re-run triggers"
        finish
        exit 1
    fi
}

# ── Atomic manifest status update (record-keeping / telemetry) ───────────────
# Rewrites to a temp file and renames over the original so any concurrent reader
# never sees a half-written file. Updates one app (by key) status + detail and
# recomputes failCount (# of apps not PASS).
manifest_set_status() {
    local key="$1"
    local newstatus="$2"
    local detail="$3"
    local tmp_json
    local tmp_plist

    tmp_json=$("${MKTEMP}")
    tmp_plist="${tmp_json}.plist"
    TEMP_FILES+=("${tmp_json}" "${tmp_plist}")

    if ! "${PLUTIL}" -convert json -o - "${MANIFEST}" 2>/dev/null \
        | "${JQ}" -c --arg k "${key}" --arg s "${newstatus}" --arg d "${detail}" \
            '.apps |= map(if .key == $k then (.status = $s | .detail = $d) else . end)
             | .failCount = ([.apps[] | select(.status != "PASS")] | length)' \
            > "${tmp_json}"
    then
        log_error "Failed to compute manifest update for ${key}"
        return 1
    fi

    if ! "${PLUTIL}" -convert xml1 -o "${tmp_plist}" "${tmp_json}"
    then
        log_error "Failed to convert manifest update for ${key}"
        return 1
    fi

    "${MV}" "${tmp_plist}" "${MANIFEST}"
    "${CHMOD}" 644 "${MANIFEST}"
    log_debug "manifest: ${key} -> ${newstatus} (${detail})"
}

# ── Re-run one app's trigger with retry/backoff, confirmed by re-verify ──────
run_trigger_with_retry() {
    local trigger="$1"
    local vtype="$2"
    local varg="$3"
    local attempt=1
    local backoff

    while [[ "${attempt}" -le "${MAX_ATTEMPTS}" ]]
    do
        log_info "Remediation attempt ${attempt}/${MAX_ATTEMPTS} for trigger '${trigger}'"
        # jamf policy returns 0 even on a 503 no-op — ignore its exit, re-verify instead.
        # -forceNoRecon: skip each triggered policy's inventory submit; the checklist
        # policy's final recon (its last action) captures everything remediation installed.
        "${JAMF}" policy -forceNoRecon -event "${trigger}" >/dev/null 2>&1 || true

        if verify_installed "${vtype}" "${varg}"
        then
            log_info "Trigger '${trigger}' verified installed after attempt ${attempt}"
            return 0
        fi

        if [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]
        then
            backoff=$(( attempt * BACKOFF_BASE ))
            log_warn "Trigger '${trigger}' still not installed; backing off ${backoff}s before retry"
            "${SLEEP}" "${backoff}"
        fi
        attempt=$(( attempt + 1 ))
    done

    log_error "Trigger '${trigger}' failed to install after ${MAX_ATTEMPTS} attempts"
    return 1
}

# ── Complete the Checklist step: always write the done-flag ───────────────────
finish() {
    "${TOUCH}" "${PARAM_DONE_FLAG}" 2>/dev/null || true
    "${CHMOD}" 644 "${PARAM_DONE_FLAG}" 2>/dev/null || true
    log_info "Done-flag written: ${PARAM_DONE_FLAG}"
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

require_jq
require_jamf_binary

# ── Detection gate: no manifest = nothing was missed. Graceful exit. ─────────
if [[ ! -f "${MANIFEST}" ]]
then
    log_info "No manifest at ${MANIFEST}; nothing to remediate — graceful exit"
    finish
    exit 0
fi

MANIFEST_JSON=$("${PLUTIL}" -convert json -o - "${MANIFEST}" 2>/dev/null || true)
if [[ -z "${MANIFEST_JSON}" ]]
then
    log_error "Manifest present but unreadable: ${MANIFEST} — graceful exit"
    finish
    exit 0
fi

FAIL_COUNT=$("${JQ}" -r '[.apps[] | select(.status == "FAIL")] | length' <<< "${MANIFEST_JSON}")

# ── Nothing was missed: silent graceful exit, NO dialog ──────────────────────
# The swiftDialog prompt only appears when there is something to install.
if [[ "${FAIL_COUNT}" -eq 0 ]]
then
    log_info "No failed apps in manifest; nothing to remediate — exiting silently (no dialog)"
    finish
    exit 0
fi

log_info "Remediating ${FAIL_COUNT} failed app(s)"

# Something to install — resolve the logged-in user so the list dialog can draw
# in their session (may be absent in edge cases; we fall back to headless).
CURRENT_USER=$(get_current_user || true)
CONSOLE_UID=""
if [[ -n "${CURRENT_USER}" ]]
then
    CONSOLE_UID=$(get_current_user_uid "${CURRENT_USER}")
fi

# ── Build the ordered failed set from the manifest ───────────────────────────
declare -a fkeys fnames fdescs ficons ftriggers fvtypes fvargs
while IFS="${FIELD_SEP}" read -r key name description icon trigger vtype varg
do
    if [[ -z "${key}" ]]
    then
        continue
    fi
    fkeys+=("${key}")
    fnames+=("${name}")
    fdescs+=("${description}")
    ficons+=("${icon}")
    ftriggers+=("${trigger}")
    fvtypes+=("${vtype}")
    fvargs+=("${varg}")
done < <("${JQ}" -r --arg sep "${FIELD_SEP}" '.apps[] | select(.status == "FAIL") | [.key, .name, .description, .icon, .trigger, .verifyType, .verifyArg] | map(. // "" | tostring | gsub("[\n\r]"; " ")) | join($sep)' <<< "${MANIFEST_JSON}")

TOTAL=${#fkeys[@]}

# ── Launch the branded SYM-style list dialog (if a user is present) ──────────
# Random name (mktemp) so root never writes through a pre-planted symlink; 644
# is enough because swiftDialog (running as the user) only reads it.
CMD_FILE=$("${MKTEMP}" "/var/tmp/remediation-dialog.XXXXXX")
TEMP_FILES+=("${CMD_FILE}")
"${CHMOD}" 644 "${CMD_FILE}"

DIALOG_UP="false"
if [[ -n "${CURRENT_USER}" && -x "${DIALOG_BIN}" ]]
then
    declare -a dargs
    dargs=(
        --height "${dialogHeight}"
        --width "${dialogWidth}"
        --icon "${appIcon}"
        --iconsize "${appIconSize}"
        --overlayicon "${appOverlayIcon}"
        --bannerimage "${brandingBanner}"
        --bannertext "${bannerText}"
        --message "Finishing your setup. A few applications need to be installed — please wait while we take care of them."
        --progress "${TOTAL}"
        --progresstext "Preparing to install ${TOTAL} item(s)…"
        --button1text "Please wait…"
        --button1disabled
        --ontop
        --moveable
        --commandfile "${CMD_FILE}"
    )
    idx=0
    while [[ "${idx}" -lt "${TOTAL}" ]]
    do
        dargs+=( --listitem "title=${fnames[idx]},subtitle=${fdescs[idx]},icon=${ficons[idx]},status=pending,statustext=Pending" )
        idx=$(( idx + 1 ))
    done
    run_dialog "${dargs[@]}" >/dev/null 2>&1 &
    DIALOG_PID=$!
    DIALOG_UP="true"
    "${SLEEP}" 1
    log_info "Launched remediation list dialog for ${CURRENT_USER} (uid ${CONSOLE_UID})"
else
    log_warn "No user session or swiftDialog missing — remediating headless"
fi

# ── Repair each failed app, driving its row live ─────────────────────────────
REMEDIATED=0
STILL_FAILED=0
idx=0
while [[ "${idx}" -lt "${TOTAL}" ]]
do
    log_info "Remediating '${fnames[idx]}' (key=${fkeys[idx]}, trigger=${ftriggers[idx]})"
    if [[ "${DIALOG_UP}" == "true" ]]
    then
        dcmd "listitem: index: ${idx}, status: wait, statustext: Installing…"
    fi
    manifest_set_status "${fkeys[idx]}" "REMEDIATING" "remediation in progress" || true

    if run_trigger_with_retry "${ftriggers[idx]}" "${fvtypes[idx]}" "${fvargs[idx]}"
    then
        manifest_set_status "${fkeys[idx]}" "PASS" "installed after remediation" || true
        REMEDIATED=$(( REMEDIATED + 1 ))
        if [[ "${DIALOG_UP}" == "true" ]]
        then
            dcmd "listitem: index: ${idx}, status: success, statustext: Installed"
        fi
    else
        manifest_set_status "${fkeys[idx]}" "FAILED" "still not installed after ${MAX_ATTEMPTS} attempts" || true
        STILL_FAILED=$(( STILL_FAILED + 1 ))
        if [[ "${DIALOG_UP}" == "true" ]]
        then
            dcmd "listitem: index: ${idx}, status: error, statustext: Not installed"
        fi
    fi

    if [[ "${DIALOG_UP}" == "true" ]]
    then
        dcmd "progress: $(( REMEDIATED + STILL_FAILED ))"
        dcmd "progresstext: Installed ${REMEDIATED} of ${TOTAL}…"
    fi
    idx=$(( idx + 1 ))
done

log_info "Remediation summary: ${REMEDIATED} repaired, ${STILL_FAILED} still failing (of ${TOTAL})"

# ── Finalize the dialog (continue-with-warning) ──────────────────────────────
if [[ "${DIALOG_UP}" == "true" ]]
then
    if [[ "${STILL_FAILED}" -eq 0 ]]
    then
        dcmd "progress: complete"
        dcmd "progresstext: All items installed."
        dcmd "message: All required applications have been installed successfully."
        "${SLEEP}" "${SUCCESS_LINGER}"
    else
        dcmd "progresstext: ${REMEDIATED} of ${TOTAL} installed."
        dcmd "message: ${STILL_FAILED} item(s) could not be installed and have been logged for support. You can continue — these will be retried automatically."
        "${SLEEP}" "${WARN_LINGER}"
    fi
    dcmd "quit:"
    # Wait for swiftDialog to read quit: before the EXIT trap removes the
    # command file, otherwise the window could be left open.
    if ! wait "${DIALOG_PID}" 2>/dev/null
    then
        log_debug "Remediation dialog already closed"
    fi
fi

finish

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

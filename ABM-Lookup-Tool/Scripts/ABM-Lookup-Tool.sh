#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: ABM-Lookup-Tool.sh
# Author: Heath Jones
# Date: 06-25-2026
# Modified: 10-04-2026
# Purpose: swiftDialog admin utility — prompt for a serial number and look up its
#          enrollment status via a selectable data source (Jamf Parameter 6):
#            ABM  — Apple Business Manager API; shows ABM enrollment + MDM
#                   assignment and can assign/unassign to an MDM server.
#            Jamf — Jamf Pro API; read-only Automated Device Enrollment (ADE/DEP)
#                   status from /api/v1/device-enrollments/{id}/devices. No assignment.
# Version: 1.0 - Initial Script
# Version: 1.1 - Embedded ABM API credentials; private key held in memory and
#                signed via process substitution (never written to disk)
# Version: 1.2 - Page orgDevices at limit=1000 with a sparse fieldset for faster
#                lookups; --globoff for bracketed fields[orgDevices] URLs
# Version: 1.3 - admin/support mode toggle (Jamf param 4); Device Info header with
#                per-line fields; admin Assign/Unassign, support assigns a fixed server
# Version: 1.4 - Show AppleCare coverage details in the Device Info block
# Version: 1.5 - Add "Date added" to Device Info; log raw AppleCare response for
#                diagnosis (coverage was showing as unavailable)
# Version: 1.6 - Fix AppleCare: response .data is an ARRAY of coverage records with
#                description/status/startDateTime/endDateTime; parse + show each
# Version: 1.7 - Fast-path device lookup: direct GET /v1/orgDevices/{serial} with
#                pagination fallback (orgDevice id == serial in tested tenants)
# Version: 1.8 - Device Info dialog shows the device's hardware icon (CoreTypes
#                .icns by productFamily/deviceModel; SF-Symbol fallback)
# Version: 1.9 - Device Info shows the photorealistic com.apple.*.icns hardware
#                image — latest representative per family/type (Sidebar*.icns are
#                monochrome template glyphs); SF-Symbol fallback only
# Version: 2.0 - Device icon used on all post-lookup dialogs (assign/unassign
#                progress + results); brand icon only for the initial prompt and
#                device-not-found / pre-lookup errors
# Version: 2.1 - Fix HTTP 409 on unassign: ABM requires mdmServer for UNASSIGN too
#                (send the device's current server); log request body + error body
# Version: 2.3 - Cancellable progress dialog (Cancel button + abort), live phase
#                text + device-checked count; command file moved to /private/tmp so
#                the console-user dialog can read it (fixes the hang); retry on HTTP
#                000; shorter timeout; force-kill teardown so it never lingers
# Version: 2.4 - Banner uses ORG_NAME_FRIENDLY (display name, spaces allowed);
#                ORG_NAME derived path-safe via ${ORG_NAME_FRIENDLY// /}
# Version: 2.5 - Renamed ABM_Lookup_Tool.sh; add data-source toggle (Jamf param 6):
#                ABM (existing) or Jamf (read-only ADE/DEP lookup via Jamf Pro API)
# Version: 2.6 - Public release prep: sanitized identifiers/credentials, expert-bash
#                conformance. Credentials are no longer embedded: ABM client ID,
#                key ID and a private-key FILE PATH (plus Jamf client ID/secret) come
#                from Jamf params $7-$11 or env vars; refuses to run when missing.
#                Fixes: placeholder checks never matched (wrong literals); logging
#                aborted non-root runs when /var/log/jamf.log was not writable;
#                JWT builder no longer captures log output via $(...); support-mode
#                server name validated before lookup; single-line case arms split.
# Version: 2.7 - Renamed to Name-Of-Script.sh convention
#
# Requirements:
#   - Interactive admin tool (off-device). Runs as a logged-in admin user, or as
#     root (sudo / Rundeck / Jamf) with a GUI console user to display dialogs
#   - swiftDialog installed at /usr/local/bin/dialog (REQUIRED - the entire UI;
#     the script exits if it is missing)
#   - jq (ships with macOS 15+; install separately on older macOS), openssl,
#     xxd, uuidgen, curl
#   - Network access to api-business.apple.com and account.apple.com (ABM source)
#     or your Jamf Pro server (Jamf source)
#   - Jamf parameter $4: mode - "admin" or "support" (ABM source; default support)
#   - Jamf parameter $5: serial number (optional; prompts if empty)
#   - Jamf parameter $6: data source - "ABM" or "Jamf" (default ABM)
#   - ABM source credentials (param, else env var):
#       $7  / ABM_CLIENT_ID    ABM API client ID (BUSINESSAPI.xxxx)
#       $8  / ABM_KEY_ID       ABM API key ID
#       $9  / ABM_KEY_FILE     path to the ABM EC P-256 private key (.pem),
#                              readable by the running user, ideally mode 600
#   - Jamf source credentials (param, else env var):
#       $10 / JAMF_CLIENT_ID      Jamf Pro API client ID
#       $11 / JAMF_CLIENT_SECRET  Jamf Pro API client secret (prefer the env var;
#                                 positional args are visible in `ps`)
#       JAMF_URL_OVERRIDE (env, optional) Jamf Pro URL when the Mac is not enrolled
#   - Jamf Pro API role: "Read Device Enrollment Program Instances" (Jamf source)
#   - ABM API account role that can read devices and assign/unassign MDM servers
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

# File-wide ShellCheck directives (style-guide decisions, not bugs):
#   SC2230 - `which` is preferred over `command -v` per the style guide
#   SC2155 - `readonly X=$(...)` / `local x="$(...)"` is the template convention
#   SC2016 - jq/awk programs are intentionally single-quoted ($vars are jq/awk vars)
# shellcheck disable=SC2230,SC2155,SC2016

set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY is the human-readable display name and MAY contain spaces
#   (used in the swiftDialog banner). ORG_NAME is derived — spaces removed — and
#   is the path-safe form used in filesystem paths. ORG_PLIST_DOMAIN is reverse-DNS
#   (used for LOG_LABEL, etc.).
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: display name; spaces OK
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"     # derived: path-safe (e.g. CompanyName)
readonly ORG_PLIST_DOMAIN="com.company"     # CHANGE_ME: reverse-DNS

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="2.7"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"
# shellcheck disable=SC2034  # template constant; kept for future use
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

# ── Task-specific binaries ───────────────────────────────────────────────────
readonly CURL=$(which curl)
readonly JQ=$(which jq)
readonly OPENSSL=$(which openssl)
readonly TR=$(which tr)
readonly XXD=$(which xxd)
readonly SED=$(which sed)
readonly DEFAULTS=$(which defaults)
readonly UUIDGEN=$(which uuidgen)
readonly SCUTIL=$(which scutil)
readonly LAUNCHCTL=$(which launchctl)
readonly SUDO=$(which sudo)
readonly SLEEP=$(which sleep)
readonly CHMOD=$(which chmod)
readonly PGREP=$(which pgrep)
readonly PKILL=$(which pkill)
readonly STAT=$(which stat)

# ══════════════════════════════════════════════════════════════════════════════
# ABM API CREDENTIALS — supplied at runtime, NEVER embedded in this file
# ══════════════════════════════════════════════════════════════════════════════
# Each value comes from a Jamf parameter if set, else from an environment
# variable of the same name. The script refuses to run (configuration dialog +
# exit 1) when a value needed by the selected data source is missing.
#   $7 / ABM_CLIENT_ID  ABM API client ID (ABM ▸ Settings ▸ API), BUSINESSAPI.xxxx
#   $8 / ABM_KEY_ID     ABM API key ID
#   $9 / ABM_KEY_FILE   PATH to the EC P-256 private key (.pem) downloaded from ABM.
#                       Only the path is passed; the key never appears on a
#                       command line. Keep it admin-owned, chmod 600, outside any
#                       repo. Rotate it in ABM if it is ever exposed.
# Note: plain `sudo` strips the environment. When running as root, pass the
# values as parameters $7-$9 or use `sudo --preserve-env=ABM_CLIENT_ID,...`.
# shellcheck disable=SC2153  # names intentionally match the env vars they read
readonly ABM_CLIENT_ID="${7:-${ABM_CLIENT_ID:-}}"
readonly ABM_KEY_ID="${8:-${ABM_KEY_ID:-}}"
readonly ABM_KEY_FILE="${9:-${ABM_KEY_FILE:-}}"

# Optional: name of the MDM server to pre-select in the assignment dropdown.
# Leave empty to just list servers in ABM's order. Must match serverName exactly.
readonly ABM_PREFERRED_MDM_NAME=""

# ── ABM API endpoints / constants (stable — change only if Apple changes them) ─
readonly ABM_API_BASE="https://api-business.apple.com"
readonly ABM_TOKEN_URL="https://account.apple.com/auth/oauth2/token"   # sanitize:ignore - public Apple OAuth endpoint, not a secret
readonly ABM_TOKEN_AUD="https://account.apple.com/auth/oauth2/v2/token"   # sanitize:ignore - public Apple OAuth audience, not a secret
readonly ABM_SCOPE="business.api"   # use "school.api" for Apple School Manager
readonly ABM_JWT_LIFETIME=300       # client-assertion lifetime (seconds)
readonly ABM_PAGE_LIMIT=1000        # orgDevices/mdmServers page size (API max is 1000)
# The ABM/ASM API has NO serial-number filter — orgDevices must be paged and
# matched client-side. fields[orgDevices] is a sparse fieldset (selects which
# attributes are returned), NOT a filter. We request only what we match/display
# so each page (up to 1000 devices) stays small.
readonly ABM_DEVICE_FIELDS="serialNumber,status,deviceModel,productFamily,addedToOrgDateTime"
readonly ABM_HTTP_TIMEOUT=30        # per-request curl timeout (seconds)
readonly ABM_POLL_MAX_ATTEMPTS=10   # activity status poll attempts
readonly ABM_POLL_INTERVAL=3        # seconds between activity polls

# ══════════════════════════════════════════════════════════════════════════════
# JAMF PRO API — used when data source = Jamf (read-only ADE/DEP lookup)
# ══════════════════════════════════════════════════════════════════════════════
# OAuth API client (Settings ▸ System ▸ API roles and clients) whose role has
# ONLY the "Read Device Enrollment Program Instances" privilege. Supplied at
# runtime (param, else env var); not needed when only the ABM source is used.
#   $10 / JAMF_CLIENT_ID      Jamf Pro API client ID
#   $11 / JAMF_CLIENT_SECRET  Jamf Pro API client secret (prefer the env var —
#                             positional arguments are visible in `ps`)
readonly JAMF_CLIENT_ID="${10:-${JAMF_CLIENT_ID:-}}"
readonly JAMF_CLIENT_SECRET="${11:-${JAMF_CLIENT_SECRET:-}}"
# JAMF_URL_OVERRIDE (env): leave unset to read jss_url from the Mac's management
# plist (/Library/Preferences/com.jamfsoftware.jamf.plist). Set only for
# off-device use, e.g. https://your-instance.jamfcloud.com
readonly JAMF_URL_OVERRIDE="${JAMF_URL_OVERRIDE:-}"

# ── Jamf Pro Script Parameters + operating mode ──────────────────────────────
# $1-$3 are reserved by Jamf (mount point, computer name, username).
#   Parameter 4: mode — "admin" or "support" (ABM source only)
#   Parameter 5: serial number (optional; if empty the script prompts for it)
#   Parameter 6: data source — "ABM" or "Jamf"
#   Parameters 7-11: credentials (see the two credential blocks above)
# Test locally (as a logged-in admin, credentials from env vars):
#   ABM_CLIENT_ID="BUSINESSAPI.xxxx" ABM_KEY_ID="xxxx" ABM_KEY_FILE="/path/to/abm-key.pem" \
#       ./ABM-Lookup-Tool.sh "" "" "" admin C02XXXXXXXXX ABM
readonly PARAM_MODE="${4:-}"
readonly PARAM_SERIAL="${5:-}"
readonly PARAM_SOURCE="${6:-}"
# Mode behavior (ABM source only):
#   admin   — pick any MDM server + action (Assign / Unassign)
#   support — Assign to SUPPORT_MODE_MDM_NAME only; no server/action choice
readonly DEFAULT_MODE="support"                   # used if Parameter 4 is empty/invalid (least privilege)
readonly SUPPORT_MODE_MDM_NAME="YOUR_MDM_SERVER_NAME"   # CHANGE_ME: support-mode target; must match the ABM serverName exactly
readonly SUPPORT_MODE_MDM_NAME_FRIENDLY="Jamf"            # CHANGE_ME: short label shown on the Assign button
# Data source behavior (Parameter 6):
#   ABM  — look up via the Apple Business Manager API; assign/unassign to an MDM
#   Jamf — look up via the Jamf Pro API (read-only ADE/DEP status; no assignment)
readonly DEFAULT_SOURCE="ABM"                     # used if Parameter 6 is empty/invalid

# ── swiftDialog: App / Org Identity ──────────────────────────────────────────
APP_NAME="ABM Lookup Tool"
DIALOG_BIN="/usr/local/bin/dialog"
# shellcheck disable=SC2034  # template constant; kept for future use
APP_DIR="/Library/Application Support/${ORG_NAME}/${APP_NAME}"

# ── swiftDialog: Branding Banner ─────────────────────────────────────────────
# local branding banner path
brandingBanner="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/banner.jpg"   # CHANGE_ME: local banner path
if [[ ! -f "${brandingBanner}" ]]
then
    # online branding banner url if local file doesn't exist
    brandingBanner="https://img.freepik.com/premium-vector/abstract-techno-background-with-flowing-cyber-particles_1048-15244.jpg"
fi

# ── swiftDialog: App Icon ────────────────────────────────────────────────────
# local app icon path
appIcon="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/icon.png"   # CHANGE_ME: local app icon path
if [[ ! -f "${appIcon}" ]]
then
    # Fallback: a stock macOS app icon (or set an icon URL of your own here)
    appIcon="/System/Applications/Utilities/System Information.app"
fi
# shellcheck disable=SC2034  # swiftDialog sizing constants; not all used here
appIconSize=125

# ── swiftDialog: Size Constants ──────────────────────────────────────────────
# shellcheck disable=SC2034  # standard sizing set; not all used here
appSizeXSmall=250
appSizeSmall=500
appSizeMedium=650
appSizeLarge=800
# shellcheck disable=SC2034  # standard sizing set; not all used here
appSizeXLarge=1000

# ── swiftDialog: Banner text (used on every dialog) ──────────────────────────
appName="${ORG_NAME_FRIENDLY} - ${APP_NAME}"

# Hardware device icons (photoreal, shipped with macOS) used on the Device Info
# dialog in place of the app icon — see device_icon_value().
readonly DEVICE_ICON_DIR="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"

# ── Runtime state (populated as the script runs) ─────────────────────────────
CURRENT_USER=""
CONSOLE_UID=""
MODE=""
SOURCE=""
JAMF_URL=""
JAMF_TOKEN=""
JAMF_AUTH_ERROR=""
JAMF_DEVICE_JSON=""
JAMF_INSTANCE_NAME=""
JAMF_LOOKUP_STATUS=""
JAMF_LOOKUP_DETAIL=""
ACCESS_TOKEN=""
AUTH_ERROR=""
CONFIG_ERROR=""
CLIENT_ASSERTION=""
MDM_SERVERS_FILE=""
MDM_FETCH_ERROR=""
DEVICE_JSON=""
DEVICE_LOOKUP_STATUS=""    # found | notfound | error
DEVICE_LOOKUP_DETAIL=""
APPLECARE_JSON='{"data":[]}'
DEVICE_ICON=""
DIALOG_ICON="${appIcon}"   # brand icon until a device is found; then the device icon
ASSIGN_ERROR=""
ACTIVITY_ID=""
ACTIVITY_STATUS=""
ACTIVITY_SUBSTATUS=""
PROGRESS_CMD_FILE=""
PROGRESS_PID=""
PROGRESS_SEEN=0

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

# ── Logging (unified log + /var/log/jamf.log) ───────────────────────────────
# Writes the formatted line to stdout and appends it to /var/log/jamf.log when
# that file is writable. Run as a non-root admin, jamf.log is root-owned; an
# unconditional tee would fail and, under set -e, abort the script.
emit_log_line() {
    local log_msg="$1"
    if [[ -w "${JAMF_LOG}" ]]
    then
        echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    else
        echo -e "${log_msg}"
    fi
}

log_info() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    emit_log_line "${log_msg}"
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    emit_log_line "${log_msg}"
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    emit_log_line "${log_msg}"
}

log_debug() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    emit_log_line "${log_msg}"
}

# ── Temp file creation (tracked for cleanup) ─────────────────────────────────
create_temp_file() {
    local label="${1:-tmp}"
    local f
    f=$("${MKTEMP}" -t "${SCRIPT_NAME%.sh}.${label}")
    TEMP_FILES+=("${f}")
    printf '%s' "${f}"
}

# ── swiftDialog command file ─────────────────────────────────────────────────
# Must be readable by the dialog even when it runs as the console user via
# launchctl asuser, so it lives in world-traversable /private/tmp — NOT root's
# private $TMPDIR (which the console user cannot enter). 0644: root writes, the
# dialog reads. (Using mktemp's random suffix keeps the path unpredictable.)
create_cmd_file() {
    local f
    f=$("${MKTEMP}" "/private/tmp/${SCRIPT_NAME%.sh}.cmd.XXXXXX")
    "${CHMOD}" 644 "${f}"
    TEMP_FILES+=("${f}")
    printf '%s' "${f}"
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
cleanup() {
    local exit_code=$?
    # Close any lingering progress dialog before removing its command file —
    # ask it to quit, then force-kill it (targeted by its unique command file).
    if [[ -n "${PROGRESS_CMD_FILE}" && -f "${PROGRESS_CMD_FILE}" ]]
    then
        printf 'quit:\n' >> "${PROGRESS_CMD_FILE}" 2>/dev/null || true
        "${PKILL}" -f "${PROGRESS_CMD_FILE}" 2>/dev/null || true
    fi
    # Never leave a Jamf token dangling (HikariCP connection-pool hygiene)
    if [[ -n "${JAMF_TOKEN}" && -n "${JAMF_URL}" ]]
    then
        "${CURL}" --silent --location --max-time 10 --request POST \
            --header "Authorization: Bearer ${JAMF_TOKEN}" \
            --output /dev/null "${JAMF_URL}/api/v1/auth/invalidate-token" 2>/dev/null || true
        JAMF_TOKEN=""
    fi
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

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

# ── User-context resolution + dialog wrapper ─────────────────────────────────
resolve_run_context() {
    # If we're root (sudo / future Rundeck), display dialogs as the console user.
    # If we're already a logged-in admin, run dialogs directly in this session.
    if [[ "$("${ID}" -u)" -eq 0 ]]
    then
        CURRENT_USER=$("${SCUTIL}" <<< "show State:/Users/ConsoleUser" \
            | "${AWK}" '/Name :/ && !/loginwindow/ { print $3 }')
        if [[ -z "${CURRENT_USER}" || "${CURRENT_USER}" == "root" ]]
        then
            return 1
        fi
        CONSOLE_UID=$("${ID}" -u "${CURRENT_USER}")
    else
        CURRENT_USER=$("${ID}" -un)
        CONSOLE_UID=$("${ID}" -u)
    fi
    return 0
}

run_dialog() {
    if [[ "$("${ID}" -u)" -eq 0 ]]
    then
        "${LAUNCHCTL}" asuser "${CONSOLE_UID}" "${SUDO}" -u "${CURRENT_USER}" \
            "${DIALOG_BIN}" "$@" 2>/dev/null
    else
        "${DIALOG_BIN}" "$@" 2>/dev/null
    fi
}

# ── Indeterminate "working" progress dialog (cancellable) ────────────────────
start_progress() {
    local text="${1:-Working…}"
    PROGRESS_SEEN=0
    PROGRESS_CMD_FILE=$(create_cmd_file)
    run_dialog \
        --height "${appSizeSmall}" \
        --icon "${DIALOG_ICON}" \
        --overlayicon "SF=arrow.triangle.2.circlepath,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${text}" \
        --progress \
        --progresstext "${text}" \
        --button1text "Cancel" \
        --infotext "v${SCRIPT_VERSION}" \
        --ontop --moveable \
        --commandfile "${PROGRESS_CMD_FILE}" &
    PROGRESS_PID=$!
}

# Push a live status line into the progress dialog (body + text under the bar).
update_progress() {
    local text="$1"
    if [[ -n "${PROGRESS_CMD_FILE}" && -f "${PROGRESS_CMD_FILE}" ]]
    then
        printf 'message: %s\nprogresstext: %s\n' "${text}" "${text}" >> "${PROGRESS_CMD_FILE}" 2>/dev/null || true
    fi
}

# True (0) once the progress dialog has appeared and then been dismissed (the
# technician clicked Cancel). Targets THIS dialog by its unique command-file
# path, so other swiftDialog windows are never matched.
progress_cancelled() {
    if [[ -z "${PROGRESS_CMD_FILE}" ]]
    then
        return 1
    fi
    if "${PGREP}" -f "${PROGRESS_CMD_FILE}" >/dev/null 2>&1
    then
        PROGRESS_SEEN=1
        return 1
    fi
    if [[ "${PROGRESS_SEEN}" == "1" ]]
    then
        return 0
    fi
    return 1
}

# If the technician clicked Cancel, tear down and exit cleanly.
abort_if_cancelled() {
    if progress_cancelled
    then
        log_info "Cancelled by technician"
        stop_progress
        exit 0
    fi
}

# Close the progress dialog: ask it to quit, wait briefly, then force-kill if it
# lingers (e.g. an unresponsive dialog) so the script never hangs.
stop_progress() {
    if [[ -n "${PROGRESS_CMD_FILE}" && -f "${PROGRESS_CMD_FILE}" ]]
    then
        printf 'quit:\n' >> "${PROGRESS_CMD_FILE}" 2>/dev/null || true
    fi
    local n=0
    while [[ ${n} -lt 10 && -n "${PROGRESS_CMD_FILE}" ]] && "${PGREP}" -f "${PROGRESS_CMD_FILE}" >/dev/null 2>&1
    do
        "${SLEEP}" 0.3
        n=$(( n + 1 ))
    done
    if [[ -n "${PROGRESS_CMD_FILE}" ]] && "${PGREP}" -f "${PROGRESS_CMD_FILE}" >/dev/null 2>&1
    then
        "${PKILL}" -f "${PROGRESS_CMD_FILE}" 2>/dev/null || true
    fi
    if [[ -n "${PROGRESS_PID}" ]]
    then
        wait "${PROGRESS_PID}" 2>/dev/null || true
        PROGRESS_PID=""
    fi
    PROGRESS_CMD_FILE=""
    PROGRESS_SEEN=0
}

# ── Configuration validation ─────────────────────────────────────────────────
# True (0) if a credential/config value is present and not a placeholder.
value_is_set() {
    local value="$1"
    if [[ -z "${value}" || "${value}" == *REPLACE-WITH* || "${value}" == *YOUR_* ]]
    then
        return 1
    fi
    return 0
}

# Record a missing required parameter. Appends to the CONFIG_ERROR list so the
# technician sees every problem in one dialog; load_config's caller exits.
require_param() {
    local name="$1"
    local value="$2"
    if ! value_is_set "${value}"
    then
        log_error "Required parameter ${name} is empty or a placeholder"
        CONFIG_ERROR="${CONFIG_ERROR}• ${name} is not set\n"
        return 1
    fi
    return 0
}

load_config() {
    CONFIG_ERROR=""

    if [[ "${SOURCE}" == "jamf" ]]
    then
        require_param "Jamf API Client ID (\$10 / JAMF_CLIENT_ID)" "${JAMF_CLIENT_ID}" || true
        require_param "Jamf API Client Secret (\$11 / JAMF_CLIENT_SECRET)" "${JAMF_CLIENT_SECRET}" || true
        if ! resolve_jamf_url
        then
            CONFIG_ERROR="${CONFIG_ERROR}• Could not determine the Jamf Pro URL (Mac not enrolled? set JAMF_URL_OVERRIDE)\n"
        fi
    else
        # ── ABM source (default) ─────────────────────────────────────────────
        require_param "ABM Client ID (\$7 / ABM_CLIENT_ID)" "${ABM_CLIENT_ID}" || true
        require_param "ABM Key ID (\$8 / ABM_KEY_ID)" "${ABM_KEY_ID}" || true
        if require_param "ABM private key file (\$9 / ABM_KEY_FILE)" "${ABM_KEY_FILE}"
        then
            if [[ ! -f "${ABM_KEY_FILE}" || ! -r "${ABM_KEY_FILE}" ]]
            then
                CONFIG_ERROR="${CONFIG_ERROR}• ABM private key file not found or not readable: ${ABM_KEY_FILE}\n"
            elif ! "${OPENSSL}" pkey -in "${ABM_KEY_FILE}" -noout >/dev/null 2>&1
            then
                CONFIG_ERROR="${CONFIG_ERROR}• ABM private key file could not be parsed by OpenSSL\n"
            else
                local key_perms
                key_perms=$("${STAT}" -f '%Lp' "${ABM_KEY_FILE}" 2>/dev/null || printf '')
                if [[ -n "${key_perms}" && "${key_perms: -2}" != "00" ]]
                then
                    log_warn "ABM private key file is group/world accessible (mode ${key_perms}); chmod 600 recommended"
                fi
            fi
        fi
        if [[ "${MODE}" == "support" ]] && ! value_is_set "${SUPPORT_MODE_MDM_NAME}"
        then
            CONFIG_ERROR="${CONFIG_ERROR}• Support-mode MDM server name (SUPPORT_MODE_MDM_NAME) is still a placeholder\n"
        fi
    fi

    if [[ -n "${CONFIG_ERROR}" ]]
    then
        return 1
    fi
    return 0
}

# ── base64url helper (reads stdin: text or binary) ───────────────────────────
b64url() {
    "${OPENSSL}" enc -base64 -A | "${TR}" '+/' '-_' | "${TR}" -d '='
}

# ── Build the ES256 OAuth client-assertion JWT (sets CLIENT_ASSERTION) ───────
# Sets a global instead of printing: this function logs on failure, and log
# helpers write to stdout, so capturing it with $(...) would pollute the JWT.
build_client_assertion() {
    CLIENT_ASSERTION=""
    local now exp jti header_json payload_json
    now=$("${DATE}" +%s)
    exp=$(( now + ABM_JWT_LIFETIME ))
    jti=$("${UUIDGEN}")

    header_json=$("${JQ}" -c -n \
        --arg kid "${ABM_KEY_ID}" \
        '{alg:"ES256", kid:$kid, typ:"JWT"}')

    payload_json=$("${JQ}" -c -n \
        --arg iss "${ABM_CLIENT_ID}" \
        --arg sub "${ABM_CLIENT_ID}" \
        --arg aud "${ABM_TOKEN_AUD}" \
        --argjson iat "${now}" \
        --argjson exp "${exp}" \
        --arg jti "${jti}" \
        '{sub:$sub, aud:$aud, iss:$iss, iat:$iat, exp:$exp, jti:$jti}')

    local b64_header b64_payload signing_input
    b64_header=$(printf '%s' "${header_json}" | b64url)
    b64_payload=$(printf '%s' "${payload_json}" | b64url)
    signing_input="${b64_header}.${b64_payload}"

    # Sign with ECDSA P-256 / SHA-256 → DER-encoded signature
    local der_file
    der_file=$(create_temp_file "jwtsig")
    if ! printf '%s' "${signing_input}" \
        | "${OPENSSL}" dgst -sha256 -sign "${ABM_KEY_FILE}" -binary > "${der_file}" 2>/dev/null
    then
        log_error "OpenSSL failed to sign the JWT — check the ABM private key file"
        return 1
    fi

    # JOSE requires raw R||S (64 bytes), not DER. Parse the two INTEGERs and
    # left-pad each to 32 bytes (64 hex chars).
    local asn r s
    asn=$("${OPENSSL}" asn1parse -inform DER -in "${der_file}" 2>/dev/null)
    r=$("${AWK}" -F: '/INTEGER/{c++; if(c==1){gsub(/[^0-9A-Fa-f]/,"",$NF); print $NF}}' <<< "${asn}")
    s=$("${AWK}" -F: '/INTEGER/{c++; if(c==2){gsub(/[^0-9A-Fa-f]/,"",$NF); print $NF}}' <<< "${asn}")

    if [[ -z "${r}" || -z "${s}" ]]
    then
        log_error "Could not parse ECDSA r/s from DER signature"
        return 1
    fi
    if [[ ${#r} -gt 64 || ${#s} -gt 64 ]]
    then
        log_error "Unexpected ECDSA integer length (key may not be P-256)"
        return 1
    fi

    while [[ ${#r} -lt 64 ]]
    do
        r="0${r}"
    done
    while [[ ${#s} -lt 64 ]]
    do
        s="0${s}"
    done

    local b64_sig
    b64_sig=$(printf '%s' "${r}${s}" | "${XXD}" -r -p | b64url)

    CLIENT_ASSERTION="${signing_input}.${b64_sig}"
    return 0
}

# ── Exchange the client-assertion for an access token ────────────────────────
get_access_token() {
    if ! build_client_assertion
    then
        AUTH_ERROR="Failed to build the client-assertion JWT."
        return 1
    fi

    local resp_file http_code
    resp_file=$(create_temp_file "token")
    if ! http_code=$("${CURL}" --silent --show-error --location --max-time "${ABM_HTTP_TIMEOUT}" \
        --request POST \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${ABM_CLIENT_ID}" \
        --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
        --data-urlencode "client_assertion=${CLIENT_ASSERTION}" \
        --data-urlencode "scope=${ABM_SCOPE}" \
        --output "${resp_file}" \
        --write-out '%{http_code}' \
        "${ABM_TOKEN_URL}")
    then
        AUTH_ERROR="Network error contacting the Apple token endpoint."
        return 1
    fi

    if [[ "${http_code}" != "200" ]]
    then
        local err
        err=$("${JQ}" -r '.error // "unknown_error"' "${resp_file}" 2>/dev/null || printf 'unknown_error')
        AUTH_ERROR="Token request failed (HTTP ${http_code} / ${err}). Verify Client ID, Key ID, key, and scope."
        return 1
    fi

    ACCESS_TOKEN=$("${JQ}" -r '.access_token // empty' "${resp_file}")
    if [[ -z "${ACCESS_TOKEN}" ]]
    then
        AUTH_ERROR="Token endpoint returned no access_token."
        return 1
    fi
    return 0
}

# ── Authenticated GET to a full URL → writes body to file, prints HTTP code ──
abm_get_url() {
    local url="$1"
    local out_file="$2"
    local code attempt=0
    # --globoff: these URLs contain literal [ ] (e.g. fields[orgDevices]); without
    # it curl treats brackets as glob ranges and rejects the URL (exit 3).
    # HTTP 000 = no response (transient network / timeout) — retry once. Always
    # prints the final code and returns 0; callers branch on the printed code.
    while [[ ${attempt} -lt 2 ]]
    do
        if ! code=$("${CURL}" --silent --show-error --location --globoff \
            --connect-timeout 15 --max-time "${ABM_HTTP_TIMEOUT}" \
            --request GET \
            --header "Authorization: Bearer ${ACCESS_TOKEN}" \
            --header "Accept: application/json" \
            --output "${out_file}" \
            --write-out '%{http_code}' \
            "${url}")
        then
            code="000"
        fi
        if [[ "${code}" != "000" ]]
        then
            printf '%s' "${code}"
            return 0
        fi
        attempt=$(( attempt + 1 ))
        "${SLEEP}" 2
    done
    printf '000'
    return 0
}

# ── Fetch all MDM servers (paged) into NDJSON file ───────────────────────────
fetch_all_mdm_servers() {
    MDM_SERVERS_FILE=$(create_temp_file "mdmservers")
    : > "${MDM_SERVERS_FILE}"

    local url="${ABM_API_BASE}/v1/mdmServers?limit=${ABM_PAGE_LIMIT}"
    local page_file http_code next
    while [[ -n "${url}" ]]
    do
        page_file=$(create_temp_file "mdmpage")
        if ! http_code=$(abm_get_url "${url}" "${page_file}")
        then
            http_code="000"
        fi
        if [[ "${http_code}" != "200" ]]
        then
            MDM_FETCH_ERROR="Could not list MDM servers (HTTP ${http_code})."
            return 1
        fi
        "${JQ}" -c '.data[]?' "${page_file}" >> "${MDM_SERVERS_FILE}"
        next=$("${JQ}" -r '.links.next // empty' "${page_file}")
        url="${next}"
    done
    return 0
}

# ── Find a device by serial number ───────────────────────────────────────────
# Fast path: a direct GET /v1/orgDevices/{serial} (the orgDevice id equals the
# serial in tested tenants) resolves instantly. Apple documents id as opaque, so on
# anything other than a clean 200 with a matching serial we fall back to full
# pagination + client-side match (the universally-correct method).
find_device_by_serial() {
    local serial="$1"
    local page_file http_code match next direct_file direct_serial

    DEVICE_JSON=""
    DEVICE_LOOKUP_STATUS=""
    DEVICE_LOOKUP_DETAIL=""

    # ── Fast path: direct lookup by serial-as-id ─────────────────────────────
    direct_file=$(create_temp_file "devdirect")
    if ! http_code=$(abm_get_url "${ABM_API_BASE}/v1/orgDevices/${serial}?fields[orgDevices]=${ABM_DEVICE_FIELDS}" "${direct_file}")
    then
        http_code="000"
    fi
    if [[ "${http_code}" == "200" ]]
    then
        # Single-resource GET returns .data as an object; tolerate an array too.
        direct_serial=$("${JQ}" -r '(.data | if type=="array" then .[0] else . end | .attributes.serialNumber) // empty' "${direct_file}" 2>/dev/null || printf '')
        if [[ -n "${direct_serial}" \
            && "$(printf '%s' "${direct_serial}" | "${TR}" '[:lower:]' '[:upper:]')" == "$(printf '%s' "${serial}" | "${TR}" '[:lower:]' '[:upper:]')" ]]
        then
            DEVICE_JSON=$("${JQ}" -c '.data | if type=="array" then .[0] else . end' "${direct_file}")
            DEVICE_LOOKUP_STATUS="found"
            log_info "Device ${serial} resolved via direct lookup"
            return 0
        fi
    fi
    log_debug "Direct lookup for ${serial} not usable (HTTP ${http_code}); paging orgDevices"

    # ── Fallback: page orgDevices and match client-side ──────────────────────
    local url="${ABM_API_BASE}/v1/orgDevices?limit=${ABM_PAGE_LIMIT}&fields[orgDevices]=${ABM_DEVICE_FIELDS}"
    local checked=0 page_count
    while [[ -n "${url}" ]]
    do
        abort_if_cancelled
        page_file=$(create_temp_file "devpage")
        if ! http_code=$(abm_get_url "${url}" "${page_file}")
        then
            http_code="000"
        fi
        if [[ "${http_code}" != "200" ]]
        then
            DEVICE_LOOKUP_STATUS="error"
            DEVICE_LOOKUP_DETAIL="orgDevices query failed (HTTP ${http_code})."
            return 0
        fi

        match=$("${JQ}" -c --arg s "${serial}" \
            'first(.data[]? | select((.attributes.serialNumber // "") | ascii_upcase == ($s | ascii_upcase))) // empty' \
            "${page_file}")
        if [[ -n "${match}" ]]
        then
            DEVICE_JSON="${match}"
            DEVICE_LOOKUP_STATUS="found"
            return 0
        fi

        page_count=$("${JQ}" -r '.data | length' "${page_file}" 2>/dev/null || printf '0')
        checked=$(( checked + page_count ))
        update_progress "Searching Apple Business Manager…  (${checked} devices checked)"

        next=$("${JQ}" -r '.links.next // empty' "${page_file}")
        url="${next}"
    done

    DEVICE_LOOKUP_STATUS="notfound"
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# Jamf Pro API — read-only ADE/DEP lookup (used when SOURCE = jamf)
# ═════════════════════════════════════════════════════════════════════════════

# Resolve the Jamf Pro base URL: override if set, else the Mac's management plist.
resolve_jamf_url() {
    if [[ -n "${JAMF_URL_OVERRIDE}" ]]
    then
        JAMF_URL="${JAMF_URL_OVERRIDE%/}"
        return 0
    fi
    JAMF_URL=$("${DEFAULTS}" read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null | "${SED}" -e 's:/*$::')
    if [[ -z "${JAMF_URL}" ]]
    then
        return 1
    fi
    return 0
}

# OAuth 2.0 client-credentials token.
get_jamf_token() {
    JAMF_TOKEN=""
    JAMF_AUTH_ERROR=""
    local resp_file http_code
    resp_file=$(create_temp_file "jamftoken")
    if ! http_code=$("${CURL}" --silent --show-error --location \
        --connect-timeout 15 --max-time "${ABM_HTTP_TIMEOUT}" \
        --request POST \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${JAMF_CLIENT_ID}" \
        --data-urlencode "client_secret=${JAMF_CLIENT_SECRET}" \
        --output "${resp_file}" \
        --write-out '%{http_code}' \
        "${JAMF_URL}/api/oauth/token")
    then
        JAMF_AUTH_ERROR="Network error contacting Jamf Pro (${JAMF_URL})."
        return 1
    fi
    if [[ "${http_code}" != "200" ]]
    then
        JAMF_AUTH_ERROR="Token request failed (HTTP ${http_code}). Verify the API client ID/secret and role."
        return 1
    fi
    JAMF_TOKEN=$("${JQ}" -r '.access_token // empty' "${resp_file}")
    if [[ -z "${JAMF_TOKEN}" ]]
    then
        JAMF_AUTH_ERROR="Jamf Pro returned no access_token."
        return 1
    fi
    return 0
}

# Invalidate the Jamf token (skill: never leave tokens dangling).
invalidate_jamf_token() {
    if [[ -z "${JAMF_TOKEN}" ]]
    then
        return 0
    fi
    "${CURL}" --silent --location --max-time 10 --request POST \
        --header "Authorization: Bearer ${JAMF_TOKEN}" \
        --output /dev/null "${JAMF_URL}/api/v1/auth/invalidate-token" 2>/dev/null || true
    JAMF_TOKEN=""
    return 0
}

# Authenticated GET (bearer) → body to file, prints HTTP code; retries once on 000.
jamf_get_url() {
    local url="$1"
    local out_file="$2"
    local code attempt=0
    while [[ ${attempt} -lt 2 ]]
    do
        if ! code=$("${CURL}" --silent --show-error --location \
            --connect-timeout 15 --max-time "${ABM_HTTP_TIMEOUT}" \
            --request GET \
            --header "Authorization: Bearer ${JAMF_TOKEN}" \
            --header "Accept: application/json" \
            --output "${out_file}" \
            --write-out '%{http_code}' \
            "${url}")
        then
            code="000"
        fi
        if [[ "${code}" != "000" ]]
        then
            printf '%s' "${code}"
            return 0
        fi
        attempt=$(( attempt + 1 ))
        "${SLEEP}" 2
    done
    printf '000'
    return 0
}

# Find a device by serial across every Device Enrollment (ADE) instance. Sets
# JAMF_DEVICE_JSON (matched record), JAMF_INSTANCE_NAME, and JAMF_LOOKUP_STATUS
# = found | notfound | error.
jamf_find_device_by_serial() {
    local serial="$1"
    JAMF_DEVICE_JSON=""
    JAMF_INSTANCE_NAME=""
    JAMF_LOOKUP_STATUS=""
    JAMF_LOOKUP_DETAIL=""

    # 1) List all device enrollment instances
    local inst_file http_code
    inst_file=$(create_temp_file "jamfinst")
    if ! http_code=$(jamf_get_url "${JAMF_URL}/api/v1/device-enrollments?page=0&page-size=100" "${inst_file}")
    then
        http_code="000"
    fi
    if [[ "${http_code}" != "200" ]]
    then
        JAMF_LOOKUP_STATUS="error"
        JAMF_LOOKUP_DETAIL="Could not list device enrollments (HTTP ${http_code})."
        return 0
    fi

    # 2) Search each instance's devices for the serial (client-side match)
    local ids iid dev_file match
    ids=$("${JQ}" -r '.results[]?.id // empty' "${inst_file}")
    while IFS= read -r iid
    do
        if [[ -z "${iid}" ]]
        then
            continue
        fi
        abort_if_cancelled
        update_progress "Searching Automated Device Enrollment…  (instance ${iid})"
        dev_file=$(create_temp_file "jamfdev")
        if ! http_code=$(jamf_get_url "${JAMF_URL}/api/v1/device-enrollments/${iid}/devices" "${dev_file}")
        then
            http_code="000"
        fi
        if [[ "${http_code}" != "200" ]]
        then
            JAMF_LOOKUP_STATUS="error"
            JAMF_LOOKUP_DETAIL="Could not read devices for enrollment ${iid} (HTTP ${http_code})."
            return 0
        fi
        match=$("${JQ}" -c --arg s "${serial}" \
            'first(.results[]? | select((.serialNumber // "") | ascii_upcase == ($s | ascii_upcase))) // empty' \
            "${dev_file}")
        if [[ -n "${match}" ]]
        then
            JAMF_DEVICE_JSON="${match}"
            JAMF_INSTANCE_NAME=$("${JQ}" -r --arg i "${iid}" '.results[]? | select(.id==$i) | .name // empty' "${inst_file}")
            JAMF_LOOKUP_STATUS="found"
            return 0
        fi
    done <<< "${ids}"

    JAMF_LOOKUP_STATUS="notfound"
    return 0
}

# ── Resolve an MDM server's name from its id (from the NDJSON cache) ──────────
resolve_server_name() {
    local sid="$1"
    "${JQ}" -r -s --arg id "${sid}" \
        'map(select(.id==$id)) | .[0].attributes.serverName // empty' \
        "${MDM_SERVERS_FILE}"
}

# ── Resolve an MDM server's id from its name (from the NDJSON cache) ──────────
resolve_server_id() {
    local sname="$1"
    "${JQ}" -r -s --arg n "${sname}" \
        'map(select(.attributes.serverName==$n)) | .[0].id // empty' \
        "${MDM_SERVERS_FILE}"
}

# ── Build comma-separated dropdown values (preferred server first) ───────────
build_select_values() {
    "${JQ}" -r -s --arg pref "${ABM_PREFERRED_MDM_NAME}" '
        [ .[].attributes.serverName ] as $all
        | (if (($pref|length) > 0) and ($all|index($pref)) then
              ([$pref] + ($all - [$pref]))
           else $all end)
        | join(",")
    ' "${MDM_SERVERS_FILE}"
}

# ── Look up a device's currently-assigned MDM server id (or empty) ───────────
get_assigned_server_id() {
    local device_id="$1"
    local resp_file http_code
    resp_file=$(create_temp_file "assignedsrv")
    if ! http_code=$(abm_get_url "${ABM_API_BASE}/v1/orgDevices/${device_id}/relationships/assignedServer" "${resp_file}")
    then
        http_code="000"
    fi
    if [[ "${http_code}" == "200" ]]
    then
        "${JQ}" -r '.data.id // empty' "${resp_file}"
        return 0
    fi
    printf ''
    return 0
}

# ── Fetch a device's AppleCare coverage (best-effort; sets APPLECARE_JSON) ────
get_applecare_coverage() {
    local device_id="$1"
    local resp_file http_code count
    APPLECARE_JSON='{"data":[]}'
    resp_file=$(create_temp_file "applecare")
    if ! http_code=$(abm_get_url "${ABM_API_BASE}/v1/orgDevices/${device_id}/appleCareCoverage" "${resp_file}")
    then
        http_code="000"
    fi
    if [[ "${http_code}" == "200" ]]
    then
        # Shape: { "data": [ { "attributes": { description, status,
        #         startDateTime, endDateTime, isRenewable, ... } } ] }
        APPLECARE_JSON=$("${JQ}" -c '{data: (.data // [])}' "${resp_file}" 2>/dev/null || printf '{"data":[]}')
        count=$("${JQ}" -r '.data | length' <<< "${APPLECARE_JSON}" 2>/dev/null || printf '0')
        log_info "AppleCare HTTP 200 for ${device_id}: ${count} coverage record(s)"
    else
        log_debug "AppleCare coverage unavailable for ${device_id} (HTTP ${http_code})"
    fi
    return 0
}

# ── Pick a hardware icon for the device ──────────────────────────────────────
# Returns a swiftDialog --icon value: ONE photorealistic com.apple.*.icns per
# device family/type — the latest representative, NOT an exact model/size match
# (every iMac → current iMac photo, every Mac mini → current mini, etc.). The
# first listed candidate that exists wins (the 2nd is a cross-version fallback);
# "SF=<symbol>" is used only where macOS ships no photo (Apple Watch / Vision).
# Match order: Air → MacBook → mini → studio → iMac → Mac Pro, so iMac Pro /
# MacBook Pro never fall into the Mac Pro branch.
device_icon_value() {
    local family="$1"
    local model="$2"
    local lc_model
    lc_model=$(printf '%s' "${model}" | "${TR}" '[:upper:]' '[:lower:]')
    local sf="desktopcomputer"
    local -a candidates=()

    case "${family}" in
        iPhone)
            candidates=( "com.apple.iphone.icns" )
            sf="iphone"
            ;;
        iPad)
            candidates=( "com.apple.ipad.icns" )
            sf="ipad"
            ;;
        AppleTV)
            candidates=( "com.apple.apple-tv.icns" )
            sf="appletv"
            ;;
        Watch)
            sf="applewatch"
            ;;
        Vision)
            sf="vision.pro"
            ;;
        Mac)
            if [[ "${lc_model}" == *air* ]]
            then
                candidates=( "com.apple.macbookair-13-2022-silver.icns" "com.apple.macbookair.icns" )
                sf="laptopcomputer"
            elif [[ "${lc_model}" == *book* ]]
            then
                candidates=( "com.apple.macbookpro-16-2021-space-gray.icns" "com.apple.macbookpro-14-2021-silver.icns" )
                sf="laptopcomputer"
            elif [[ "${lc_model}" == *mini* ]]
            then
                candidates=( "com.apple.macmini-2020.icns" "com.apple.macmini.icns" )
                sf="macmini"
            elif [[ "${lc_model}" == *studio* ]]
            then
                candidates=( "com.apple.macstudio.icns" )
                sf="macstudio"
            elif [[ "${lc_model}" == *imac* ]]
            then
                candidates=( "com.apple.imac-2021-silver.icns" "com.apple.imac-unibody-27.icns" )
                sf="desktopcomputer"
            elif [[ "${lc_model}" == *pro* ]]
            then
                candidates=( "com.apple.macpro-2019.icns" "com.apple.macpro.icns" )
                sf="macpro.gen3"
            else
                candidates=( "com.apple.imac-2021-silver.icns" )
                sf="desktopcomputer"
            fi
            ;;
    esac

    local c
    if [[ ${#candidates[@]} -gt 0 ]]
    then
        for c in "${candidates[@]}"
        do
            if [[ -f "${DEVICE_ICON_DIR}/${c}" ]]
            then
                printf '%s/%s' "${DEVICE_ICON_DIR}" "${c}"
                return 0
            fi
        done
    fi
    printf 'SF=%s' "${sf}"
}

# ── Format an ISO date (e.g. addedToOrgDateTime) as "Month DD, YYYY" ─────────
format_date() {
    local raw="$1"
    local datepart="${raw%%T*}"
    local out=""
    if [[ -z "${datepart}" ]]
    then
        printf ''
        return 0
    fi
    if out=$("${DATE}" -j -f "%Y-%m-%d" "${datepart}" "+%B %d, %Y" 2>/dev/null)
    then
        printf '%s' "${out}"
    else
        printf '%s' "${datepart}"
    fi
}

# ── Build AppleCare markdown list lines from APPLECARE_JSON (real newlines) ───
build_applecare_md() {
    local count i desc st st_display start_raw end_raw start_fmt end_fmt out=""
    count=$("${JQ}" -r '(.data // []) | length' <<< "${APPLECARE_JSON}" 2>/dev/null || printf '0')
    if [[ -z "${count}" || "${count}" == "0" ]]
    then
        printf -- '- **AppleCare/Warranty:** No coverage on record'
        return 0
    fi

    i=0
    while [[ ${i} -lt ${count} ]]
    do
        desc=$("${JQ}" -r --argjson i "${i}" '.data[$i].attributes.description // "Coverage"' <<< "${APPLECARE_JSON}")
        st=$("${JQ}" -r --argjson i "${i}" '.data[$i].attributes.status // empty' <<< "${APPLECARE_JSON}")
        start_raw=$("${JQ}" -r --argjson i "${i}" '.data[$i].attributes.startDateTime // empty' <<< "${APPLECARE_JSON}")
        end_raw=$("${JQ}" -r --argjson i "${i}" '.data[$i].attributes.endDateTime // empty' <<< "${APPLECARE_JSON}")

        case "${st}" in
            ACTIVE)
                st_display="Active"
                ;;
            INACTIVE)
                st_display="Expired"
                ;;
            "")
                st_display=""
                ;;
            *)
                st_display="${st}"
                ;;
        esac

        start_fmt=$(format_date "${start_raw}")
        end_fmt=$(format_date "${end_raw}")

        if [[ -n "${st_display}" ]]
        then
            out="${out}- **AppleCare/Warranty:** ${desc} — ${st_display}"$'\n'
        else
            out="${out}- **AppleCare/Warranty:** ${desc}"$'\n'
        fi
        if [[ -n "${start_fmt}" || -n "${end_fmt}" ]]
        then
            out="${out}- **Coverage period:** ${start_fmt:-?} – ${end_fmt:-?}"$'\n'
        fi
        i=$(( i + 1 ))
    done
    printf '%s' "${out%$'\n'}"
}

# ── Create an assign/unassign activity (POST /v1/orgDeviceActivities) ─────────
# activity_type: ASSIGN_DEVICES | UNASSIGN_DEVICES
# mdm_id: the MDM server id. ABM REQUIRES the mdmServer relationship for BOTH
#         assign (the target server) AND unassign (the device's current server),
#         so the body includes mdmServer whenever mdm_id is non-empty.
submit_device_activity() {
    local activity_type="$1"
    local device_id="$2"
    local mdm_id="${3:-}"
    local body_file resp_file http_code

    ASSIGN_ERROR=""
    ACTIVITY_ID=""

    body_file=$(create_temp_file "activitybody")
    if [[ -n "${mdm_id}" ]]
    then
        "${JQ}" -n \
            --arg at "${activity_type}" \
            --arg did "${device_id}" \
            --arg mid "${mdm_id}" \
            '{data:{type:"orgDeviceActivities",
                    attributes:{activityType:$at},
                    relationships:{
                        mdmServer:{data:{type:"mdmServers", id:$mid}},
                        devices:{data:[{type:"orgDevices", id:$did}]}
                    }}}' \
            > "${body_file}"
    else
        "${JQ}" -n \
            --arg at "${activity_type}" \
            --arg did "${device_id}" \
            '{data:{type:"orgDeviceActivities",
                    attributes:{activityType:$at},
                    relationships:{
                        devices:{data:[{type:"orgDevices", id:$did}]}
                    }}}' \
            > "${body_file}"
    fi
    log_info "Activity request (${activity_type}): $("${JQ}" -c . "${body_file}" 2>/dev/null)"

    resp_file=$(create_temp_file "activityresp")
    if ! http_code=$("${CURL}" --silent --show-error --location --max-time "${ABM_HTTP_TIMEOUT}" \
        --request POST \
        --header "Authorization: Bearer ${ACCESS_TOKEN}" \
        --header "Content-Type: application/json" \
        --header "Accept: application/json" \
        --data @"${body_file}" \
        --output "${resp_file}" \
        --write-out '%{http_code}' \
        "${ABM_API_BASE}/v1/orgDeviceActivities")
    then
        ASSIGN_ERROR="Network error submitting the request."
        return 1
    fi

    if [[ "${http_code}" != "201" && "${http_code}" != "200" ]]
    then
        log_warn "Activity HTTP ${http_code} response: $("${JQ}" -c . "${resp_file}" 2>/dev/null || printf '<non-json>')"
        local emsg
        emsg=$("${JQ}" -r '.errors[0].detail // .errors[0].title // "unknown error"' "${resp_file}" 2>/dev/null || printf 'unknown error')
        ASSIGN_ERROR="Request rejected (HTTP ${http_code}): ${emsg}"
        return 1
    fi

    ACTIVITY_ID=$("${JQ}" -r '.data.id // empty' "${resp_file}")
    if [[ -z "${ACTIVITY_ID}" ]]
    then
        ASSIGN_ERROR="Request submitted but no activity ID was returned."
        return 1
    fi
    return 0
}

# ── Poll an activity until it reaches a terminal status (or timeout) ──────────
poll_activity() {
    local activity_id="$1"
    local attempt=0
    local resp_file http_code

    ACTIVITY_STATUS=""
    ACTIVITY_SUBSTATUS=""

    while [[ ${attempt} -lt ${ABM_POLL_MAX_ATTEMPTS} ]]
    do
        resp_file=$(create_temp_file "activity")
        if ! http_code=$(abm_get_url "${ABM_API_BASE}/v1/orgDeviceActivities/${activity_id}" "${resp_file}")
        then
            http_code="000"
        fi
        if [[ "${http_code}" == "200" ]]
        then
            ACTIVITY_STATUS=$("${JQ}" -r '.data.attributes.status // empty' "${resp_file}")
            ACTIVITY_SUBSTATUS=$("${JQ}" -r '.data.attributes.subStatus // empty' "${resp_file}")
            if [[ "${ACTIVITY_STATUS}" == "COMPLETED" \
                || "${ACTIVITY_STATUS}" == "FAILED" \
                || "${ACTIVITY_STATUS}" == "STOPPED" ]]
            then
                return 0
            fi
        fi
        attempt=$(( attempt + 1 ))
        "${SLEEP}" "${ABM_POLL_INTERVAL}"
    done
    return 0
}

# ── Simple branded info/notification dialog ──────────────────────────────────
show_message() {
    local message="$1"
    local sf_symbol="${2:-info.circle.fill}"
    local colour="${3:-blue}"
    local size="${4:-${appSizeMedium}}"
    if ! run_dialog \
        --height "${size}" \
        --icon "${DIALOG_ICON}" \
        --overlayicon "SF=${sf_symbol},colour=${colour}" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${message}" \
        --button1text "OK" \
        --infotext "v${SCRIPT_VERSION}" \
        --ontop --moveable
    then
        log_debug "Info dialog dismissed"
    fi
}

# ── Preflight: required binaries ─────────────────────────────────────────────
preflight() {
    local b
    for b in "${CURL}" "${JQ}" "${OPENSSL}" "${XXD}" "${UUIDGEN}"
    do
        if [[ ! -x "${b}" ]]
        then
            log_error "Required binary missing or not executable: ${b}"
            return 1
        fi
    done
    if [[ ! -x "${DIALOG_BIN}" ]]
    then
        log_error "swiftDialog not found at ${DIALOG_BIN}"
        return 1
    fi
    return 0
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

# Preflight — binaries / swiftDialog must be present
if ! preflight
then
    printf 'Preflight failed — see logs (log label: %s)\n' "${LOG_LABEL}" >&2
    exit 1
fi

# Resolve who we display dialogs as (admin session now, root/Rundeck later)
if ! resolve_run_context
then
    log_error "Running as root with no GUI console user — cannot display dialogs"
    printf 'No logged-in GUI user to display dialogs to.\n' >&2
    exit 1
fi

# ── Resolve data source (Jamf Parameter 6: ABM | Jamf) ───────────────────────
SOURCE=$(printf '%s' "${PARAM_SOURCE:-${DEFAULT_SOURCE}}" | "${TR}" '[:upper:]' '[:lower:]' | "${TR}" -d '[:space:]')
case "${SOURCE}" in
    abm|jamf)
        ;;
    *)
        log_warn "Invalid source '${SOURCE}' (Parameter 6) — defaulting to '${DEFAULT_SOURCE}'"
        SOURCE=$(printf '%s' "${DEFAULT_SOURCE}" | "${TR}" '[:upper:]' '[:lower:]' | "${TR}" -d '[:space:]')
        ;;
esac
log_info "Data source: ${SOURCE}"

# ── Resolve operating mode (Jamf Parameter 4: admin | support) ───────────────
MODE=$(printf '%s' "${PARAM_MODE:-${DEFAULT_MODE}}" | "${TR}" '[:upper:]' '[:lower:]' | "${TR}" -d '[:space:]')
case "${MODE}" in
    admin|support)
        ;;
    *)
        log_warn "Invalid mode '${MODE}' (Parameter 4) — defaulting to '${DEFAULT_MODE}'"
        MODE="${DEFAULT_MODE}"
        ;;
esac
log_info "Operating mode: ${MODE}"

# Validate the selected source's configuration before doing anything else
if ! load_config
then
    show_message "The tool is not configured for the **${SOURCE}** data source:\n\n${CONFIG_ERROR}\nSupply the missing values as Jamf parameters or environment variables (see the Requirements section at the top of this script) and try again." \
        "exclamationmark.triangle.fill" "orange" "${appSizeLarge}"
    log_error "Configuration incomplete (source=${SOURCE})"
    exit 1
fi

# ── Step 1: obtain the serial number ─────────────────────────────────────────
# Use the serial from Jamf Parameter 5 if supplied; otherwise prompt.
SERIAL_INPUT="${PARAM_SERIAL}"

if [[ -z "${SERIAL_INPUT}" ]]
then
    serial_out=$(create_temp_file "serialprompt")
    if ! run_dialog \
        --height "${appSizeMedium}" \
        --icon "${appIcon}" \
        --overlayicon "SF=barcode.viewfinder,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "Enter the device **serial number** to look up its enrollment status." \
        --textfield "Serial Number,name=serialNumber,required,prompt=e.g. C02XXXXXXXXX,regex=^[A-Za-z0-9]+$,regexerror=Letters and numbers only" \
        --button1text "Look Up" \
        --button2text "Cancel" \
        --infotext "v${SCRIPT_VERSION}" \
        --ontop --moveable \
        --json \
        > "${serial_out}"
    then
        log_info "User cancelled at the serial prompt"
        exit 0
    fi
    SERIAL_INPUT=$("${JQ}" -r '.serialNumber // empty' "${serial_out}")
fi

# Normalize: uppercase, strip whitespace
SERIAL=$(printf '%s' "${SERIAL_INPUT}" | "${TR}" '[:lower:]' '[:upper:]' | "${TR}" -d '[:space:]')

if [[ -z "${SERIAL}" ]]
then
    show_message "No serial number was provided." "exclamationmark.triangle.fill" "orange" "${appSizeSmall}"
    exit 1
fi

log_info "Looking up serial: ${SERIAL}"

# ══════════════════════════════════════════════════════════════════════════════
# Jamf source — read-only ADE/DEP lookup (no ABM, no assignment)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${SOURCE}" == "jamf" ]]
then
    start_progress "Connecting to Jamf Pro…"

    if ! get_jamf_token
    then
        stop_progress
        show_message "Could not authenticate to Jamf Pro.\n\n${JAMF_AUTH_ERROR}" \
            "xmark.octagon.fill" "red" "${appSizeLarge}"
        log_error "Jamf auth failed: ${JAMF_AUTH_ERROR}"
        exit 1
    fi
    log_info "Obtained Jamf Pro access token"
    abort_if_cancelled

    update_progress "Searching Automated Device Enrollment…"
    jamf_find_device_by_serial "${SERIAL}"
    invalidate_jamf_token

    if [[ "${JAMF_LOOKUP_STATUS}" == "error" ]]
    then
        stop_progress
        show_message "Error searching Jamf Pro.\n\n${JAMF_LOOKUP_DETAIL}" \
            "xmark.octagon.fill" "red" "${appSizeLarge}"
        log_error "Jamf lookup error: ${JAMF_LOOKUP_DETAIL}"
        exit 1
    fi

    if [[ "${JAMF_LOOKUP_STATUS}" == "notfound" ]]
    then
        stop_progress
        show_message "Serial **${SERIAL}** was **not found** in Jamf Pro's Automated Device Enrollment.\n\nThe device is not synced from Apple Business Manager into any ADE instance in this Jamf Pro." \
            "questionmark.circle.fill" "orange" "${appSizeLarge}"
        log_info "Serial ${SERIAL} not found in Jamf ADE"
        exit 0
    fi

    # Found — parse the Jamf device-enrollment record
    j_serial=$("${JQ}" -r '.serialNumber // empty' <<< "${JAMF_DEVICE_JSON}")
    j_model=$("${JQ}" -r '.model // "Unknown"' <<< "${JAMF_DEVICE_JSON}")
    j_desc=$("${JQ}" -r '.description // ""' <<< "${JAMF_DEVICE_JSON}")
    j_profile=$("${JQ}" -r '.profileStatus // "UNKNOWN"' <<< "${JAMF_DEVICE_JSON}")
    j_sync=$("${JQ}" -r '.syncState.syncStatus // "—"' <<< "${JAMF_DEVICE_JSON}")
    j_prestage=$("${JQ}" -r '.prestageId // empty' <<< "${JAMF_DEVICE_JSON}")
    j_assigned=$(format_date "$("${JQ}" -r '.deviceAssignedDate // empty' <<< "${JAMF_DEVICE_JSON}")")
    j_profassign=$(format_date "$("${JQ}" -r '.profileAssignTime // empty' <<< "${JAMF_DEVICE_JSON}")")

    # Hardware icon — infer the family from the model string
    case "$(printf '%s' "${j_model}" | "${TR}" '[:upper:]' '[:lower:]')" in
        *iphone*)
            j_family="iPhone"
            ;;
        *ipad*)
            j_family="iPad"
            ;;
        *watch*)
            j_family="Watch"
            ;;
        *"apple tv"*|*appletv*)
            j_family="AppleTV"
            ;;
        *vision*)
            j_family="Vision"
            ;;
        *)
            j_family="Mac"
            ;;
    esac
    DIALOG_ICON=$(device_icon_value "${j_family}" "${j_model}")

    log_info "Found ${j_serial} in ADE instance '${JAMF_INSTANCE_NAME}' profileStatus=${j_profile} sync=${j_sync}"

    jamf_msg=$(printf '## Device Info\n\n- **Enrolled in ADE (Jamf):** Yes\n- **Serial:** %s\n- **Model:** %s\n- **Description:** %s\n- **ADE instance:** %s\n- **Profile status:** %s\n- **Sync status:** %s\n- **Assigned to org:** %s\n- **Profile assigned:** %s\n- **PreStage ID:** %s' \
        "${j_serial}" "${j_model}" "${j_desc:-—}" "${JAMF_INSTANCE_NAME:-—}" "${j_profile}" "${j_sync}" "${j_assigned:-—}" "${j_profassign:-—}" "${j_prestage:-—}")

    stop_progress
    show_message "${jamf_msg}" "checkmark.seal.fill" "green" "${appSizeLarge}"
    log_info "${SCRIPT_NAME} completed successfully"
    exit 0
fi

# ── Step 2: authenticate + query ABM (cancellable spinner with live status) ──
start_progress "Authenticating to Apple Business Manager…"

if ! get_access_token
then
    stop_progress
    show_message "Could not authenticate to Apple Business Manager.\n\n${AUTH_ERROR}" \
        "xmark.octagon.fill" "red" "${appSizeLarge}"
    log_error "Auth failed: ${AUTH_ERROR}"
    exit 1
fi
log_info "Obtained ABM access token"
abort_if_cancelled

update_progress "Loading MDM servers…"
if ! fetch_all_mdm_servers
then
    stop_progress
    show_message "Authenticated, but could not list MDM servers.\n\n${MDM_FETCH_ERROR}" \
        "xmark.octagon.fill" "red" "${appSizeLarge}"
    log_error "MDM server fetch failed: ${MDM_FETCH_ERROR}"
    exit 1
fi
abort_if_cancelled

update_progress "Searching Apple Business Manager…"
find_device_by_serial "${SERIAL}"

# ── Step 3: report results / branch ──────────────────────────────────────────
if [[ "${DEVICE_LOOKUP_STATUS}" == "error" ]]
then
    stop_progress
    show_message "Error while searching Apple Business Manager.\n\n${DEVICE_LOOKUP_DETAIL}" \
        "xmark.octagon.fill" "red" "${appSizeLarge}"
    log_error "Device lookup error: ${DEVICE_LOOKUP_DETAIL}"
    exit 1
fi

if [[ "${DEVICE_LOOKUP_STATUS}" == "notfound" ]]
then
    stop_progress
    show_message "Serial **${SERIAL}** was **not found** in Apple Business Manager.\n\nThis device is **not enrolled in ABM** (it was not purchased through a linked Apple/Reseller account, or has not been added manually)." \
        "questionmark.circle.fill" "orange" "${appSizeLarge}"
    log_info "Serial ${SERIAL} not found in ABM"
    exit 0
fi

# Found — parse device facts
DEVICE_ID=$("${JQ}" -r '.id // empty' <<< "${DEVICE_JSON}")
DEVICE_MODEL=$("${JQ}" -r '.attributes.deviceModel // .attributes.productType // "Unknown"' <<< "${DEVICE_JSON}")
DEVICE_FAMILY=$("${JQ}" -r '.attributes.productFamily // ""' <<< "${DEVICE_JSON}")
DEVICE_STATUS=$("${JQ}" -r '.attributes.status // "UNKNOWN"' <<< "${DEVICE_JSON}")
DEVICE_ADDED_RAW=$("${JQ}" -r '.attributes.addedToOrgDateTime // empty' <<< "${DEVICE_JSON}")
DEVICE_ADDED_DISPLAY=$(format_date "${DEVICE_ADDED_RAW}")
if [[ -z "${DEVICE_ADDED_DISPLAY}" ]]
then
    DEVICE_ADDED_DISPLAY="Unknown"
fi

DEVICE_ICON=$(device_icon_value "${DEVICE_FAMILY}" "${DEVICE_MODEL}")
DIALOG_ICON="${DEVICE_ICON}"   # device found → all subsequent dialogs use the device icon

log_info "Found device id=${DEVICE_ID} model='${DEVICE_MODEL}' status=${DEVICE_STATUS} added=${DEVICE_ADDED_RAW} icon=${DEVICE_ICON}"

# Determine current MDM assignment (capture the server id — needed to unassign)
CURRENT_MDM_NAME="— Not assigned —"
CURRENT_MDM_ID=""
if [[ "${DEVICE_STATUS}" == "ASSIGNED" ]]
then
    assigned_id=$(get_assigned_server_id "${DEVICE_ID}")
    if [[ -n "${assigned_id}" ]]
    then
        CURRENT_MDM_ID="${assigned_id}"
        resolved=$(resolve_server_name "${assigned_id}")
        if [[ -n "${resolved}" ]]
        then
            CURRENT_MDM_NAME="${resolved}"
        else
            CURRENT_MDM_NAME="(server id ${assigned_id})"
        fi
    fi
fi

# AppleCare coverage (best-effort; spinner still showing)
get_applecare_coverage "${DEVICE_ID}"
applecare_md=$(build_applecare_md)

stop_progress

# Count available MDM servers (used by admin mode)
SERVER_COUNT=$("${JQ}" -r -s 'length' "${MDM_SERVERS_FILE}")

# Shared "Device Info" block — header + one field per line (markdown list so each
# item renders on its own line; a single \n collapses in swiftDialog markdown).
device_info=$(printf '## Device Info\n\n- **Enrolled in ABM:** Yes\n- **Serial:** %s\n- **Model:** %s %s\n- **Date added:** %s\n- **Status:** %s\n- **Current MDM:** %s\n%s' \
    "${SERIAL}" "${DEVICE_FAMILY}" "${DEVICE_MODEL}" "${DEVICE_ADDED_DISPLAY}" "${DEVICE_STATUS}" "${CURRENT_MDM_NAME}" "${applecare_md}")

# Action selection — populated by the mode-specific dialog below
ACTIVITY_TYPE=""
TARGET_MDM_ID=""
TARGET_MDM_NAME=""

if [[ "${MODE}" == "support" ]]
then
    # ── Support mode: assign ONLY to the fixed SUPPORT_MODE_MDM_NAME server ──
    TARGET_MDM_ID=$(resolve_server_id "${SUPPORT_MODE_MDM_NAME}")
    if [[ -z "${TARGET_MDM_ID}" ]]
    then
        show_message "$(printf '%s\n\nThe required MDM server **%s** was not found in Apple Business Manager.\n\nContact your MDM administrator.' "${device_info}" "${SUPPORT_MODE_MDM_NAME}")" \
            "xmark.octagon.fill" "red" "${appSizeLarge}"
        log_error "Support-mode target server '${SUPPORT_MODE_MDM_NAME}' not found in tenant"
        exit 1
    fi

    support_msg=$(printf '%s\n\nClick **Assign** to assign this device to **%s**.' "${device_info}" "${SUPPORT_MODE_MDM_NAME_FRIENDLY}")
    if run_dialog \
        --height "${appSizeLarge}" \
        --icon "${DEVICE_ICON}" \
        --overlayicon "SF=checkmark.seal.fill,colour=green" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${support_msg}" \
        --button1text "Assign to ${SUPPORT_MODE_MDM_NAME_FRIENDLY}" \
        --button2text "Close" \
        --infotext "v${SCRIPT_VERSION}" \
        --ontop --moveable
    then
        ACTIVITY_TYPE="ASSIGN_DEVICES"
        TARGET_MDM_NAME="${SUPPORT_MODE_MDM_NAME}"
    else
        log_info "Support user closed without assigning"
        exit 0
    fi
else
    # ── Admin mode: choose action (Assign/Unassign) + MDM server ─────────────
    if [[ "${SERVER_COUNT}" -eq 0 ]]
    then
        show_message "$(printf '%s\n\nNo MDM servers are defined in this ABM tenant, so assignment is not possible.' "${device_info}")" \
            "info.circle.fill" "blue" "${appSizeLarge}"
        log_warn "No MDM servers available to assign to"
        exit 0
    fi

    SELECT_VALUES=$(build_select_values)
    admin_msg=$(printf '%s\n\nChoose an **action** and **MDM server**, then click **Continue**.\n\n_MDM Server is used for Assign; it is ignored for Unassign._' "${device_info}")

    results_out=$(create_temp_file "results")
    if run_dialog \
        --height "${appSizeLarge}" \
        --icon "${DEVICE_ICON}" \
        --overlayicon "SF=slider.horizontal.3,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${admin_msg}" \
        --selecttitle "Action,required,name=action" \
        --selectvalues "Assign,Unassign" \
        --selecttitle "MDM Server,required,name=mdmserver" \
        --selectvalues "${SELECT_VALUES}" \
        --button1text "Continue" \
        --button2text "Close" \
        --infotext "v${SCRIPT_VERSION}" \
        --ontop --moveable \
        --json \
        > "${results_out}"
    then
        sel_action=$("${JQ}" -r '.action.selectedValue // empty' "${results_out}")
        sel_mdm=$("${JQ}" -r '.mdmserver.selectedValue // empty' "${results_out}")
    else
        log_info "Admin closed without acting"
        exit 0
    fi

    case "${sel_action}" in
        Assign)
            if [[ -z "${sel_mdm}" ]]
            then
                show_message "No MDM server was selected — nothing was changed." "exclamationmark.triangle.fill" "orange" "${appSizeSmall}"
                exit 0
            fi
            TARGET_MDM_ID=$(resolve_server_id "${sel_mdm}")
            if [[ -z "${TARGET_MDM_ID}" ]]
            then
                show_message "Could not resolve the ID for MDM server '${sel_mdm}'." "xmark.octagon.fill" "red" "${appSizeMedium}"
                log_error "Failed to resolve MDM id for '${sel_mdm}'"
                exit 1
            fi
            ACTIVITY_TYPE="ASSIGN_DEVICES"
            TARGET_MDM_NAME="${sel_mdm}"
            ;;
        Unassign)
            if [[ "${DEVICE_STATUS}" != "ASSIGNED" ]]
            then
                show_message "Device **${SERIAL}** is already **unassigned** — nothing to do." "info.circle.fill" "blue" "${appSizeMedium}"
                log_info "Unassign requested but ${SERIAL} is already unassigned"
                exit 0
            fi
            if ! run_dialog \
                --height "${appSizeMedium}" \
                --icon "${DIALOG_ICON}" \
                --overlayicon "SF=exclamationmark.triangle.fill,colour=orange" \
                --bannerimage "${brandingBanner}" \
                --bannertext "${appName}" \
                --message "$(printf 'Unassign **%s** from **%s**?\n\nThe device will no longer be assigned to any MDM in Apple Business Manager and will drop out of Automated Device Enrollment until reassigned.\n\nThis is reversible — you can reassign it later.' "${SERIAL}" "${CURRENT_MDM_NAME}")" \
                --button1text "Unassign" \
                --button2text "Cancel" \
                --infotext "v${SCRIPT_VERSION}" \
                --ontop --moveable
            then
                log_info "Admin cancelled unassign for ${SERIAL}"
                exit 0
            fi
            ACTIVITY_TYPE="UNASSIGN_DEVICES"
            TARGET_MDM_ID="${CURRENT_MDM_ID}"   # ABM requires the current server on unassign
            TARGET_MDM_NAME="${CURRENT_MDM_NAME}"
            ;;
        *)
            show_message "No action was selected — nothing was changed." "exclamationmark.triangle.fill" "orange" "${appSizeSmall}"
            exit 0
            ;;
    esac
fi

log_info "Mode=${MODE} action=${ACTIVITY_TYPE} device=${DEVICE_ID} target='${TARGET_MDM_NAME}'"

# ── Submit the activity + poll for completion ────────────────────────────────
if [[ "${ACTIVITY_TYPE}" == "ASSIGN_DEVICES" ]]
then
    start_progress "Assigning ${SERIAL} to ${TARGET_MDM_NAME}…"
else
    start_progress "Unassigning ${SERIAL}…"
fi

if ! submit_device_activity "${ACTIVITY_TYPE}" "${DEVICE_ID}" "${TARGET_MDM_ID}"
then
    stop_progress
    show_message "Request failed.\n\n${ASSIGN_ERROR}" "xmark.octagon.fill" "red" "${appSizeLarge}"
    log_error "Activity submission failed: ${ASSIGN_ERROR}"
    exit 1
fi

poll_activity "${ACTIVITY_ID}"
stop_progress

# ── Report outcome ───────────────────────────────────────────────────────────
if [[ "${ACTIVITY_TYPE}" == "ASSIGN_DEVICES" ]]
then
    action_noun="Assignment"
    success_msg=$(printf '✅ **%s** is now assigned to **%s**.\n\nIt will sync into that MDM for Automated Device Enrollment shortly.' "${SERIAL}" "${TARGET_MDM_NAME}")
else
    action_noun="Unassignment"
    success_msg=$(printf '✅ **%s** has been **unassigned** from its MDM in Apple Business Manager.' "${SERIAL}")
fi

case "${ACTIVITY_STATUS}" in
    COMPLETED)
        if [[ "${ACTIVITY_SUBSTATUS}" == "COMPLETED_WITH_SUCCESS" ]]
        then
            show_message "${success_msg}" "checkmark.seal.fill" "green" "${appSizeLarge}"
            log_info "${action_noun} COMPLETED_WITH_SUCCESS for ${SERIAL}"
        else
            show_message "${action_noun} completed with issues.\n\nStatus: ${ACTIVITY_STATUS}\nDetail: ${ACTIVITY_SUBSTATUS}\n\nVerify the device in Apple Business Manager." \
                "exclamationmark.triangle.fill" "orange" "${appSizeLarge}"
            log_warn "${action_noun} ${ACTIVITY_STATUS}/${ACTIVITY_SUBSTATUS} for ${SERIAL}"
        fi
        ;;
    FAILED|STOPPED)
        show_message "${action_noun} did not succeed.\n\nStatus: ${ACTIVITY_STATUS}\nDetail: ${ACTIVITY_SUBSTATUS}\n\nCheck Apple Business Manager and try again." \
            "xmark.octagon.fill" "red" "${appSizeLarge}"
        log_error "${action_noun} ${ACTIVITY_STATUS}/${ACTIVITY_SUBSTATUS} for ${SERIAL}"
        ;;
    *)
        show_message "${action_noun} was **submitted** (activity ${ACTIVITY_ID}) and is still processing.\n\nLast status: ${ACTIVITY_STATUS:-IN_PROGRESS}\n\nIt should finish shortly — re-run the lookup to confirm." \
            "clock.fill" "blue" "${appSizeLarge}"
        log_info "${action_noun} still processing for ${SERIAL} (status=${ACTIVITY_STATUS:-IN_PROGRESS})"
        ;;
esac

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

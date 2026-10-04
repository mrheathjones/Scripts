#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Erase-And-Delete-Devices.sh
# Author: Heath Jones
# Date: 07-01-2026
# Modified: 07-01-2026
# Purpose: Admin tool — pull managed computers from the Jamf Pro API, let an
#          admin pick one or more from a searchable swiftDialog list, queue an
#          EraseDevice MDM command to each, and (after acknowledgment) delete
#          the Jamf computer record(s).
# Version: 1.0 - Initial Script
# Version: 1.1 - Org identity vars; searchable/multiselect native picker
# Version: 1.2 - Confirmation shows live per-device inventory detail
# Version: 1.3 - Human-readable local timestamps; single-device confirmation/
#                summary uses the model's photorealistic hardware icon
# Version: 1.4 - MacBook Neo: resolve the color-matched hardware icon using the
#                enclosure color from Jamf ADE sync (device-enrollments)
# Version: 1.5 - Color shown as text in the detail block; background "working"
#                progress spinner during auth/inventory + detail load phases
# Version: 1.6 - Progress spinner during erase→ack→delete; ack poll now tolerates
#                array/object shapes + Title-case status (Acknowledged); adaptive
#                token skew stops re-auth spam on very short-lived tokens
# Version: 1.7 - Fix status field (commandState, not status) so delete fires; new
#                default 'after-sent' delete mode = verify command issued, then
#                delete (fast) instead of waiting for device acknowledgment
# Version: 1.8 - Optional Microsoft Entra cleanup (param 11): after erase, delete
#                the device object(s) from Entra by displayName via Graph so the
#                Mac can re-register cleanly with PSSO / Company Portal
# Version: 1.9 - Entra Graph auth supports certificate (PS256 client assertion)
#                in addition to client secret; cert is auto-preferred when the
#                entra-graph.pem (cert + key) is present
# Version: 1.10 - Cert assertion fails clearly if the PEM can't be read/parsed
#                 (instead of a misleading sign error)
# Version: 1.11 - Param 11 is now an Entra MODE (off|delete|provision). "provision"
#                 self-creates credentials.plist + PEM from embedded content if
#                 missing. Confirmation dialog states the Entra record is deleted too.
# Version: 1.12 - Param 11 simplified to a "Cleanup Entra" on/off toggle: enabled
#                 = create creds if missing + delete from Entra; disabled = ignore
#                 the PEM/plist/cleanup entirely.
# Version: 1.13 - Fix: provisioned credentials.plist is now built with PlistBuddy
#                 so the app path's '&' is XML-escaped (a heredoc wrote a literal
#                 '&', corrupting the plist so no keys could be read)
# Version: 1.13-SANITIZED - Handoff copy for use in a DIFFERENT organization.
#                 The live Entra private key and tenant/client IDs have been
#                 STRIPPED and replaced with REPLACE_ME placeholders; org identity
#                 and branding vars are placeholders too. Search this file for
#                 "REPLACE_ME" and fill in every hit before use. See the
#                 "SETUP — READ BEFORE USE" block below for the Jamf/Entra
#                 permissions required.
# Version: 1.14-SANITIZED - Decouple Entra auth method from provisioning. New
#                 plist key entra_auth_method (cert|secret|auto, default auto)
#                 drives auth by the RESOLVED method, not "a cert path happens to
#                 be set". provision_credentials() split into plist-skeleton +
#                 opt-in PEM (PEM written only for method 'cert', never a
#                 placeholder), so a secret-only setup is never forced onto the
#                 cert path. Added an Entra preflight that fails fast if the
#                 chosen method's creds are missing/unparseable, skipping cleanup
#                 instead of erroring mid-run. (SECRET auth needs NO PEM at all —
#                 set entra_auth_method=secret + entra_client_secret in the plist.)
# Version: 1.15-SANITIZED - provision_entra_plist() only writes entra_cert_path
#                 for method cert/auto (secret-only skeleton omits it); the
#                 SC2230 lint directive moved to its own line (clears SC1125).
# Version: 1.16-SANITIZED - Renamed to the Title-Case-Hyphenated filename
#                 convention; added a Requirements section (placed after the
#                 version history), enforced by the existing require_root /
#                 validate_environment / get_current_user preflight checks.
#                 swiftDialog called out as the key REQUIRED dependency. Local
#                 brandingBanner/appIcon paths replaced with CHANGE_ME
#                 placeholder subpaths (online fallbacks retained).
#
# Requirements:
#   - Run as root (Jamf policy) on a Jamf-enrolled Mac — reads jss_url from the
#     local com.jamfsoftware.jamf plist.
#   - A logged-in GUI (console) user — swiftDialog renders in their session.
#   - **swiftDialog REQUIRED** — installed at /usr/local/bin/dialog. The ENTIRE
#     user interface (device picker, erase confirmation, progress, summary) is
#     swiftDialog; validate_environment aborts the run if it is missing.
#     Download: https://github.com/swiftDialog/swiftDialog
#   - jq installed (not stock on macOS before 15).
#   - Jamf API client (params 4/5, or credentials.plist) whose API role grants:
#     Read Computers, Delete Computers, Send Computer Remote Wipe Command,
#     View MDM Command Information, Read Automated Device Enrollment.
#   - Optional Entra cleanup (param 11): an Entra app with Microsoft Graph
#     Device.ReadWrite.All AND the "Cloud Device Administrator" role, using
#     certificate or client-secret auth (see entra_auth_method).
#   - See the SETUP block below for full per-field setup and placeholders.
#
######################################################################
#
# ┌───────────────────────────────────────────────────────────────────────────┐
# │ SETUP — READ BEFORE USE (this is a sanitized copy for another org)         │
# ├───────────────────────────────────────────────────────────────────────────┤
# │ 1. JAMF PRO                                                                 │
# │    • Create an API Client (OAuth client credentials) and pass its          │
# │      client_id / client_secret as script params 4 and 5 (or drop them in   │
# │      the fallback credentials.plist — see CONFIG_PLIST below).              │
# │    • The API Role needs these privileges:                                  │
# │        - Read Computers                     (inventory + detail)           │
# │        - Delete Computers                   (remove the record)            │
# │        - Send Computer Remote Wipe Command  (EraseDevice)                  │
# │        - View MDM Command Information        (verify issued / poll ack)    │
# │        - Read Automated Device Enrollment    (ADE enclosure-color icons;   │
# │          optional — script degrades gracefully to a generic icon if denied)│
# │    • The Mac running this must be Jamf-enrolled (reads jss_url locally),    │
# │      run as root, and have jq, curl, and swiftDialog installed.            │
# │                                                                            │
# │ 2. MICROSOFT ENTRA (only if you enable "Cleanup Entra", param 11)          │
# │    • Register an app in YOUR tenant → gives tenant_id + client_id.         │
# │    • Auth: set entra_auth_method in credentials.plist to cert | secret |   │
# │      auto (default auto). Pick ONE credential to match:                     │
# │        - SECRET (simplest): entra_auth_method=secret + entra_client_secret  │
# │          in the plist. NO PEM, no cert, nothing to embed in this script.    │
# │        - CERT: entra_auth_method=cert + a PEM (cert+key) at entra_cert_path │
# │          (default <APP_DIR>/entra-graph.pem), PS256 client assertion.       │
# │        - AUTO: uses a valid cert if present, else the secret.               │
# │    • Graph application permission: Device.ReadWrite.All (admin consented). │
# │    • Assign the app's service principal the "Cloud Device Administrator"   │
# │      Entra role — WITHOUT it, device DELETE returns 403.                   │
# │    • Self-provisioning writes the plist skeleton for ANY method; it only    │
# │      writes the embedded PEM when entra_auth_method is 'cert' AND you have  │
# │      pasted a real cert+key into the PEM_EOF heredoc (+ filled              │
# │      PROVISION_ENTRA_* below). Secret-only setups embed nothing here.       │
# │                                                                            │
# │ 3. PLACEHOLDERS — grep for REPLACE_ME and set every one before running.    │
# └───────────────────────────────────────────────────────────────────────────┘
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
# shellcheck disable=SC2230
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY: human-readable display name; MAY contain spaces. Used for
#   user-facing text and swiftDialog banners.
# ORG_NAME: path-safe — ORG_NAME_FRIENDLY with spaces removed — for filesystem
#   paths like /Library/Application Support/${ORG_NAME}/ and /Library/Logs/${ORG_NAME}/.
# ORG_PLIST_DOMAIN: reverse-DNS — used for LOG_LABEL, LaunchDaemon/LaunchAgent
#   labels, and defaults preference domains.
readonly ORG_NAME_FRIENDLY="REPLACE_ME Org Name"      # e.g. "Acme Corp" (may contain spaces)
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"          # path-safe (spaces stripped) — leave as-is
readonly ORG_PLIST_DOMAIN="com.replaceme"             # reverse-DNS, e.g. "com.acme"

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.16-SANITIZED"
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

# ── Task-specific binary paths ───────────────────────────────────────────────
readonly CURL=$(which curl)
readonly JQ=$(which jq)
readonly DEFAULTS=$(which defaults)
readonly SED=$(which sed)
readonly SCUTIL=$(which scutil)
readonly MV=$(which mv)
readonly CAT=$(which cat)
readonly SLEEP=$(which sleep)
readonly TR=$(which tr)
readonly CHMOD=$(which chmod)
readonly CHOWN=$(which chown)
readonly MKDIR=$(which mkdir)
readonly PGREP=$(which pgrep)
readonly PKILL=$(which pkill)
readonly OPENSSL=$(which openssl)
readonly UUIDGEN=$(which uuidgen)
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"

# ── App / Org Identity (swiftDialog branding) ────────────────────────────────
APP_NAME="Erase & Delete Devices"
DIALOG_BIN="/usr/local/bin/dialog"
APP_DIR="/Library/Application Support/${ORG_NAME}/${APP_NAME}"

# ── swiftDialog: Branding Banner ─────────────────────────────────────────────
# CHANGE_ME: local path to YOUR banner image. The placeholder subpath below does
# not exist, so the script falls back to the generic online image. Point this at
# your own asset (the ${ORG_NAME} segment is filled from the org identity vars).
brandingBanner="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/banner.png"
if [[ ! -f "${brandingBanner}" ]]
then
    # online branding banner url if local file doesn't exist (generic public
    # stock image — not org-specific)
    brandingBanner="https://img.freepik.com/premium-vector/abstract-techno-background-with-flowing-cyber-particles_1048-15244.jpg" # sanitize:ignore
fi

# ── swiftDialog: App Icon ────────────────────────────────────────────────────
# CHANGE_ME: local path to YOUR app icon. The placeholder subpath below does not
# exist, so the script falls back to the generic online icon. Point this at your
# own asset (or set it to your Jamf icon-repo hash URL).
appIcon="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/icon.png"
if [[ ! -f "${appIcon}" ]]
then
    # app icon url if local file doesn't exist (generic public placeholder)
    appIcon="https://raw.githubusercontent.com/github/explore/main/topics/apple/apple.png"
fi
appIconSize=125
# Larger icon size (px) for the photorealistic device image on the confirmation
# and summary dialogs (swiftDialog default is 150). Bump this to taste.
deviceIconSize=240

# ── Dialog Size Constants ────────────────────────────────────────────────────
appSizeXSmall=250
appSizeSmall=500
appSizeMedium=650
appSizeLarge=800
appSizeXLarge=1000

# ── Dialog Title (banner text — used on every dialog) ────────────────────────
appName="${ORG_NAME_FRIENDLY} - ${APP_NAME}"

# Photorealistic hardware icons shipped with macOS (used on the confirmation +
# summary dialogs in place of the brand icon once a single device is resolved).
readonly DEVICE_ICON_DIR="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"
# Color-specific model icons (e.g. MacBook Neo) live in CoreTypes SUB-bundles.
# The sub-bundle number (CoreTypes-00NN) shifts between macOS releases, so we
# glob under this Library dir rather than hardcoding it — see resolve_neo_icon().
readonly DEVICE_ICON_LIB="/System/Library/CoreServices/CoreTypes.bundle/Contents/Library"

# ── Jamf Pro URL (read from the local management plist, trailing slash stripped)
JAMF_URL=$("${DEFAULTS}" read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null | "${SED}" -e 's/\/$//') || JAMF_URL=""

# ── Jamf Pro Script Parameters ───────────────────────────────────────────────
# $1-$3 are reserved by Jamf (mount point, computer name, username)
# $4/$5 = your Jamf API client_id / client_secret (see SETUP block at top)
readonly PARAM_CLIENT_ID="${4:-}"
readonly PARAM_CLIENT_SECRET="${5:-}"
readonly PARAM_MULTI_SELECT="${6:-false}" # "true" allows selecting multiple devices
readonly PARAM_ERASE_PIN="${7:-}"        # 6-digit PIN — REQUIRED for Intel T2 Macs, ignored on Apple Silicon
# Delete mode (param 8):
#   after-sent  (default) — verify the erase command was ISSUED (accepted + sent
#                 to the device, commandState not errored), then delete. Fast.
#   after-ack   — wait until the device ACKNOWLEDGES the erase, then delete.
#                 Safest (proves the device received it) but can wait a long time
#                 and may never ack within the window (device wipes and is gone).
#   immediate   — delete right after issuing, no verification.
#   never       — erase only; leave the Jamf record.
readonly PARAM_DELETE_MODE="${8:-after-sent}"
readonly PARAM_DRY_RUN="${9:-true}"     # "true" = show/log actions but issue NOTHING
# Optional: scope the ADE color lookup to a single device-enrollment instance id.
# Leave blank to enumerate ALL instances via GET /api/v1/device-enrollments.
readonly PARAM_ADE_INSTANCE_ID="${10:-}"
# Cleanup Entra (param 11) — a simple on/off toggle.
#   ENABLED  (true / enable / enabled / on / yes / 1): ensure the
#            credentials.plist exists (created from the embedded content below if
#            missing); the embedded PEM is written ONLY when entra_auth_method is
#            'cert'. Then delete the erased device's Entra object(s) so it can
#            re-register with PSSO / Company Portal.
#   DISABLED (anything else, default): ignore the PEM, plist, and all Entra
#            logic entirely.
readonly PARAM_ENTRA_CLEANUP="${11:-false}"
_entra_cleanup_lc=$(printf '%s' "${PARAM_ENTRA_CLEANUP}" | "${TR}" '[:upper:]' '[:lower:]' | "${TR}" -d '[:space:]')
case "${_entra_cleanup_lc}" in
    true|enable|enabled|on|yes|1)
        readonly PARAM_DELETE_FROM_ENTRA="true"
        readonly PARAM_PROVISION_CREDS="true"
        ;;
    *)
        readonly PARAM_DELETE_FROM_ENTRA="false"
        readonly PARAM_PROVISION_CREDS="false"
        ;;
esac

# ── Credentials fallback (root-only plist) ───────────────────────────────────
# Jamf keys:  client_id, client_secret  (used when params 4/5 are blank)
# Entra keys: entra_tenant_id, entra_client_id  (required for Entra cleanup)
#   entra_auth_method   — cert | secret | auto  (default: auto). Selects HOW the
#                         script authenticates to Microsoft Graph, independently
#                         of provisioning:
#                           cert   — require a valid PEM at entra_cert_path;
#                                    skip cleanly if absent/unparseable.
#                           secret — require entra_client_secret; a stray PEM on
#                                    disk is ignored.
#                           auto   — prefer a valid cert, else fall back to a
#                                    secret, else skip.
#   entra_cert_path     — path to a PEM holding the certificate + private key
#                         (default: <APP_DIR>/entra-graph.pem). Client-assertion.
#   entra_client_secret — client-secret auth (used for method 'secret', or 'auto'
#                         when no valid cert is present).
readonly CONFIG_PLIST="${APP_DIR}/credentials.plist"

# ══════════════════════════════════════════════════════════════════════════════
# EMBEDDED PROVISIONING CONTENT (used ONLY when param 11 == "provision")
# ══════════════════════════════════════════════════════════════════════════════
# ⚠️  SECURITY: the PEM heredoc inside provision_credentials() embeds a LIVE Entra
#     private key. Anyone who can read THIS SCRIPT can authenticate as that app.
#       • If loaded as a Jamf Script payload, anyone with "Read Scripts" can
#         extract the key. Prefer deploying the PEM via a package and leaving
#         param 11 at "delete", OR accept this exposure knowingly (as with ABM).
#       • Rotate the key in Entra if this file is ever exposed.
# The Entra tenant/client IDs are identifiers (low sensitivity). Fill these plus
# the PEM block in provision_credentials() below.
readonly PROVISION_ENTRA_TENANT_ID="REPLACE_ME-tenant-id"   # your Entra tenant (directory) ID
readonly PROVISION_ENTRA_CLIENT_ID="REPLACE_ME-client-id"   # your app registration (client) ID
# Auth method seeded into a freshly-provisioned credentials.plist. ONLY "cert"
# causes the embedded PEM to be written; "auto"/"secret" never force a PEM (for
# secret auth, add entra_client_secret to the plist yourself — no PEM needed).
readonly PROVISION_ENTRA_AUTH_METHOD="auto"

# ── Behaviour tuning ─────────────────────────────────────────────────────────
readonly INVENTORY_PAGE_SIZE=200         # computers-inventory page size
readonly ACK_TIMEOUT_SECONDS=180         # how long to wait for erase acknowledgment (after-ack mode)
readonly ACK_POLL_INTERVAL=15            # seconds between status polls
readonly TOKEN_SKEW_SECONDS=60           # refresh token this many seconds before real expiry

# ── Mutable runtime state (NOT readonly) ─────────────────────────────────────
ACCESS_TOKEN=""
TOKEN_EXPIRY_EPOCH=0
FORCE_TOKEN_REFRESH="false"
CLIENT_ID=""
CLIENT_SECRET=""
DIALOG_ICON="${appIcon}"   # brand icon until one device is resolved; then its hardware photo
ADE_COLOR_MAP=""           # NDJSON file: {serial,color,model} from ADE sync (built lazily)
ADE_MAP_BUILT="false"      # guard so the ADE map is fetched at most once per run
PROGRESS_CMD_FILE=""       # swiftDialog command file for the background progress dialog
PROGRESS_PID=""            # PID of the backgrounded progress dialog
ENTRA_TENANT_ID=""         # Microsoft Entra tenant id (from credentials.plist)
ENTRA_CLIENT_ID=""         # Entra app registration client id
ENTRA_CLIENT_SECRET=""     # Entra app client secret (fallback auth if no cert)
ENTRA_CERT_PATH=""         # PEM (cert + private key) for client-assertion auth (preferred)
ENTRA_AUTH_METHOD=""       # RESOLVED Entra auth method: "cert" | "secret" | "" (skip)
ENTRA_ACCESS_TOKEN=""      # Microsoft Graph bearer token (separate from the Jamf token)
ENTRA_TOKEN_EXPIRY_EPOCH=0

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
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}" >&2
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}" >&2
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}" >&2
}

log_debug() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}" >&2
}

# ── Temp file helper (tracked for cleanup) ───────────────────────────────────
create_temp_file() {
    local label="${1:-tmp}"
    local f
    f=$("${MKTEMP}" "/private/tmp/${LOG_LABEL}.${label}.${TIMESTAMP}.XXXXXX")
    TEMP_FILES+=("${f}")
    printf '%s' "${f}"
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
cleanup() {
    local exit_code=$?
    # Close any lingering background progress dialog first (quit, then force-kill
    # it by its unique command-file path) so it never outlives the script.
    if [[ -n "${PROGRESS_CMD_FILE}" && -f "${PROGRESS_CMD_FILE}" ]]
    then
        printf 'quit:\n' >> "${PROGRESS_CMD_FILE}" 2>/dev/null || true
        "${PKILL}" -f "${PROGRESS_CMD_FILE}" 2>/dev/null || true
    fi
    # Always try to invalidate the token so we don't leak DB connections.
    if [[ -n "${ACCESS_TOKEN}" ]]
    then
        "${CURL}" --silent --show-error --location --max-time 20 \
            -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "${JAMF_URL}/api/v1/auth/invalidate-token" >/dev/null 2>&1 || true
        log_info "Access token invalidated"
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

# ── Console user / swiftDialog context helpers ───────────────────────────────
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
    local user="$1"
    "${ID}" -u "${user}"
}

# Every swiftDialog call goes through this wrapper (runs in the user's GUI session)
run_dialog() {
    /bin/launchctl asuser "${CONSOLE_UID}" /usr/bin/sudo -u "${CURRENT_USER}" \
        "${DIALOG_BIN}" "$@" 2>/dev/null
}

# ── Background "working" progress dialog ─────────────────────────────────────
# Shown during slow, UI-less API phases (auth + inventory load, and the
# post-selection detail/ADE fetch) so the user sees the script is working.
# Uses an indeterminate (animated) bar — plain --progress with no value — driven
# by a world-readable command file the console-user dialog can read. Killed with
# stop_progress() before any other dialog appears.
start_progress() {
    local text="${1:-Working…}"
    PROGRESS_CMD_FILE=$("${MKTEMP}" "/private/tmp/${LOG_LABEL}.cmd.${TIMESTAMP}.XXXXXX")
    "${CHMOD}" 644 "${PROGRESS_CMD_FILE}"
    TEMP_FILES+=("${PROGRESS_CMD_FILE}")
    run_dialog \
        --height "${appSizeSmall}" \
        --icon "${DIALOG_ICON}" \
        --overlayicon "SF=arrow.triangle.2.circlepath,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${text}" \
        --progress \
        --progresstext "${text}" \
        --button1text "Please wait…" \
        --button1disabled \
        --ontop --moveable \
        --commandfile "${PROGRESS_CMD_FILE}" &
    PROGRESS_PID=$!
}

# Push a live status line into the progress dialog (keeps the bar indeterminate —
# we only ever send progresstext, never a numeric progress value).
update_progress() {
    local text="$1"
    if [[ -n "${PROGRESS_CMD_FILE}" && -f "${PROGRESS_CMD_FILE}" ]]
    then
        printf 'message: %s\nprogresstext: %s\n' "${text}" "${text}" >> "${PROGRESS_CMD_FILE}" 2>/dev/null || true
    fi
}

# Close the progress dialog: ask it to quit, wait briefly, force-kill if it
# lingers. Idempotent — safe to call when no progress dialog is running.
stop_progress() {
    if [[ -z "${PROGRESS_CMD_FILE}" ]]
    then
        return 0
    fi
    if [[ -f "${PROGRESS_CMD_FILE}" ]]
    then
        printf 'quit:\n' >> "${PROGRESS_CMD_FILE}" 2>/dev/null || true
    fi
    local n=0
    while [[ ${n} -lt 10 ]]
    do
        if ! "${PGREP}" -f "${PROGRESS_CMD_FILE}" >/dev/null 2>&1
        then
            break
        fi
        "${SLEEP}" 0.3
        n=$(( n + 1 ))
    done
    if "${PGREP}" -f "${PROGRESS_CMD_FILE}" >/dev/null 2>&1
    then
        "${PKILL}" -f "${PROGRESS_CMD_FILE}" 2>/dev/null || true
    fi
    if [[ -n "${PROGRESS_PID}" ]]
    then
        wait "${PROGRESS_PID}" 2>/dev/null || true
        PROGRESS_PID=""
    fi
    PROGRESS_CMD_FILE=""
}

# Small reusable error dialog (dismiss any progress spinner first)
show_error_dialog() {
    local msg="$1"
    stop_progress
    if ! run_dialog \
        --height "${appSizeSmall}" \
        --icon "${appIcon}" \
        --overlayicon "SF=xmark.octagon.fill,colour=red" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${msg}" \
        --button1text "OK" \
        --ontop --moveable
    then
        log_debug "Error dialog dismissed"
    fi
}

# ── Dependency + config validation ───────────────────────────────────────────
validate_environment() {
    if [[ ! -x "${JQ}" ]]
    then
        log_error "jq is required but not found in PATH"
        exit 1
    fi
    if [[ ! -x "${CURL}" ]]
    then
        log_error "curl is required but not found in PATH"
        exit 1
    fi
    if [[ ! -x "${DIALOG_BIN}" ]]
    then
        log_error "swiftDialog not installed at ${DIALOG_BIN}"
        exit 1
    fi
    if [[ -z "${JAMF_URL}" ]]
    then
        log_error "Unable to read Jamf URL from com.jamfsoftware.jamf.plist — is this Mac enrolled?"
        exit 1
    fi
    log_info "Jamf URL: ${JAMF_URL}"

    case "${PARAM_DELETE_MODE}" in
        after-sent|after-ack|immediate|never)
            log_info "Delete mode: ${PARAM_DELETE_MODE}"
            ;;
        *)
            log_error "Invalid delete mode '${PARAM_DELETE_MODE}' (use after-sent | after-ack | immediate | never)"
            exit 1
            ;;
    esac

    if [[ "${PARAM_DRY_RUN}" == "true" ]]
    then
        log_warn "DRY RUN enabled — no erase or delete commands will be issued"
    fi

    if [[ "${PARAM_DELETE_FROM_ENTRA}" == "true" ]]
    then
        log_info "Cleanup Entra ENABLED — will ensure ${CONFIG_PLIST} exists (PEM only for method 'cert'), resolve the Entra auth method, then delete matching Entra device object(s) by displayName"
    fi
}

# ── Resolve Jamf API credentials (params first, then root-only config plist) ──
resolve_credentials() {
    if [[ -n "${PARAM_CLIENT_ID}" && -n "${PARAM_CLIENT_SECRET}" ]]
    then
        CLIENT_ID="${PARAM_CLIENT_ID}"
        CLIENT_SECRET="${PARAM_CLIENT_SECRET}"
        log_info "Using API credentials from Jamf script parameters"
        return 0
    fi

    if [[ -f "${CONFIG_PLIST}" ]]
    then
        CLIENT_ID=$("${PLIST_BUDDY}" -c "Print :client_id" "${CONFIG_PLIST}" 2>/dev/null) || CLIENT_ID=""
        CLIENT_SECRET=$("${PLIST_BUDDY}" -c "Print :client_secret" "${CONFIG_PLIST}" 2>/dev/null) || CLIENT_SECRET=""
        if [[ -n "${CLIENT_ID}" && -n "${CLIENT_SECRET}" ]]
        then
            log_info "Using API credentials from ${CONFIG_PLIST}"
            return 0
        fi
    fi

    log_error "No API credentials — set Jamf parameters 4/5 or create ${CONFIG_PLIST} (root:wheel, 600)"
    exit 1
}

# ── Provision the Entra credentials from embedded content (Cleanup Entra only) ─
# Split into two INDEPENDENT pieces so auth method is decoupled from provisioning:
#   • provision_entra_plist — writes the plist skeleton (tenant/client id + the
#     entra_auth_method key, plus entra_cert_path only for cert/auto). ALWAYS
#     safe when cleanup is enabled, for ANY method.
#   • provision_entra_pem   — writes the embedded PEM. OPT-IN: only when the
#     desired auth method is 'cert', the PEM is missing, AND the embedded content
#     actually parses as a certificate (never a placeholder). A 'secret'/'auto'
#     setup is NEVER handed a forced PEM.
# Neither overwrites an existing file; both lock what they create to 600 root:wheel.
provision_credentials() {
    local desired
    "${MKDIR}" -p "${APP_DIR}"

    # Resolve the method once (falls back to the embedded seed when the plist
    # does not exist yet) and hand it to the skeleton writer so it only records
    # the keys that method actually uses.
    desired=$(resolve_provision_auth_method)
    provision_entra_plist "${desired}"

    if [[ "${desired}" == "cert" ]]
    then
        provision_entra_pem
    else
        log_info "Provisioning: auth method '${desired}' does not use a certificate — skipping PEM creation (a PEM is written only when entra_auth_method is 'cert')"
    fi
}

# Desired auth method for provisioning: read the plist (just written, or a
# pre-existing one), else fall back to the embedded default. Normalized.
resolve_provision_auth_method() {
    local m
    m=$("${PLIST_BUDDY}" -c "Print :entra_auth_method" "${CONFIG_PLIST}" 2>/dev/null) || m="${PROVISION_ENTRA_AUTH_METHOD}"
    m=$(printf '%s' "${m}" | "${TR}" '[:upper:]' '[:lower:]' | "${TR}" -d '[:space:]')
    case "${m}" in
        cert|secret|auto)
            printf '%s' "${m}"
            ;;
        *)
            printf 'auto'
            ;;
    esac
}

# Write the plist skeleton (never overwrites an existing plist). Built with
# PlistBuddy so values with XML-special characters (the app path's '&') are
# escaped correctly — a raw heredoc would corrupt the plist. Takes the resolved
# provisioning method ($1: cert|secret|auto) and only records entra_cert_path for
# methods that can use a cert (cert/auto) — a secret-only skeleton omits it so it
# doesn't imply cert auth is expected.
provision_entra_plist() {
    local method="$1"
    local -a add_args

    if [[ -f "${CONFIG_PLIST}" ]]
    then
        log_info "Provisioning: ${CONFIG_PLIST} already present — leaving as-is"
        return 0
    fi

    add_args=(
        -c "Add :entra_tenant_id string ${PROVISION_ENTRA_TENANT_ID}"
        -c "Add :entra_client_id string ${PROVISION_ENTRA_CLIENT_ID}"
        -c "Add :entra_auth_method string ${method}"
    )

    if [[ "${method}" == "cert" || "${method}" == "auto" ]]
    then
        add_args+=( -c "Add :entra_cert_path string ${APP_DIR}/entra-graph.pem" )
        log_info "Provisioning: creating ${CONFIG_PLIST} skeleton (tenant/client id, auth method '${method}', cert_path)"
    else
        log_info "Provisioning: creating ${CONFIG_PLIST} skeleton (tenant/client id, auth method '${method}'; no cert_path — secret auth)"
    fi

    "${PLIST_BUDDY}" "${add_args[@]}" "${CONFIG_PLIST}"
    "${CHOWN}" root:wheel "${CONFIG_PLIST}"
    "${CHMOD}" 600 "${CONFIG_PLIST}"
}

# Write the embedded PEM — OPT-IN, cert method only (gated by the caller).
# Never overwrites an existing PEM. Validates that the embedded content actually
# parses as a certificate before keeping it, so the REPLACE_ME placeholder below
# does NOT force a broken cert path — it is removed and secret auth stays viable.
# ⚠️  SECURITY: if you paste a LIVE Entra private key into the heredoc, anyone who
#     can read THIS SCRIPT (e.g. Jamf "Read Scripts") can authenticate as that
#     app. Prefer deploying the PEM via a package and leaving this placeholder;
#     rotate the key in Entra if the script is ever exposed.
provision_entra_pem() {
    local dest="${APP_DIR}/entra-graph.pem"

    if [[ -f "${dest}" ]]
    then
        log_info "Provisioning: PEM already present at ${dest} — leaving as-is"
        return 0
    fi

    log_info "Provisioning: creating Entra PEM at ${dest}"
    # ⚠️ REPLACE_ME: paste YOUR OWN Entra app certificate + private key below,
    # between the markers, exactly as the two PEM blocks (certificate first,
    # then private key). The original org's live key was REMOVED for handoff.
    # If you leave the placeholder, this function detects it does not parse as a
    # certificate, removes it, and does NOT force cert auth — use secret auth, or
    # deploy a real PEM out-of-band.
    "${CAT}" > "${dest}" <<'PEM_EOF'
#############################################################################
## REPLACE THIS ENTIRE BLOCK with YOUR OWN Entra app credential, in PEM    ##
## form: your X.509 certificate block immediately followed by its private  ##
## key block (the standard BEGIN/END CERTIFICATE and BEGIN/END PRIVATE KEY ##
## armor, base64 body between the markers).                                ##
##                                                                         ##
## This public template ships NO key. Until you replace this block it will ##
## not parse as a certificate, so provision_entra_pem() deletes it and     ##
## does NOT force cert auth — use entra_client_secret (secret auth), or     ##
## deploy a real PEM to entra_cert_path out-of-band via a package.         ##
#############################################################################
PEM_EOF
    "${CHOWN}" root:wheel "${dest}"
    "${CHMOD}" 600 "${dest}"

    # If the embedded content is still the placeholder (or a corrupt paste), it
    # won't parse as an X.509 cert. Remove it rather than leaving a broken PEM
    # that would force cert auth and then fail at signing — secret auth stays
    # usable, and 'auto' can fall back to it.
    if ! "${OPENSSL}" x509 -in "${dest}" -noout 2>/dev/null
    then
        log_warn "Provisioning: embedded PEM is a placeholder or unparseable — removing it and NOT forcing cert auth. Paste a real cert+key into the PEM_EOF block, or use entra_client_secret for secret auth."
        "${RM}" -f "${dest}"
        return 0
    fi

    log_warn "Provisioning: installed an embedded Entra private key at ${dest} (root:wheel 600). SECURITY: anyone who can read this script payload can extract this key — prefer packaging the PEM out-of-band, and rotate the key in Entra if the script is ever exposed."
    return 0
}

# ── Is the configured Entra cert usable? (exists + parses as an X.509 cert) ───
entra_cert_is_valid() {
    if [[ -z "${ENTRA_CERT_PATH}" || ! -f "${ENTRA_CERT_PATH}" ]]
    then
        return 1
    fi
    if ! "${OPENSSL}" x509 -in "${ENTRA_CERT_PATH}" -noout 2>/dev/null
    then
        return 1
    fi
    return 0
}

# ── Load Entra (Microsoft Graph) app credentials from the root-only plist ─────
# Optional — only needed when PARAM_DELETE_FROM_ENTRA is "true". Never fatal.
# Reads the requested auth method (entra_auth_method: cert|secret|auto, default
# auto) and RESOLVES it into ENTRA_AUTH_METHOD from what's actually present:
#   cert   — require a valid cert; skip cleanly if missing/unparseable.
#   secret — require entra_client_secret; a stray PEM on disk is ignored.
#   auto   — prefer a valid cert, else fall back to a secret, else skip.
# The RESOLVED method (not "a cert path happens to be set") drives auth, so a
# stray/placeholder PEM cannot hijack a secret-only setup.
load_entra_credentials() {
    local default_cert="${APP_DIR}/entra-graph.pem"
    local requested
    ENTRA_AUTH_METHOD=""

    if [[ ! -f "${CONFIG_PLIST}" ]]
    then
        log_warn "Entra deletion enabled but ${CONFIG_PLIST} not found — Entra cleanup will be skipped"
        return 0
    fi

    ENTRA_TENANT_ID=$("${PLIST_BUDDY}" -c "Print :entra_tenant_id" "${CONFIG_PLIST}" 2>/dev/null) || ENTRA_TENANT_ID=""
    ENTRA_CLIENT_ID=$("${PLIST_BUDDY}" -c "Print :entra_client_id" "${CONFIG_PLIST}" 2>/dev/null) || ENTRA_CLIENT_ID=""
    ENTRA_CLIENT_SECRET=$("${PLIST_BUDDY}" -c "Print :entra_client_secret" "${CONFIG_PLIST}" 2>/dev/null) || ENTRA_CLIENT_SECRET=""
    ENTRA_CERT_PATH=$("${PLIST_BUDDY}" -c "Print :entra_cert_path" "${CONFIG_PLIST}" 2>/dev/null) || ENTRA_CERT_PATH=""

    # Requested method (default auto), normalized.
    requested=$("${PLIST_BUDDY}" -c "Print :entra_auth_method" "${CONFIG_PLIST}" 2>/dev/null) || requested=""
    requested=$(printf '%s' "${requested}" | "${TR}" '[:upper:]' '[:lower:]' | "${TR}" -d '[:space:]')
    case "${requested}" in
        cert|secret|auto)
            :
            ;;
        *)
            requested="auto"
            ;;
    esac

    # Default the cert path so cert/auto can find the standard PEM location.
    if [[ -z "${ENTRA_CERT_PATH}" ]]
    then
        ENTRA_CERT_PATH="${default_cert}"
    fi

    # Tenant + client id are required for every method.
    if [[ -z "${ENTRA_TENANT_ID}" || -z "${ENTRA_CLIENT_ID}" ]]
    then
        log_warn "Entra deletion enabled but entra_tenant_id/entra_client_id missing in ${CONFIG_PLIST} — skipping"
        return 0
    fi

    log_info "Entra auth method requested: ${requested}"

    # Resolve the requested method against what is actually present.
    case "${requested}" in
        cert)
            if entra_cert_is_valid
            then
                ENTRA_AUTH_METHOD="cert"
            else
                log_error "Entra auth method 'cert' requires a valid certificate at ${ENTRA_CERT_PATH}, but none was found or it failed to parse — Entra cleanup will be skipped"
                return 0
            fi
            ;;
        secret)
            if [[ -n "${ENTRA_CLIENT_SECRET}" ]]
            then
                ENTRA_AUTH_METHOD="secret"
                # Ignore any cert on disk — secret was explicitly requested.
                ENTRA_CERT_PATH=""
            else
                log_error "Entra auth method 'secret' requires entra_client_secret in ${CONFIG_PLIST}, but it is missing — Entra cleanup will be skipped"
                return 0
            fi
            ;;
        auto)
            if entra_cert_is_valid
            then
                ENTRA_AUTH_METHOD="cert"
            elif [[ -n "${ENTRA_CLIENT_SECRET}" ]]
            then
                ENTRA_AUTH_METHOD="secret"
                ENTRA_CERT_PATH=""
            else
                log_warn "Entra auth method 'auto' found neither a valid cert at ${ENTRA_CERT_PATH} nor an entra_client_secret — Entra cleanup will be skipped"
                return 0
            fi
            ;;
    esac

    if [[ "${ENTRA_AUTH_METHOD}" == "cert" ]]
    then
        log_info "Loaded Entra app credentials (tenant ${ENTRA_TENANT_ID}, certificate auth: ${ENTRA_CERT_PATH})"
    else
        log_info "Loaded Entra app credentials (tenant ${ENTRA_TENANT_ID}, client-secret auth)"
    fi
    return 0
}

# ── Preflight: confirm the RESOLVED auth method's credentials are usable ──────
# Called right after load_entra_credentials so a broken Entra config fails fast
# (before any erase) instead of surfacing mid-run in get_graph_token(). Verifies
# the credential the chosen method needs exists and is readable/parseable. On
# failure it clears ENTRA_AUTH_METHOD so the run continues with Entra cleanup
# skipped (never fatal to the erase workflow).
preflight_entra_auth() {
    case "${ENTRA_AUTH_METHOD}" in
        cert)
            if ! entra_cert_is_valid
            then
                log_error "Entra preflight FAILED: certificate at ${ENTRA_CERT_PATH} is missing or unparseable — Entra cleanup will be skipped for all devices"
                ENTRA_AUTH_METHOD=""
                return 1
            fi
            log_info "Entra preflight OK: certificate auth (${ENTRA_CERT_PATH})"
            ;;
        secret)
            if [[ -z "${ENTRA_CLIENT_SECRET}" ]]
            then
                log_error "Entra preflight FAILED: entra_client_secret missing — Entra cleanup will be skipped for all devices"
                ENTRA_AUTH_METHOD=""
                return 1
            fi
            log_info "Entra preflight OK: client-secret auth"
            ;;
        *)
            log_warn "Entra preflight: no usable auth method resolved — Entra cleanup will be skipped for all devices"
            return 1
            ;;
    esac
    return 0
}

# ── base64url helper (reads stdin: text or binary) ───────────────────────────
b64url() {
    "${OPENSSL}" enc -base64 -A | "${TR}" '+/' '-_' | "${TR}" -d '='
}

# ── Build a PS256 client-assertion JWT for Graph cert auth (prints to stdout) ─
# Per Microsoft's certificate-credentials spec: header alg=PS256, typ=JWT, and
# x5t#S256 = base64url(SHA-256(cert DER)); claims aud/iss/sub/jti/nbf/exp/iat;
# signature is RSA-PSS/SHA-256. Reads the cert AND private key from the same
# combined PEM at ENTRA_CERT_PATH (openssl x509 reads the cert; openssl dgst
# -sign reads the private key). Verified on macOS system LibreSSL 3.3+.
build_graph_assertion() {
    local x5t header payload h_b64 p_b64 signing_input sig now exp jti aud
    now=$("${DATE}" +%s)
    exp=$(( now + 300 ))
    jti=$("${UUIDGEN}")
    aud="https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/token"

    # Fail clearly if the cert can't be read/parsed (permission, corruption, or a
    # PEM with no certificate) instead of hashing empty input and failing at sign.
    if ! "${OPENSSL}" x509 -in "${ENTRA_CERT_PATH}" -noout 2>/dev/null
    then
        log_error "Cannot read the certificate in ${ENTRA_CERT_PATH} — running as root? PEM valid (cert + key)?"
        return 1
    fi
    x5t=$("${OPENSSL}" x509 -in "${ENTRA_CERT_PATH}" -outform DER 2>/dev/null | "${OPENSSL}" dgst -sha256 -binary | b64url)
    if [[ -z "${x5t}" ]]
    then
        log_error "Could not read certificate from ${ENTRA_CERT_PATH} to compute x5t#S256"
        return 1
    fi

    header=$("${JQ}" -c -n --arg x5t "${x5t}" '{alg:"PS256", typ:"JWT", "x5t#S256":$x5t}')
    payload=$("${JQ}" -c -n \
        --arg iss "${ENTRA_CLIENT_ID}" \
        --arg aud "${aud}" \
        --arg jti "${jti}" \
        --argjson now "${now}" \
        --argjson exp "${exp}" \
        '{aud:$aud, iss:$iss, sub:$iss, jti:$jti, nbf:$now, exp:$exp, iat:$now}')

    h_b64=$(printf '%s' "${header}" | b64url)
    p_b64=$(printf '%s' "${payload}" | b64url)
    signing_input="${h_b64}.${p_b64}"

    sig=$(printf '%s' "${signing_input}" \
        | "${OPENSSL}" dgst -sha256 -sign "${ENTRA_CERT_PATH}" \
            -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:digest -binary 2>/dev/null \
        | b64url)
    if [[ -z "${sig}" ]]
    then
        log_error "OpenSSL failed to sign the Graph client assertion (check the private key in ${ENTRA_CERT_PATH})"
        return 1
    fi

    printf '%s.%s' "${signing_input}" "${sig}"
    return 0
}

# ── Microsoft Graph: obtain an app-only access token (cert assertion or secret)
get_graph_token() {
    local resp_file http_code now expires_in assertion
    local -a auth_args
    resp_file=$(create_temp_file "graphtoken")

    # Branch on the RESOLVED auth method (set by load_entra_credentials), NOT on
    # whether a cert path variable happens to be non-empty.
    if [[ "${ENTRA_AUTH_METHOD}" == "cert" ]]
    then
        if ! assertion=$(build_graph_assertion)
        then
            ENTRA_ACCESS_TOKEN=""
            return 1
        fi
        auth_args=( --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                    --data-urlencode "client_assertion=${assertion}" )
        log_info "Authenticating to Microsoft Graph with a certificate (client assertion)"
    elif [[ "${ENTRA_AUTH_METHOD}" == "secret" ]]
    then
        auth_args=( --data-urlencode "client_secret=${ENTRA_CLIENT_SECRET}" )
        log_info "Authenticating to Microsoft Graph with a client secret"
    else
        log_warn "No resolved Entra auth method (ENTRA_AUTH_METHOD is empty) — cannot get a Graph token"
        ENTRA_ACCESS_TOKEN=""
        return 1
    fi

    http_code=$("${CURL}" --silent --show-error --location \
        --connect-timeout 15 --max-time 60 \
        -X POST "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${ENTRA_CLIENT_ID}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "scope=https://graph.microsoft.com/.default" \
        "${auth_args[@]}" \
        --write-out "%{http_code}" --output "${resp_file}") || http_code="000"

    if [[ "${http_code}" != "200" ]]
    then
        log_warn "Microsoft Graph token request failed (HTTP ${http_code}): $("${JQ}" -r '.error // empty' "${resp_file}" 2>/dev/null)"
        ENTRA_ACCESS_TOKEN=""
        return 1
    fi
    ENTRA_ACCESS_TOKEN=$("${JQ}" -r '.access_token // empty' "${resp_file}")
    expires_in=$("${JQ}" -r '.expires_in // 0' "${resp_file}")
    if [[ -z "${ENTRA_ACCESS_TOKEN}" ]]
    then
        log_warn "Graph token response contained no access_token"
        return 1
    fi
    now=$("${DATE}" +%s)
    ENTRA_TOKEN_EXPIRY_EPOCH=$(( now + expires_in - TOKEN_SKEW_SECONDS ))
    log_info "Obtained Microsoft Graph token (expires in ${expires_in}s)"
    return 0
}

# ── Refresh the Graph token only when needed. Returns 0 if a token is available.
ensure_graph_token() {
    local now
    now=$("${DATE}" +%s)
    if [[ -z "${ENTRA_ACCESS_TOKEN}" || ${now} -ge ${ENTRA_TOKEN_EXPIRY_EPOCH} ]]
    then
        get_graph_token
    fi
    if [[ -n "${ENTRA_ACCESS_TOKEN}" ]]
    then
        return 0
    fi
    return 1
}

# ── Delete a Mac's device object(s) from Microsoft Entra by displayName ───────
# Matches on displayName == the Jamf computer name and deletes EVERY match
# (stale duplicate registrations are exactly what blocks PSSO/Company Portal
# re-registration). Never fatal to the erase workflow — logs and returns.
# NOTE: app-only device deletion needs Device.ReadWrite.All AND the app's
# service principal assigned the "Cloud Device Administrator" Entra role;
# without the role Graph returns 403.
delete_from_entra() {
    local computer_name="$1"
    local resp_file http_code count escaped
    local deleted=0 failed=0
    local dev_id del_file dcode

    if [[ -z "${ENTRA_TENANT_ID}" || -z "${ENTRA_CLIENT_ID}" || -z "${ENTRA_AUTH_METHOD}" ]]
    then
        log_warn "Entra credentials/auth method not resolved — skipping Entra cleanup for '${computer_name}'"
        return 1
    fi
    if [[ -z "${computer_name}" ]]
    then
        log_warn "No computer name to match in Entra — skipping"
        return 1
    fi
    if ! ensure_graph_token
    then
        log_warn "No Microsoft Graph token — skipping Entra cleanup for '${computer_name}'"
        return 1
    fi

    # OData string literal escaping: a single quote is doubled ('' ).
    escaped="${computer_name//\'/''}"
    resp_file=$(create_temp_file "entrafind")
    http_code=$("${CURL}" --silent --show-error --location --get \
        --connect-timeout 15 --max-time 60 \
        -H "Authorization: Bearer ${ENTRA_ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        -H "ConsistencyLevel: eventual" \
        --data-urlencode "\$filter=displayName eq '${escaped}'" \
        --data-urlencode "\$count=true" \
        --data-urlencode "\$select=id,deviceId,displayName,operatingSystem,approximateLastSignInDateTime" \
        --write-out "%{http_code}" --output "${resp_file}" \
        "https://graph.microsoft.com/v1.0/devices") || http_code="000"

    if [[ "${http_code}" != "200" ]]
    then
        log_warn "Entra device lookup failed for '${computer_name}' (HTTP ${http_code})"
        return 1
    fi

    count=$("${JQ}" -r '.value | length' "${resp_file}" 2>/dev/null || printf '0')
    if [[ "${count}" -eq 0 ]]
    then
        log_info "No Entra device object found for '${computer_name}' — nothing to delete"
        return 0
    fi
    log_info "Found ${count} Entra device object(s) named '${computer_name}' — deleting all"

    while IFS= read -r dev_id
    do
        if [[ -z "${dev_id}" ]]
        then
            continue
        fi
        del_file=$(create_temp_file "entradel")
        dcode=$("${CURL}" --silent --show-error --location \
            --connect-timeout 15 --max-time 60 \
            -X DELETE \
            -H "Authorization: Bearer ${ENTRA_ACCESS_TOKEN}" \
            --write-out "%{http_code}" --output "${del_file}" \
            "https://graph.microsoft.com/v1.0/devices/${dev_id}") || dcode="000"

        if [[ "${dcode}" == "204" ]]
        then
            log_info "Deleted Entra device object ${dev_id} ('${computer_name}')"
            deleted=$(( deleted + 1 ))
        elif [[ "${dcode}" == "403" ]]
        then
            log_error "Entra delete 403 for ${dev_id} — the app needs the 'Cloud Device Administrator' role in addition to Device.ReadWrite.All"
            failed=$(( failed + 1 ))
        else
            log_error "Failed to delete Entra device object ${dev_id} (HTTP ${dcode})"
            failed=$(( failed + 1 ))
        fi
    done < <("${JQ}" -r '.value[].id' "${resp_file}")

    log_info "Entra cleanup for '${computer_name}': ${deleted} deleted, ${failed} failed"
    if [[ ${failed} -gt 0 ]]
    then
        return 1
    fi
    return 0
}

# ── OAuth: obtain access token ───────────────────────────────────────────────
get_oauth_token() {
    local resp_file
    local http_code
    local now
    local expires_in
    local skew
    resp_file=$(create_temp_file "token")

    http_code=$("${CURL}" --silent --show-error --location \
        --connect-timeout 15 --max-time 60 \
        -X POST "${JAMF_URL}/api/oauth/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "client_secret=${CLIENT_SECRET}" \
        --data-urlencode "grant_type=client_credentials" \
        --write-out "%{http_code}" --output "${resp_file}") || http_code="000"

    if [[ "${http_code}" != "200" ]]
    then
        log_error "OAuth token request failed (HTTP ${http_code})"
        show_error_dialog "Could not authenticate to Jamf Pro (HTTP ${http_code}).\\n\\nCheck the API client credentials and network connectivity."
        exit 1
    fi

    ACCESS_TOKEN=$("${JQ}" -r '.access_token // empty' "${resp_file}")
    expires_in=$("${JQ}" -r '.expires_in // 0' "${resp_file}")

    if [[ -z "${ACCESS_TOKEN}" ]]
    then
        log_error "OAuth response contained no access_token"
        exit 1
    fi

    now=$("${DATE}" +%s)
    # Refresh a little before real expiry. With a normal ~20-30 min token the
    # fixed 60s skew is fine; but some API clients issue very short tokens
    # (e.g. 59s), where a 60s skew marks the token expired immediately and we
    # re-auth on EVERY call. Cap the skew to a third of the lifetime for those.
    skew="${TOKEN_SKEW_SECONDS}"
    if [[ ${expires_in} -le $(( TOKEN_SKEW_SECONDS * 2 )) ]]
    then
        skew=$(( expires_in / 3 ))
    fi
    TOKEN_EXPIRY_EPOCH=$(( now + expires_in - skew ))
    log_info "Obtained OAuth token (expires in ${expires_in}s)"
}

# ── Refresh token only when needed ───────────────────────────────────────────
ensure_token() {
    local now
    now=$("${DATE}" +%s)
    if [[ "${FORCE_TOKEN_REFRESH}" == "true" || -z "${ACCESS_TOKEN}" || ${now} -ge ${TOKEN_EXPIRY_EPOCH} ]]
    then
        get_oauth_token
        FORCE_TOKEN_REFRESH="false"
    fi
}

# ── Central authenticated API call ───────────────────────────────────────────
# Usage: http_code=$(jamf_api METHOD PATH OUTFILE [BODYFILE])
# Auto-refreshes the token once on a 401.
jamf_api() {
    local method="$1"
    local path="$2"
    local out_file="$3"
    local body_file="${4:-}"
    local http_code="000"
    local attempt=0
    local -a curl_args

    while [[ ${attempt} -lt 2 ]]
    do
        ensure_token
        curl_args=( --silent --show-error --location \
            --connect-timeout 15 --max-time 120 \
            -X "${method}" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Accept: application/json" \
            --write-out "%{http_code}" --output "${out_file}" )
        if [[ -n "${body_file}" ]]
        then
            curl_args+=( -H "Content-Type: application/json" --data-binary "@${body_file}" )
        fi

        http_code=$("${CURL}" "${curl_args[@]}" "${JAMF_URL}${path}") || http_code="000"

        if [[ "${http_code}" == "401" ]]
        then
            log_warn "HTTP 401 on ${method} ${path} — refreshing token and retrying once"
            FORCE_TOKEN_REFRESH="true"
            attempt=$(( attempt + 1 ))
            continue
        fi
        break
    done

    printf '%s' "${http_code}"
}

# ── Fetch ALL managed computers (paginated, file-accumulated for ARG_MAX safety)
# Produces a flat JSON array at $DEVICES_JSON:
#   [ { "id":"123", "name":"MAC-01", "serial":"C02...", "managementId":"uuid" }, ... ]
fetch_all_computers() {
    local page=0
    local total=-1
    local fetched=0
    local page_file
    local merge_file
    local page_count
    local http_code

    printf '[]' > "${DEVICES_JSON}"

    while true
    do
        page_file=$(create_temp_file "page_${page}")
        http_code=$(jamf_api "GET" \
            "/api/v1/computers-inventory?section=GENERAL&section=HARDWARE&page=${page}&page-size=${INVENTORY_PAGE_SIZE}&sort=general.name:asc" \
            "${page_file}")

        if [[ "${http_code}" != "200" ]]
        then
            log_error "Inventory request failed on page ${page} (HTTP ${http_code})"
            show_error_dialog "Failed to read computer inventory from Jamf Pro (HTTP ${http_code})."
            exit 1
        fi

        if [[ ${total} -lt 0 ]]
        then
            total=$("${JQ}" -r '.totalCount // 0' "${page_file}")
            log_info "Inventory reports ${total} total computers"
        fi

        page_count=$("${JQ}" -r '.results | length' "${page_file}")

        # Project only the fields we need and merge into the running array using
        # slurp mode (-s) which reads FILES — never passes big data via argv.
        merge_file=$(create_temp_file "merge_${page}")
        "${JQ}" -s '
            .[0] + ( (.[1].results // [])
                     | map({
                         id:           (.id | tostring),
                         name:         (.general.name // "Unknown"),
                         serial:       (.hardware.serialNumber // ""),
                         managementId: (.general.managementId // "")
                       }) )
        ' "${DEVICES_JSON}" "${page_file}" > "${merge_file}"
        "${MV}" "${merge_file}" "${DEVICES_JSON}"

        fetched=$(( fetched + page_count ))
        log_debug "Page ${page}: +${page_count} (accumulated ${fetched}/${total})"
        update_progress "Loading computer inventory…  (${fetched}/${total})"

        if [[ ${page_count} -eq 0 || ${fetched} -ge ${total} ]]
        then
            break
        fi
        page=$(( page + 1 ))
    done

    if [[ "$("${JQ}" -r 'length' "${DEVICES_JSON}")" -eq 0 ]]
    then
        log_error "Inventory returned zero computers"
        show_error_dialog "Jamf Pro returned no managed computers."
        exit 1
    fi
    log_info "Loaded ${fetched} computers into the picker"
}

# ── Build the label for a device: "Name  —  SERIAL" (commas stripped for CSV) ─
# Serial is unique per Mac, so the label uniquely maps back to one record.
build_selectvalues() {
    "${JQ}" -r '
        map( (.name | gsub(",";" ")) + "  —  " + (if .serial == "" then "NO-SERIAL" else .serial end) )
        | join(",")
    ' "${DEVICES_JSON}"
}

# ── Map a chosen label back to id + managementId ─────────────────────────────
lookup_field_by_label() {
    local label="$1"
    local field="$2"
    "${JQ}" -r --arg L "${label}" --arg F "${field}" '
        map( select( ((.name | gsub(",";" ")) + "  —  " + (if .serial == "" then "NO-SERIAL" else .serial end)) == $L ) )
        | .[0][$F] // empty
    ' "${DEVICES_JSON}"
}

# ── Present the searchable picker (native swiftDialog searchable/multiselect) ─
# Populates SELECTED_LABELS. Returns 0 if at least one device was picked,
# 1 if the user cancelled or picked nothing.
#
# swiftDialog searchable select renders a type-to-filter combo box.
# --selecttitle modifiers (parsed independently): "required" gates button1,
# "searchable" enables filtering, "multiselect" lets several devices be tagged.
# JSON output contract (verified against swiftDialog quitDialog source):
#   single      -> "SelectedOption": "LABEL"
#   multiselect -> "SelectedOption": "LABEL_A, LABEL_B"   (SORTED, joined by ", ")
# It is a STRING in both cases — never an array. Because we strip commas out of
# device names when building labels, the only ", " in the string is the
# multiselect separator, so splitting on ", " recovers the individual labels.
select_devices() {
    local selectvalues
    local out_file
    local title_spec="Devices,required,searchable"
    local msg
    local line
    selectvalues=$(build_selectvalues)
    out_file=$(create_temp_file "select")

    if [[ "${PARAM_MULTI_SELECT}" == "true" ]]
    then
        title_spec="${title_spec},multiselect"
        msg="Search and select **one or more** devices to **ERASE**.\\n\\nType part of a computer name or serial number to filter, then check each device you want."
    else
        msg="Search and select a device to **ERASE**.\\n\\nType part of a computer name or serial number to filter the list."
    fi

    if ! run_dialog \
        --height "${appSizeMedium}" \
        --icon "${appIcon}" \
        --overlayicon "SF=laptopcomputer.and.arrow.down,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${msg}" \
        --selecttitle "${title_spec}" \
        --selectvalues "${selectvalues}" \
        --button1text "Confirm Selection" \
        --button2text "Cancel" \
        --ontop --moveable \
        --json \
        > "${out_file}"
    then
        log_info "Device selection cancelled by user"
        return 1
    fi

    while IFS= read -r line
    do
        if [[ -n "${line}" ]]
        then
            SELECTED_LABELS+=("${line}")
        fi
    done < <("${JQ}" -r '
        ( .SelectedOption // .Devices.selectedValue // "" )
        | select(. != "")
        | split(", ")
        | .[]
    ' "${out_file}")

    if [[ "${#SELECTED_LABELS[@]}" -eq 0 ]]
    then
        log_warn "Dialog returned no device selection"
        return 1
    fi
    log_info "Selected ${#SELECTED_LABELS[@]} device(s)"
    return 0
}

# ── Format a UTC ISO8601 timestamp as LOCAL, human-readable ──────────────────
# e.g. "2026-07-06T15:36:00.000Z" -> "Monday July, 6 2026 11:36 AM" (local tz).
# Jamf reports these in UTC (trailing Z); appending " +0000" tells BSD `date`
# the input is UTC so it converts to the Mac's local time zone for display.
format_datetime() {
    local raw="$1"
    local clean
    local out
    if [[ -z "${raw}" || "${raw}" == "null" ]]
    then
        printf 'Unknown'
        return 0
    fi
    # Reduce to YYYY-MM-DDTHH:MM:SS (strip fractional seconds and/or trailing Z)
    clean="${raw%%.*}"
    clean="${clean%Z}"
    if out=$("${DATE}" -j -f "%Y-%m-%dT%H:%M:%S %z" "${clean} +0000" "+%A %B, %-d %Y %I:%M %p" 2>/dev/null)
    then
        printf '%s' "${out}"
    else
        printf '%s' "${raw}"
    fi
}

# ── Normalize an ABM/ADE color string to icns filename form ──────────────────
# "BLUSH" -> "blush", "SPACE GRAY" -> "space-gray", "SKY BLUE" -> "sky-blue".
normalize_color() {
    printf '%s' "$1" | "${TR}" '[:upper:]' '[:lower:]' \
        | "${SED}" -e 's/^ *//' -e 's/ *$//' -e 's/  */-/g'
}

# ── Resolve the color-matched MacBook Neo icon from the sealed system volume ──
# The Neo icons live in a CoreTypes sub-bundle whose NUMBER shifts between macOS
# releases, so we glob for it rather than hardcoding CoreTypes-0033. Order:
#   1. exact color match  com.apple.macbookneo-<color>.icns
#   2. any Neo icon (unknown/blank color)
# Returns 0 + the path on success, 1 if no Neo icon exists on this OS.
# (Under /bin/bash an unmatched glob stays literal, so the -f test filters it;
#  do NOT rely on this under zsh, which errors on nomatch.)
resolve_neo_icon() {
    local color="$1"
    local f
    if [[ -n "${color}" ]]
    then
        for f in "${DEVICE_ICON_LIB}"/CoreTypes-*.bundle/Contents/Resources/com.apple.macbookneo-"${color}".icns
        do
            if [[ -f "${f}" ]]
            then
                printf '%s' "${f}"
                return 0
            fi
        done
    fi
    for f in "${DEVICE_ICON_LIB}"/CoreTypes-*.bundle/Contents/Resources/com.apple.macbookneo-*.icns
    do
        if [[ -f "${f}" ]]
        then
            printf '%s' "${f}"
            return 0
        fi
    done
    return 1
}

# ── Photorealistic hardware icon for a Mac model (mirrors ABM_MDM_Assignment) ─
# Args: $1 = hardware.model, $2 = ADE enclosure color (optional; used for Neo).
# Returns a swiftDialog --icon value: a photorealistic com.apple.*.icns for the
# model (color-matched for MacBook Neo), or an "SF=<symbol>" fallback.
# Match order matters: Air before Book (MacBook Air also matches "book"); iMac
# before Pro (iMac Pro also matches "pro").
mac_icon_value() {
    local model="$1"
    local color="${2:-}"
    local lc_model
    lc_model=$(printf '%s' "${model}" | "${TR}" '[:upper:]' '[:lower:]')
    local sf="desktopcomputer"
    local -a candidates=()

    if [[ "${lc_model}" == *air* ]]
    then
        candidates=( "com.apple.macbookair-13-2022-silver.icns" "com.apple.macbookair.icns" )
        sf="laptopcomputer"
    elif [[ "${lc_model}" == *neo* ]]
    then
        # MacBook Neo — resolve the color-matched icon from the sealed volume.
        # Checked before *book* so it doesn't fall into the MacBook Pro branch.
        local neo_icon
        if neo_icon=$(resolve_neo_icon "$(normalize_color "${color}")")
        then
            printf '%s' "${neo_icon}"
            return 0
        fi
        # No Neo icon on this macOS — generic laptop fallback from main Resources.
        candidates=( "com.apple.macbook.icns" "com.apple.macbookair-13-2022-silver.icns" "com.apple.macbookair.icns" )
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

    local c
    for c in "${candidates[@]}"
    do
        if [[ -f "${DEVICE_ICON_DIR}/${c}" ]]
        then
            printf '%s/%s' "${DEVICE_ICON_DIR}" "${c}"
            return 0
        fi
    done
    printf 'SF=%s' "${sf}"
}

# ── Build a serial→color map from Jamf's ADE (device-enrollments) sync ────────
# Standard computer inventory has no enclosure color — it only exists in Apple's
# ADE sync. We enumerate device-enrollment instances (or use the configured id),
# page each instance's /devices, and write one NDJSON line per device:
#   {serial (UPPERCASE), color, model}
# Verified against a live tenant: envelope is {results,totalCount}; the field is
# "color" (e.g. "SPACE GRAY","CITRUS"); some devices have "" (non-color models).
# Pagination stops on totalCount so it can't loop if the API ignores `page`.
# Only ABM/ADE-assigned devices appear here; user-enrolled Macs simply won't match.
build_ade_color_map() {
    local -a instance_ids=()
    local inst_page dev_page http_code id iid
    local page total accumulated got n

    ADE_COLOR_MAP=$(create_temp_file "ademap")
    : > "${ADE_COLOR_MAP}"

    if [[ -n "${PARAM_ADE_INSTANCE_ID}" ]]
    then
        instance_ids=( "${PARAM_ADE_INSTANCE_ID}" )
        log_info "ADE: using configured enrollment instance ${PARAM_ADE_INSTANCE_ID}"
    else
        page=0
        total=-1
        accumulated=0
        while :
        do
            inst_page=$(create_temp_file "adeinst")
            http_code=$(jamf_api "GET" "/api/v1/device-enrollments?page=${page}&page-size=100&sort=id:asc" "${inst_page}")
            if [[ "${http_code}" != "200" ]]
            then
                log_warn "ADE: could not list enrollment instances (HTTP ${http_code}) — colors unavailable"
                ADE_MAP_BUILT="true"
                return 0
            fi
            if [[ ${total} -lt 0 ]]
            then
                total=$("${JQ}" -r '.totalCount // 0' "${inst_page}")
            fi
            while IFS= read -r id
            do
                if [[ -n "${id}" ]]
                then
                    instance_ids+=("${id}")
                fi
            done < <("${JQ}" -r '.results[]?.id // empty' "${inst_page}")
            got=$("${JQ}" -r '.results | length' "${inst_page}")
            accumulated=$(( accumulated + got ))
            if [[ ${got} -eq 0 || ${accumulated} -ge ${total} ]]
            then
                break
            fi
            page=$(( page + 1 ))
        done
        log_info "ADE: ${#instance_ids[@]} enrollment instance(s) to scan"
    fi

    for iid in "${instance_ids[@]:-}"
    do
        if [[ -z "${iid}" ]]
        then
            continue
        fi
        page=0
        total=-1
        accumulated=0
        while :
        do
            dev_page=$(create_temp_file "adedev")
            http_code=$(jamf_api "GET" "/api/v1/device-enrollments/${iid}/devices?page=${page}&page-size=100&sort=id:asc" "${dev_page}")
            if [[ "${http_code}" != "200" ]]
            then
                log_warn "ADE: devices query failed for instance ${iid} (HTTP ${http_code})"
                break
            fi
            if [[ ${total} -lt 0 ]]
            then
                total=$("${JQ}" -r '.totalCount // 0' "${dev_page}")
            fi
            "${JQ}" -c '.results[]?
                | {serial: ((.serialNumber // "") | ascii_upcase),
                   color:  (.color // ""),
                   model:  (.model // "")}
                | select(.serial != "")' "${dev_page}" >> "${ADE_COLOR_MAP}"
            got=$("${JQ}" -r '.results | length' "${dev_page}")
            accumulated=$(( accumulated + got ))
            if [[ ${got} -eq 0 || ${accumulated} -ge ${total} ]]
            then
                break
            fi
            page=$(( page + 1 ))
        done
    done

    ADE_MAP_BUILT="true"
    n=$("${AWK}" 'END{print NR}' "${ADE_COLOR_MAP}" 2>/dev/null || printf '0')
    log_info "ADE: color map built (${n} device record(s))"
}

# ── Build the ADE color map at most once per run ─────────────────────────────
ensure_ade_color_map() {
    if [[ "${ADE_MAP_BUILT}" == "true" ]]
    then
        return 0
    fi
    log_info "Fetching Apple ADE enrollment data for enclosure color…"
    build_ade_color_map
}

# ── Look up an ADE enclosure color by serial (empty if none / non-ADE) ────────
lookup_ade_color() {
    local serial="$1"
    local up
    if [[ -z "${serial}" || -z "${ADE_COLOR_MAP}" || ! -f "${ADE_COLOR_MAP}" ]]
    then
        printf ''
        return 0
    fi
    up=$(printf '%s' "${serial}" | "${TR}" '[:lower:]' '[:upper:]')
    "${JQ}" -r -s --arg s "${up}" 'map(select(.serial == $s)) | (.[0].color // "")' "${ADE_COLOR_MAP}"
}

# ── Fetch live inventory for one computer id → formatted markdown block ───────
# Endpoint: GET /api/v1/computers-inventory-detail/{id} (returns the full record
# at root, so .general / .hardware / .userAndLocation are top-level).
# Fields are extracted individually so timestamps can be humanized via `date`
# (BSD date can't run inside jq). This formats an ALREADY-FETCHED detail file —
# the caller does the API request so the model (for icon selection) and HTTP
# status stay in the parent shell (a $(...) capture runs in a subshell, so a
# global set here would be lost). Field keys with a version-dependent name
# (email, model) fall back to the alternate spelling across Jamf versions.
format_device_block() {
    local resp_file="$1"
    local name serial raw_serial model checkin_raw inv_raw site managed supervised fv_state fv_pct username email
    local checkin inv fv managed_disp supervised_disp color_raw color_disp

    name=$("${JQ}"       -r '.general.name // "Unknown"' "${resp_file}")
    serial=$("${JQ}"     -r '.hardware.serialNumber // "—"' "${resp_file}")
    raw_serial=$("${JQ}" -r '.hardware.serialNumber // ""' "${resp_file}")
    model=$("${JQ}"      -r '.hardware.model // .hardware.modelIdentifier // ""' "${resp_file}")
    checkin_raw=$("${JQ}" -r '.general.lastContactTime // ""' "${resp_file}")
    inv_raw=$("${JQ}"    -r '.general.reportDate // ""' "${resp_file}")
    site=$("${JQ}"       -r '.general.site.name // "None"' "${resp_file}")
    managed=$("${JQ}"    -r '.general.remoteManagement.managed // empty' "${resp_file}")
    supervised=$("${JQ}" -r '.general.supervised // empty' "${resp_file}")
    fv_state=$("${JQ}"   -r '.diskEncryption.bootPartitionEncryptionDetails.partitionFileVault2State // ""' "${resp_file}")
    fv_pct=$("${JQ}"     -r '.diskEncryption.bootPartitionEncryptionDetails.partitionFileVault2Percent // empty' "${resp_file}")
    username=$("${JQ}"   -r '.userAndLocation.username // "—"' "${resp_file}")
    email=$("${JQ}"      -r '.userAndLocation.email // .userAndLocation.emailAddress // "—"' "${resp_file}")

    checkin=$(format_datetime "${checkin_raw}")
    inv=$(format_datetime "${inv_raw}")

    # Enclosure color comes from the ADE map (already built by the caller); Title
    # Case the ABM string ("SPACE GRAY" -> "Space Gray"). Blank => non-ADE Mac.
    color_raw=$(lookup_ade_color "${raw_serial}")
    if [[ -n "${color_raw}" ]]
    then
        color_disp=$(printf '%s' "${color_raw}" \
            | "${AWK}" '{ for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)) } 1')
    else
        color_disp="Unknown"
    fi

    case "${managed}" in
        true)  managed_disp="Yes" ;;
        false) managed_disp="No" ;;
        *)     managed_disp="Unknown" ;;
    esac
    case "${supervised}" in
        true)  supervised_disp="Yes" ;;
        false) supervised_disp="No" ;;
        *)     supervised_disp="Unknown" ;;
    esac

    if [[ -z "${fv_state}" ]]
    then
        fv="Unknown"
    elif [[ -n "${fv_pct}" ]]
    then
        fv="${fv_state} (${fv_pct}%)"
    else
        fv="${fv_state}"
    fi

    printf '**%s**\n\n' "${name}"
    printf -- '- **Serial:** %s\n' "${serial}"
    printf -- '- **Model:** %s\n' "${model:-—}"
    printf -- '- **Color:** %s\n' "${color_disp}"
    printf -- '- **Last Check-In:** %s\n' "${checkin}"
    printf -- '- **Last Inventory:** %s\n' "${inv}"
    printf -- '- **Site:** %s\n' "${site}"
    printf -- '- **Managed:** %s  ·  **Supervised:** %s\n' "${managed_disp}" "${supervised_disp}"
    printf -- '- **FileVault:** %s\n' "${fv}"
    printf -- '- **User:** %s\n' "${username}"
    printf -- '- **Email:** %s' "${email}"
    return 0
}

# ── Final typed confirmation with live inventory. Returns 0 only if typed ERASE
confirm_destruction() {
    local out_file
    local typed
    local details=""
    local lbl
    local comp_id
    local detail_file
    local http_code
    local block
    local single_model=""
    local single_serial=""
    local single_color=""
    local confirm_msg
    out_file=$(create_temp_file "confirm")

    # Slow, UI-less phase — show the working spinner until the confirm dialog.
    start_progress "Gathering device details…"

    # Build the ADE color map once up front — every device block shows a Color
    # line (format_device_block reads the map, which the subshell inherits).
    ensure_ade_color_map

    log_info "Fetching inventory detail for ${#SELECTED_LABELS[@]} selected device(s)"
    for lbl in "${SELECTED_LABELS[@]}"
    do
        update_progress "Gathering device details…"
        comp_id=$(lookup_field_by_label "${lbl}" "id")
        detail_file=$(create_temp_file "detail_${comp_id}")
        # NOTE: fetch here in the parent (not inside a $(...) capture) so the
        # model and HTTP status remain in this shell for icon selection below.
        http_code=$(jamf_api "GET" "/api/v1/computers-inventory-detail/${comp_id}" "${detail_file}")
        if [[ "${http_code}" == "200" ]]
        then
            block=$(format_device_block "${detail_file}")
            single_model=$("${JQ}" -r '.hardware.model // .hardware.modelIdentifier // ""' "${detail_file}")
            single_serial=$("${JQ}" -r '.hardware.serialNumber // ""' "${detail_file}")
        else
            log_warn "Detail lookup failed for computer id ${comp_id} (HTTP ${http_code})"
            block="- _Could not load inventory details for computer id ${comp_id} (HTTP ${http_code})_"
            single_model=""
            single_serial=""
        fi
        if [[ -n "${details}" ]]
        then
            details+=$'\n\n---\n\n'
        fi
        details+="${block}"
    done

    # For a single device, swap the brand icon for that model's hardware photo
    # (mirrors ABM_MDM_Assignment). With multiple devices there is no single
    # photo to show, so keep the brand icon.
    if [[ "${#SELECTED_LABELS[@]}" -eq 1 && -n "${single_model}" ]]
    then
        # Color-matched icons (MacBook Neo) need the enclosure color; the ADE map
        # is already built above, so this is just a lookup.
        single_color=$(lookup_ade_color "${single_serial}")
        if [[ "$(printf '%s' "${single_model}" | "${TR}" '[:upper:]' '[:lower:]')" == *neo* ]]
        then
            if [[ -n "${single_color}" ]]
            then
                log_info "ADE enclosure color for ${single_serial}: ${single_color}"
            else
                log_info "No ADE color for ${single_serial} (non-ADE or unsynced) — generic Neo icon"
            fi
        fi
        DIALOG_ICON=$(mac_icon_value "${single_model}" "${single_color}")
        log_info "Using hardware icon for '${single_model}': ${DIALOG_ICON}"
    fi

    local entra_line=""
    if [[ "${PARAM_DELETE_FROM_ENTRA}" == "true" ]]
    then
        entra_line=$'\n\n☁️ The matching **Microsoft Entra** device record(s) will ALSO be deleted, so the Mac can re-register with PSSO / Company Portal.'
    fi

    confirm_msg="### ⚠️ This will PERMANENTLY ERASE the following ${#SELECTED_LABELS[@]} device(s):

${details}

All data will be destroyed. Delete mode after erase: **${PARAM_DELETE_MODE}**.${entra_line}

Type **ERASE** below to confirm."

    # Data is ready — kill the spinner so it isn't up behind the confirm dialog.
    stop_progress

    if ! run_dialog \
        --height "${appSizeXLarge}" \
        --icon "${DIALOG_ICON}" \
        --iconsize "${deviceIconSize}" \
        --overlayicon "SF=trash.fill,colour=red" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${confirm_msg}" \
        --textfield "Confirmation,required,prompt=Type ERASE to confirm" \
        --button1text "Erase Device(s)" \
        --button2text "Cancel" \
        --ontop --moveable \
        --json \
        > "${out_file}"
    then
        log_info "User cancelled at confirmation"
        return 1
    fi

    typed=$("${JQ}" -r '.Confirmation // ""' "${out_file}")
    if [[ "${typed}" != "ERASE" ]]
    then
        log_warn "Confirmation text did not match (got '${typed}')"
        show_error_dialog "Confirmation text did not match. No devices were erased."
        return 1
    fi
    return 0
}

# ── Queue the EraseDevice MDM command. Echoes the command UUID (or empty) ─────
issue_erase_command() {
    local mgmt_id="$1"
    local body_file
    local resp_file
    local http_code
    local uuid
    body_file=$(create_temp_file "erasebody")
    resp_file=$(create_temp_file "eraseresp")

    # Build the payload with jq. commandType ERASE_DEVICE is the required
    # discriminator; pin is included ONLY when supplied (Intel T2 needs it,
    # Apple Silicon ignores it).
    "${JQ}" -n \
        --arg mid "${mgmt_id}" \
        --arg pin "${PARAM_ERASE_PIN}" \
        '{
            clientData: [ { managementId: $mid } ],
            commandData: ( { commandType: "ERASE_DEVICE" }
                           + ( if $pin == "" then {} else { pin: $pin } end ) )
        }' > "${body_file}"

    http_code=$(jamf_api "POST" "/api/v2/mdm/commands" "${resp_file}" "${body_file}")

    if [[ "${http_code}" != "201" && "${http_code}" != "200" ]]
    then
        log_error "Erase command rejected for managementId ${mgmt_id} (HTTP ${http_code})"
        log_debug "Response: $("${JQ}" -c '.' "${resp_file}" 2>/dev/null || "${CAT}" "${resp_file}")"
        return 1
    fi

    # Response shape varies slightly by Jamf version; pull the first UUID-ish field.
    uuid=$("${JQ}" -r '(.[0].id // .[0].commandUuid // .id // .commandUuid // empty)' "${resp_file}" 2>/dev/null)
    log_info "Erase queued for managementId ${mgmt_id} (command uuid: ${uuid:-unknown})"
    printf '%s' "${uuid}"
    return 0
}

# ── Confirm the erase command was ISSUED (accepted + sent) — one quick GET ────
# "Issued" = the command exists in Jamf's queue with a non-error commandState
# (PENDING / ACKNOWLEDGED / NOT_NOW all count — the device just hasn't finished
# yet). Returns 0 if issued, 1 if missing/errored. Reads the version-dependent
# status field (this tenant uses `commandState`, e.g. "PENDING").
verify_command_issued() {
    local uuid="$1"
    local resp_file http_code state date_sent state_norm
    resp_file=$(create_temp_file "cmdissued")

    http_code=$(jamf_api "GET" \
        "/api/v2/mdm/commands?page=0&page-size=1&filter=uuid%3D%3D%22${uuid}%22" \
        "${resp_file}")
    if [[ "${http_code}" != "200" ]]
    then
        log_warn "Could not query command ${uuid} (HTTP ${http_code})"
        return 1
    fi

    state=$("${JQ}" -r '
        ( .results? // . ) | ( if type == "array" then .[0] else . end )
        | ( .commandState // .status // "" )' "${resp_file}")
    date_sent=$("${JQ}" -r '
        ( .results? // . ) | ( if type == "array" then .[0] else . end )
        | ( .dateSent // "" )' "${resp_file}")
    state_norm=$(printf '%s' "${state}" | "${TR}" '[:lower:]' '[:upper:]' | "${TR}" -d '_ ')

    log_info "Command ${uuid} state=${state:-<none>} dateSent=${date_sent:-<none>}"
    case "${state_norm}" in
        ""|ERROR|FAILED)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ── Poll command status until acknowledged/completed or timeout. 0 if acked ───
# GET /api/v2/mdm/commands is filterable on uuid & status. The response shape and
# status casing vary by Jamf version — Jamf's own docs filter on "status==Pending"
# (Title case, not PENDING). So we parse tolerantly: accept either a top-level
# array or a {results:[…]} envelope, and normalize the status (uppercase, strip
# spaces/underscores) before matching. The raw response is logged once so an
# unexpected shape is diagnosable from the log.
wait_for_ack() {
    local uuid="$1"
    local dev_label="${2:-device}"
    local resp_file
    local status=""
    local status_norm=""
    local waited=0
    local http_code
    local logged_raw="false"

    if [[ -z "${uuid}" ]]
    then
        log_warn "No command UUID to poll — cannot confirm acknowledgment"
        return 1
    fi

    resp_file=$(create_temp_file "cmdstatus")

    while [[ ${waited} -lt ${ACK_TIMEOUT_SECONDS} ]]
    do
        http_code=$(jamf_api "GET" \
            "/api/v2/mdm/commands?page=0&page-size=1&filter=uuid%3D%3D%22${uuid}%22" \
            "${resp_file}")

        if [[ "${http_code}" == "200" ]]
        then
            if [[ "${logged_raw}" == "false" ]]
            then
                log_debug "Raw command-status response: $("${JQ}" -c '.' "${resp_file}" 2>/dev/null)"
                logged_raw="true"
            fi
            status=$("${JQ}" -r '
                ( .results? // . )
                | ( if type == "array" then .[0] else . end )
                | ( .commandState // .status // "" )
            ' "${resp_file}")
            status_norm=$(printf '%s' "${status}" | "${TR}" '[:lower:]' '[:upper:]' | "${TR}" -d '_ ')
            log_debug "Command ${uuid} status: ${status:-<none>} (waited ${waited}s)"
            update_progress "Erasing ${dev_label}…  waiting for the device to acknowledge  (${waited}s)"
            case "${status_norm}" in
                ACKNOWLEDGED|COMPLETED)
                    return 0
                    ;;
                ERROR|FAILED|NOTNOW)
                    log_warn "Command ${uuid} returned status ${status}"
                    return 1
                    ;;
            esac
        else
            log_warn "Status poll failed (HTTP ${http_code})"
        fi

        "${SLEEP}" "${ACK_POLL_INTERVAL}"
        waited=$(( waited + ACK_POLL_INTERVAL ))
    done

    log_warn "Timed out after ${ACK_TIMEOUT_SECONDS}s waiting for ack of ${uuid}"
    return 1
}

# ── Delete the Jamf computer record by numeric id ────────────────────────────
delete_computer_record() {
    local comp_id="$1"
    local resp_file
    local http_code
    resp_file=$(create_temp_file "delete")

    http_code=$(jamf_api "DELETE" "/api/v1/computers-inventory/${comp_id}" "${resp_file}")

    if [[ "${http_code}" == "204" || "${http_code}" == "200" ]]
    then
        log_info "Deleted Jamf record for computer id ${comp_id}"
        return 0
    fi
    log_error "Failed to delete computer id ${comp_id} (HTTP ${http_code})"
    return 1
}

# ── Orchestrate erase + (conditional) delete for one selected label ──────────
process_device() {
    local label="$1"
    local comp_id
    local mgmt_id
    local computer_name
    local uuid
    comp_id=$(lookup_field_by_label "${label}" "id")
    mgmt_id=$(lookup_field_by_label "${label}" "managementId")
    computer_name=$(lookup_field_by_label "${label}" "name")

    if [[ -z "${comp_id}" || -z "${mgmt_id}" ]]
    then
        log_error "Could not resolve id/managementId for '${label}' — skipping"
        return 1
    fi

    log_info "Processing '${label}' (id=${comp_id}, managementId=${mgmt_id})"

    if [[ "${PARAM_DRY_RUN}" == "true" ]]
    then
        log_warn "[DRY RUN] Would erase managementId ${mgmt_id} and delete id ${comp_id} (mode ${PARAM_DELETE_MODE})"
        if [[ "${PARAM_DELETE_FROM_ENTRA}" == "true" ]]
        then
            log_warn "[DRY RUN] Would delete Entra device object(s) with displayName '${computer_name}'"
        fi
        return 0
    fi

    update_progress "Sending erase command to ${label}…"
    uuid=$(issue_erase_command "${mgmt_id}") || return 1

    case "${PARAM_DELETE_MODE}" in
        never)
            log_info "Delete mode 'never' — leaving record for id ${comp_id}"
            ;;
        after-sent)
            update_progress "Confirming the erase command was issued…"
            if verify_command_issued "${uuid}"
            then
                log_info "Erase command issued (accepted + sent) — deleting record id ${comp_id}"
                update_progress "Erase issued. Removing Jamf record for ${label}…"
                delete_computer_record "${comp_id}" || true
            else
                log_warn "Could not confirm the erase was issued — NOT deleting id ${comp_id}."
            fi
            ;;
        immediate)
            log_warn "Delete mode 'immediate' — deleting id ${comp_id} without any verification (may cancel an undelivered wipe)"
            update_progress "Removing Jamf record for ${label}…"
            delete_computer_record "${comp_id}" || true
            ;;
        after-ack)
            update_progress "Erase sent to ${label}. Waiting for the device to acknowledge…"
            if wait_for_ack "${uuid}" "${label}"
            then
                log_info "Device acknowledged erase — deleting record id ${comp_id}"
                update_progress "Acknowledged. Removing Jamf record for ${label}…"
                delete_computer_record "${comp_id}" || true
            else
                log_warn "Erase not acknowledged in time — NOT deleting id ${comp_id}. Follow up manually."
            fi
            ;;
    esac

    # Entra cleanup — remove the stale device object(s) so the Mac can cleanly
    # re-register with PSSO / Company Portal for Conditional Access. Independent
    # of the Jamf delete outcome; never aborts the run.
    if [[ "${PARAM_DELETE_FROM_ENTRA}" == "true" ]]
    then
        update_progress "Removing '${computer_name}' from Microsoft Entra…"
        delete_from_entra "${computer_name}" || true
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

require_root
validate_environment

# swiftDialog needs a GUI session — enforce the logged-in-user requirement here,
# right after the other preflight checks, before any side effects.
CURRENT_USER=$(get_current_user) || {
    log_error "No user logged in — cannot display the device picker"
    exit 1
}
CONSOLE_UID=$(get_current_user_uid "${CURRENT_USER}")
log_info "Running dialogs as ${CURRENT_USER} (uid ${CONSOLE_UID})"

# Self-provision the Entra credentials.plist + PEM if requested (param 11 =
# "provision") and they're missing. Runs as root; creates only what's absent.
if [[ "${PARAM_PROVISION_CREDS}" == "true" ]]
then
    provision_credentials
fi

resolve_credentials

if [[ "${PARAM_DELETE_FROM_ENTRA}" == "true" ]]
then
    load_entra_credentials
    # Fail fast: verify the resolved method's creds are usable before any erase.
    # Non-fatal — on failure ENTRA_AUTH_METHOD is cleared and cleanup is skipped.
    preflight_entra_auth || true
fi

# Show the working spinner across the slow, UI-less auth + inventory load so the
# user isn't staring at nothing. Killed right before the device picker appears.
start_progress "Connecting to Jamf Pro…"
ensure_token
update_progress "Loading computer inventory…"

# Accumulator files / arrays
DEVICES_JSON=$(create_temp_file "devices")
declare -a SELECTED_LABELS=()

# 1. Pull inventory
fetch_all_computers

# Data is ready — kill the spinner before the picker is displayed.
stop_progress

# 2. Selection (one searchable dialog; multiselect when enabled)
if ! select_devices
then
    log_info "No device selected — nothing to do"
    exit 0
fi

log_info "Final selection: ${#SELECTED_LABELS[@]} device(s)"

# 3. Typed confirmation gate
if ! confirm_destruction
then
    log_info "Destruction not confirmed — exiting without action"
    exit 0
fi

# 4. Erase + conditional delete
# Show the working spinner across this phase — the erase → acknowledge → delete
# wait (up to ACK_TIMEOUT_SECONDS per device) would otherwise be a silent stall.
start_progress "Sending erase command…"
FAILURES=0
for label in "${SELECTED_LABELS[@]}"
do
    if ! process_device "${label}"
    then
        FAILURES=$(( FAILURES + 1 ))
    fi
done
# Done erasing — kill the spinner before the summary dialog.
stop_progress

# 5. Summary dialog
if [[ ${FAILURES} -eq 0 ]]
then
    summary_icon="SF=checkmark.circle.fill,colour=green"
    summary_msg="Processed ${#SELECTED_LABELS[@]} device(s) with no errors.\\n\\nCheck /var/log/jamf.log for details."
else
    summary_icon="SF=exclamationmark.triangle.fill,colour=orange"
    summary_msg="Processed ${#SELECTED_LABELS[@]} device(s). **${FAILURES} had errors** — review /var/log/jamf.log."
fi

if ! run_dialog \
    --height "${appSizeSmall}" \
    --icon "${DIALOG_ICON}" \
    --iconsize "${deviceIconSize}" \
    --overlayicon "${summary_icon}" \
    --bannerimage "${brandingBanner}" \
    --bannertext "${appName}" \
    --message "${summary_msg}" \
    --button1text "Close" \
    --timer 30 \
    --ontop --moveable
then
    log_debug "Summary dialog dismissed"
fi

if [[ ${FAILURES} -gt 0 ]]
then
    log_error "${SCRIPT_NAME} completed with ${FAILURES} failure(s)"
    exit 1
fi

log_info "${SCRIPT_NAME} completed successfully"
exit 0

###########################################################
################## End Script Block #######################
###########################################################

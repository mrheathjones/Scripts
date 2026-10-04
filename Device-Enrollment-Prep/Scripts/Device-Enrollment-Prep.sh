#! /bin/bash
# File-wide: `which` is preferred over `command -v` per the style guide, and
# `readonly NAME=$(which ...)` is the template's declaration style, and jq/awk
# programs are deliberately single-quoted (their $vars are jq/awk variables).
# shellcheck disable=SC2230,SC2155,SC2016

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Device-Enrollment-Prep.sh
# Author: Heath Jones
# Date: 06-25-2026
# Modified: 10-04-2026
# Purpose: Self Service workflow. Prompts a technician (swiftDialog) for an
#          asset tag, serial number, and a PreStage enrollment selection,
#          then (1) upserts a Jamf Inventory Preload record for the asset
#          tag + serial and (2) assigns the serial to the selected computer
#          PreStage enrollment scope. Both take effect at the next ADE
#          (re-)enrollment; the PreStage supplies the device's site.
# Version: 1.0 - Initial Script
#          1.1 - Removed host serial auto-detection (script runs off-device);
#                serial input is now uppercased on submit.
#          1.2 - Added bulk CSV Inventory Preload: a "Bulk CSV" file-select in
#                the prompt and a headless CSV path (Parameter 8). Parses by
#                header, skips existing preloads, derives asset tag from
#                Computer Name (org asset-tag pattern) when the Asset Tag column is blank.
#          1.3 - Public release prep: sanitized identifiers/credentials,
#                expert-bash conformance. Removed embedded API client
#                credentials (params 4/5 now required via require_param);
#                Admin mode (param 6) now defaults to OFF (support mode);
#                asset-tag fallback pattern is now the configurable
#                ASSET_TAG_PATTERN; hardcoded Jamf URL fallback replaced by a
#                refused-if-unchanged placeholder; dialogs are skipped when no
#                GUI is available; single-device serial is validated before
#                it is used in an API filter; launchctl/sudo via binary vars.
#          1.4 - Renamed to Name-Of-Script.sh convention
#
# Requirements:
#   - Runs as root (Jamf Self Service policy)
#   - jq (ships with macOS 15+; install it on older macOS)
#   - Jamf Pro tenant URL readable from com.jamfsoftware.jamf.plist, or
#     JAMF_URL_FALLBACK set below
#   - Jamf parameter $4: API Client ID (required)
#   - Jamf parameter $5: API Client Secret (required)
#   - Jamf parameter $6: Admin mode toggle (optional; blank = support mode)
#   - Jamf parameter $7: Curated Device Type list (required in support mode)
#   - Jamf parameter $8: Bulk CSV path (optional; enables headless bulk mode)
#   - API Role privileges: Read/Create/Update Inventory Preload Records,
#     Read/Update Computer PreStage Enrollments
#   - swiftDialog at /usr/local/bin/dialog for the interactive form (optional
#     for headless bulk mode; interactive mode exits with an error without it)
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
readonly ORG_NAME_FRIENDLY="Company Name"
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.4"
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

# ── Task-specific binary paths ───────────────────────────────────────────────
readonly CURL=$(which curl)
readonly JQ=$(which jq)
readonly DEFAULTS=$(which defaults)
readonly SED=$(which sed)
readonly TR=$(which tr)
readonly SCUTIL=$(which scutil)
readonly CHMOD=$(which chmod)
readonly SLEEP=$(which sleep)
readonly GREP=$(which grep)
readonly SORT=$(which sort)
readonly MV=$(which mv)
readonly LAUNCHCTL=$(which launchctl)
readonly SUDO=$(which sudo)

# ── Jamf Pro API credentials (Jamf policy parameters) ────────────────────────
# Parameter 4: API Client ID    (OAuth client_id)
# Parameter 5: API Client Secret (OAuth client_secret)
# The API Role needs: Read/Create/Update Inventory Preload Records,
#                     Read/Update Computer PreStage Enrollments.
# Both are REQUIRED; there are no defaults. The script refuses to run if empty.
readonly JAMF_CLIENT_ID="${4:-}"
readonly JAMF_CLIENT_SECRET="${5:-}"

# ── Admin mode toggle (Jamf policy Parameter 6) ──────────────────────────────
# When set to a truthy value (admin / true / yes / 1 / on), the "Device Type"
# dropdown lists ALL Computer PreStage Enrollments fetched live from Jamf. When
# empty (default / support mode), the dropdown shows only the curated
# CURATED_DEVICE_TYPES list below. Scope an "admin" copy of the policy with
# Parameter 6 set; leave it blank on the standard Self Service policy.
readonly ADMIN_MODE_PARAM="${6:-}"

case "${ADMIN_MODE_PARAM}" in
    enabled|admin|Admin|ADMIN|true|TRUE|True|yes|Yes|YES|1|on|On|ON)
        readonly ADMIN_MODE="true"
        ;;
    *)
        readonly ADMIN_MODE="false"
        ;;
esac

# ── Bulk CSV path (Jamf policy Parameter 8, optional) ────────────────────────
# If set, the script runs headless bulk mode against this CSV (no prompt): it
# reads each row's serial + asset tag and creates Inventory Preload records,
# skipping serials that already have one. Leave blank for the interactive flow
# (a CSV can also be chosen/dropped in the prompt's "Bulk CSV" field).
readonly CSV_PATH_PARAM="${8:-}"

# ── Jamf URL from the local management plist (strip trailing slash) ──────────
# Guarded so a missing key (unenrolled Mac) doesn't trip `set -e`/`pipefail`.
# If the plist has no jss_url, JAMF_URL_FALLBACK is used; the script refuses to
# run while the fallback is still the placeholder value.
readonly JAMF_URL_PLACEHOLDER="https://your-instance.jamfcloud.com"
readonly JAMF_URL_FALLBACK="https://your-instance.jamfcloud.com"    # CHANGE_ME: your Jamf Pro URL (used only if the plist has no jss_url)
if ! JAMF_URL=$("${DEFAULTS}" read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null | "${SED}" -e 's/\/$//')
then
    JAMF_URL=""
fi
if [[ -z "${JAMF_URL}" ]]
then
    JAMF_URL="${JAMF_URL_FALLBACK%/}"
fi

# ── swiftDialog: App / Org Identity ──────────────────────────────────────────
APP_NAME="Device Enrollment Prep"
DIALOG_BIN="/usr/local/bin/dialog"
# APP_DIR to be used to contain all files associated with the app/script
# ex: log files - ${APP_DIR}/_LOGS, receipts - ${APP_DIR}/_RECEIPTS etc
# shellcheck disable=SC2034  # reserved for future logs/receipts
APP_DIR="/Library/Application Support/${ORG_NAME}/${APP_NAME}"

# ── swiftDialog: Branding Banner ─────────────────────────────────────────────
# local branding banner path
brandingBanner="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/banner.jpg"    # CHANGE_ME: local banner image path
if [[ ! -f "${brandingBanner}" ]]
then
    # online branding banner url if local file doesn't exist
    brandingBanner="https://img.freepik.com/premium-vector/abstract-techno-background-with-flowing-cyber-particles_1048-15244.jpg"
fi

# ── swiftDialog: App Icon ────────────────────────────────────────────────────
# local app icon path
appIcon="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/icon.png"    # CHANGE_ME: local app icon path
if [[ ! -f "${appIcon}" ]]
then
    # built-in SF Symbol fallback if the local file doesn't exist (no network needed)
    appIcon="SF=laptopcomputer.and.arrow.down,colour=blue"
fi
appIconSize=125

# ── swiftDialog: Dialog Size Constants ───────────────────────────────────────
# shellcheck disable=SC2034  # full size scale kept for consistency across scripts
appSizeXSmall=250
# shellcheck disable=SC2034
appSizeSmall=500
appSizeMedium=650
appSizeLarge=800
# shellcheck disable=SC2034
appSizeXLarge=1000

# ── swiftDialog: Dialog Title (banner text — used on every dialog) ───────────
appName="${ORG_NAME_FRIENDLY} - ${APP_NAME}"

# ── Asset tag format (used for the bulk-CSV Computer Name fallback) ───────────
# When a CSV row's Asset Tag column is blank, the Computer Name is used as the
# asset tag if it (uppercased) matches ASSET_TAG_PATTERN, an awk extended regex.
# Set it to "" to disable the fallback. ASSET_TAG_EXAMPLE is shown as the form's
# field hint, and ASSET_TAG_DESCRIPTION in the form's help text.
readonly ASSET_TAG_PATTERN="^(AB|CD)[0-9][0-9][0-9][0-9][0-9][0-9]$"    # CHANGE_ME: your org's asset tag regex
readonly ASSET_TAG_EXAMPLE="AB123456"                                    # CHANGE_ME: sample asset tag for the form hint
readonly ASSET_TAG_DESCRIPTION="AB/CD + 6 digits"                        # CHANGE_ME: plain-language description of the pattern

# ── Device Type dropdown placeholder (forces a conscious choice) ─────────────
readonly SELECT_PROMPT="Select a device type"

# ── Rich form message (Markdown) ─────────────────────────────────────────────
readonly FORM_MESSAGE="## Device Enrollment Preparation\n\nRegister device(s) for their next automated (ADE) re-enrollment. Nothing changes on any Mac now — settings apply at the next enrollment.\n\n**Single device** — fill in **Asset Tag**, **Serial Number**, and **Device Type** below.\n\n**Bulk** — choose or drag a **.csv** into the **Bulk CSV** field. Its *Serial Number* and *Asset Tag* columns are read; when a row's asset tag is blank the *Computer Name* is used if it looks like an asset tag (${ASSET_TAG_DESCRIPTION}). Records that already exist are skipped. In bulk, the single-device fields above are ignored.\n\n> ℹ️ Asset tags are saved to Jamf **Inventory Preload**; serials are stored in uppercase."

# ── Curated Device Type list (support / default mode) — Jamf Parameter 7 ─────
# Parameter 7: a comma-separated list of Device Type names shown in the dropdown
# when NOT in admin mode. Each name MUST exactly match a Computer PreStage
# Enrollment displayName in Jamf Pro — the script resolves the selected name to
# its PreStage by that exact name. Names must not contain commas; surrounding
# whitespace is trimmed. Populated into CURATED_DEVICE_TYPES at runtime.
# Example Parameter 7 value:
#   Standard Staff Mac, Shared Kiosk Mac, Lab Workstation Mac, Loaner Mac
readonly CURATED_DEVICE_TYPES_PARAM="${7:-}"
declare -a CURATED_DEVICE_TYPES=()

# ── Runtime state (populated as the script runs) ─────────────────────────────
ACCESS_TOKEN=""
DIALOG_PID=""
DIALOG_CMD_FILE=""
PRESTAGE_IDS_FILE=""
DROPDOWN_VALUES=""
PRESTAGE_ID=""
PRESTAGE_NAME=""
CURRENT_USER=""
CONSOLE_UID=""
HAS_GUI="false"

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

# ── Preflight ────────────────────────────────────────────────────────────────
require_root() {
    if [[ "$("${ID}" -u)" -ne 0 ]]
    then
        log_error "Must run as root"
        exit 1
    fi
}

require_param() {
    local name="$1"
    local value="$2"
    if [[ -z "${value}" ]]
    then
        log_error "Required parameter ${name} is empty"
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

# ── Cleanup (trapped on EXIT/INT/TERM) — overrides core cleanup to also ──────
# ── invalidate the OAuth token and tear down any open dialog. ────────────────
cleanup() {
    local exit_code=$?
    local f

    if [[ -n "${DIALOG_PID}" ]]
    then
        if [[ -n "${DIALOG_CMD_FILE}" && -f "${DIALOG_CMD_FILE}" ]]
        then
            printf 'quit:\n' >> "${DIALOG_CMD_FILE}" 2>/dev/null || true
        fi
        if ! wait "${DIALOG_PID}" 2>/dev/null
        then
            log_debug "Dialog process already closed during cleanup"
        fi
    fi

    if [[ -n "${ACCESS_TOKEN}" ]]
    then
        invalidate_jamf_token "${ACCESS_TOKEN}"
        log_debug "OAuth access token invalidated"
    fi

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

# ── Preflight: jq ────────────────────────────────────────────────────────────
require_jq() {
    if [[ -z "${JQ}" || ! -x "${JQ}" ]]
    then
        log_error "jq is required but not found in PATH"
        exit 1
    fi
}

# ── Preflight: Jamf URL (refuse to run on the unchanged placeholder) ─────────
require_jamf_url() {
    if [[ -z "${JAMF_URL}" || "${JAMF_URL}" == "${JAMF_URL_PLACEHOLDER}" ]]
    then
        log_error "No Jamf Pro URL: jss_url is missing from com.jamfsoftware.jamf.plist and JAMF_URL_FALLBACK is still the placeholder"
        exit 1
    fi
}

# ── Temp file helper (tracked for cleanup) ───────────────────────────────────
create_temp_file() {
    local prefix="${1:-tmp}"
    local f
    f=$("${MKTEMP}" "/var/tmp/${prefix}.XXXXXX")
    TEMP_FILES+=("${f}")
    printf '%s' "${f}"
}

# ── User-context resolution (swiftDialog must run as the console user) ───────
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

# ── swiftDialog wrapper — EVERY dialog goes through this ──────────────────────
run_dialog() {
    "${LAUNCHCTL}" asuser "${CONSOLE_UID}" "${SUDO}" -u "${CURRENT_USER}" \
        "${DIALOG_BIN}" "$@" 2>/dev/null
}

# ── OAuth: acquire access token (sets global ACCESS_TOKEN) ───────────────────
get_jamf_access_token() {
    local token_file
    local http_code

    token_file=$(create_temp_file "jamf_token")

    if ! http_code=$("${CURL}" \
        --silent \
        --show-error \
        --location \
        --request POST \
        --url "${JAMF_URL}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${JAMF_CLIENT_ID}" \
        --data-urlencode "client_secret=${JAMF_CLIENT_SECRET}" \
        --output "${token_file}" \
        --write-out "%{http_code}" \
        2>/dev/null)
    then
        http_code="000"
    fi

    if [[ "${http_code}" -ne 200 ]]
    then
        log_error "OAuth token request failed (HTTP ${http_code})"
        return 1
    fi

    ACCESS_TOKEN=$("${JQ}" -r '.access_token // empty' "${token_file}")

    if [[ -z "${ACCESS_TOKEN}" ]]
    then
        log_error "access_token missing from OAuth response"
        return 1
    fi
    log_debug "OAuth access token acquired"
}

# ── OAuth: invalidate access token ───────────────────────────────────────────
invalidate_jamf_token() {
    local token="$1"
    if ! "${CURL}" \
        --silent \
        --request POST \
        --url "${JAMF_URL}/api/v1/auth/invalidate-token" \
        --header "Authorization: Bearer ${token}" \
        >/dev/null 2>&1
    then
        log_debug "Token invalidation returned non-zero (already invalid or network issue)"
    fi
}

# ── Generic Jamf API call (file-based I/O, returns HTTP code on stdout) ───────
jamf_api_call() {
    local method="$1"
    local endpoint="$2"
    local output_file="$3"
    local data_file="${4:-}"
    local http_code
    local -a curl_args

    curl_args=(
        --silent
        --show-error
        --location
        --request "${method}"
        --url "${JAMF_URL}${endpoint}"
        --header "Authorization: Bearer ${ACCESS_TOKEN}"
        --header "Accept: application/json"
        --output "${output_file}"
        --write-out "%{http_code}"
    )

    if [[ -n "${data_file}" ]]
    then
        curl_args+=(
            --header "Content-Type: application/json"
            --data @"${data_file}"
        )
    fi

    if ! http_code=$("${CURL}" "${curl_args[@]}" 2>/dev/null)
    then
        http_code="000"
    fi

    printf '%s' "${http_code}"
}

# ── ADMIN MODE: fetch ALL computer PreStages → ids file + dropdown values ────
# Populates global PRESTAGE_IDS_FILE (one id per line, sorted by displayName)
# and global DROPDOWN_VALUES (comma-joined display names, commas sanitized) for
# swiftDialog --selectvalues. Returns 0 on success, non-zero on failure.
fetch_all_prestages() {
    local resp_file
    local http_code
    local total

    resp_file=$(create_temp_file "prestages")

    http_code=$(jamf_api_call "GET" \
        "/api/v3/computer-prestages?page=0&page-size=100&sort=id%3Adesc" \
        "${resp_file}")

    if [[ "${http_code}" -ne 200 ]]
    then
        log_error "Failed to fetch computer PreStages (HTTP ${http_code})"
        return 1
    fi

    total=$("${JQ}" -r '.totalCount // 0' "${resp_file}")

    if [[ "${total}" -eq 0 ]]
    then
        log_error "No computer PreStage enrollments returned"
        return 1
    fi

    if [[ "${total}" -gt 100 ]]
    then
        log_warn "More than 100 PreStages exist (${total}); only the first 100 are shown"
    fi

    # Sort by displayName so the ids file and the selectvalues string stay aligned.
    "${JQ}" -r '.results | sort_by(.displayName) | .[].id' \
        "${resp_file}" > "${PRESTAGE_IDS_FILE}"

    # Return values via the DROPDOWN_VALUES global — NOT via stdout. The
    # dual-output log_* functions echo to stdout, so returning the value on
    # stdout would let an internal log call corrupt the captured dropdown list.
    DROPDOWN_VALUES=$("${JQ}" -r '[.results | sort_by(.displayName) | .[].displayName | gsub(","; " ")] | join(",")' \
        "${resp_file}")
}

# ── SUPPORT MODE: build the dropdown string from the curated array ───────────
# Joins CURATED_DEVICE_TYPES with commas (sanitizing any commas in names) for
# swiftDialog --selectvalues. No logging here, so it is safe to return on stdout.
build_curated_values() {
    local out=""
    local name
    local sanitized

    for name in "${CURATED_DEVICE_TYPES[@]}"
    do
        sanitized="${name//,/ }"
        if [[ -z "${out}" ]]
        then
            out="${sanitized}"
        else
            out="${out},${sanitized}"
        fi
    done

    printf '%s' "${out}"
}

# ── Resolve an exact PreStage displayName → id (sets global PRESTAGE_ID) ──────
# The v3 computer-prestages endpoint does not support RSQL filtering, so fetch
# the list and match displayName exactly client-side with jq.
lookup_prestage_id_by_name() {
    local name="$1"
    local resp_file
    local http_code
    local total
    local id

    resp_file=$(create_temp_file "prestage_lookup")

    http_code=$(jamf_api_call "GET" \
        "/api/v3/computer-prestages?page=0&page-size=200&sort=id%3Adesc" \
        "${resp_file}")

    if [[ "${http_code}" -ne 200 ]]
    then
        log_error "PreStage lookup failed for '${name}' (HTTP ${http_code})"
        return 1
    fi

    total=$("${JQ}" -r '.totalCount // 0' "${resp_file}")

    if [[ "${total}" -gt 200 ]]
    then
        log_warn "More than 200 PreStages exist (${total}); name '${name}' may be missed if outside the first 200"
    fi

    id=$("${JQ}" -r --arg n "${name}" \
        '[.results[] | select(.displayName == $n) | .id] | .[0] // empty' \
        "${resp_file}")

    if [[ -z "${id}" ]]
    then
        log_error "No PreStage matches the exact name '${name}'"
        return 1
    fi

    PRESTAGE_ID="${id}"
    log_info "Resolved device type '${name}' to PreStage id ${PRESTAGE_ID}"
}

# ── Parse Parameter 7 (comma-separated) into the CURATED_DEVICE_TYPES array ──
# Trims surrounding whitespace on each entry and skips empties. `local IFS`
# auto-restores IFS on return. Bash 3.2-safe.
parse_curated_device_types() {
    local raw="$1"
    local entry
    local trimmed
    local IFS=','

    # Intentional split on IFS=',' to parse the list.
    # shellcheck disable=SC2086
    for entry in ${raw}
    do
        trimmed="${entry#"${entry%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        if [[ -n "${trimmed}" ]]
        then
            CURATED_DEVICE_TYPES+=("${trimmed}")
        fi
    done
}

# ── Build the Device Type dropdown values for the active mode ─────────────────
# Admin mode → all PreStages (also populates PRESTAGE_IDS_FILE for index mapping).
# Support mode → the curated list from Parameter 7. Sets global DROPDOWN_VALUES.
build_dropdown_values() {
    if [[ "${ADMIN_MODE}" == "true" ]]
    then
        fetch_all_prestages
        return $?
    fi

    parse_curated_device_types "${CURATED_DEVICE_TYPES_PARAM}"

    if [[ ${#CURATED_DEVICE_TYPES[@]} -eq 0 ]]
    then
        log_error "Support mode is active but no device types were provided in Parameter 7"
        return 1
    fi

    DROPDOWN_VALUES=$(build_curated_values)
}

# ── Registration form (asset tag + serial + Device Type dropdown) ────────────
show_registration_form() {
    local output_file="$1"
    local dropdown_values="$2"

    run_dialog \
        --height "${appSizeLarge}" \
        --icon "${appIcon}" \
        --iconsize "${appIconSize}" \
        --overlayicon "SF=barcode.viewfinder,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${FORM_MESSAGE}" \
        --textfield "Asset Tag,prompt=e.g. ${ASSET_TAG_EXAMPLE} (single device)" \
        --textfield "Serial Number,prompt=e.g. C02XXXXXXXXX (single device)" \
        --selecttitle "Device Type" \
        --selectvalues "${SELECT_PROMPT},${dropdown_values}" \
        --selectdefault "${SELECT_PROMPT}" \
        --textfield "Bulk CSV,fileselect,filetype=csv,prompt=Choose or drop a .csv for bulk import" \
        --button1text "Submit" \
        --button2text "Cancel" \
        --infotext "${SCRIPT_NAME} v${SCRIPT_VERSION}" \
        --ontop \
        --moveable \
        --json \
        > "${output_file}"
}

# ── Progress dialog (determinate) ────────────────────────────────────────────
start_progress_dialog() {
    local message="$1"
    local total_steps="$2"

    run_dialog \
        --height "${appSizeMedium}" \
        --icon "${appIcon}" \
        --iconsize "${appIconSize}" \
        --overlayicon "SF=externaldrive.badge.plus,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${message}" \
        --progress "${total_steps}" \
        --progresstext "Starting..." \
        --button1text "Please Wait" \
        --button1disabled \
        --infotext "${SCRIPT_NAME} v${SCRIPT_VERSION}" \
        --commandfile "${DIALOG_CMD_FILE}" \
        --ontop \
        --moveable &
    DIALOG_PID=$!
    "${SLEEP}" 0.5
}

update_progress() {
    local step="$1"
    local message="$2"
    printf 'progress: %s\nprogresstext: %s\n' "${step}" "${message}" \
        >> "${DIALOG_CMD_FILE}"
}

complete_and_close_progress() {
    printf 'progress: complete\nprogresstext: %s\n' "Complete" >> "${DIALOG_CMD_FILE}"
    "${SLEEP}" 0.6
    printf 'quit:\n' >> "${DIALOG_CMD_FILE}"
    if ! wait "${DIALOG_PID}" 2>/dev/null
    then
        log_debug "Progress dialog already closed"
    fi
    DIALOG_PID=""
}

close_progress_dialog() {
    if [[ -z "${DIALOG_PID}" ]]
    then
        return 0
    fi
    printf 'quit:\n' >> "${DIALOG_CMD_FILE}"
    if ! wait "${DIALOG_PID}" 2>/dev/null
    then
        log_debug "Progress dialog already closed"
    fi
    DIALOG_PID=""
}

# ── Result dialogs ───────────────────────────────────────────────────────────
show_notification() {
    local message="$1"
    local overlay_icon="${2:-SF=info.circle.fill,colour=blue}"

    # No console user / no swiftDialog: the message is already logged by the
    # caller's log_* line, so skip the dialog instead of failing in launchctl.
    if [[ "${HAS_GUI}" != "true" ]]
    then
        log_warn "No GUI available; dialog suppressed"
        return 0
    fi

    if ! run_dialog \
        --height "${appSizeMedium}" \
        --icon "${appIcon}" \
        --iconsize "${appIconSize}" \
        --overlayicon "${overlay_icon}" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${message}" \
        --button1text "OK" \
        --infotext "${SCRIPT_NAME} v${SCRIPT_VERSION}" \
        --ontop \
        --moveable
    then
        log_debug "Notification dismissed"
    fi
}

show_success() {
    show_notification "$1" "SF=checkmark.circle.fill,colour=green"
}

show_error() {
    show_notification "$1" "SF=xmark.octagon.fill,colour=red"
}

# ── Inventory Preload upsert (asset tag + serial) ────────────────────────────
upsert_inventory_preload() {
    local serial="$1"
    local asset_tag="$2"
    local body_file
    local search_file
    local resp_file
    local http_code
    local existing_id
    local endpoint
    local method

    # Build the record body
    body_file=$(create_temp_file "preload_body")
    "${JQ}" -n \
        --arg serial "${serial}" \
        --arg asset "${asset_tag}" \
        '{serialNumber: $serial, deviceType: "Computer", assetTag: $asset}' \
        > "${body_file}"

    # Look for an existing record for this serial (upsert, never duplicate)
    search_file=$(create_temp_file "preload_search")
    http_code=$(jamf_api_call "GET" \
        "/api/v2/inventory-preload/records?page=0&page-size=1&filter=serialNumber%3D%3D%22${serial}%22" \
        "${search_file}")

    if [[ "${http_code}" -ne 200 ]]
    then
        log_error "Inventory Preload search failed (HTTP ${http_code})"
        return 1
    fi

    existing_id=$("${JQ}" -r '.results[0].id // empty' "${search_file}")

    if [[ -n "${existing_id}" ]]
    then
        log_info "Updating existing Inventory Preload record ${existing_id} for serial ${serial}"
        endpoint="/api/v2/inventory-preload/records/${existing_id}"
        method="PUT"
    else
        log_info "Creating new Inventory Preload record for serial ${serial}"
        endpoint="/api/v2/inventory-preload/records"
        method="POST"
    fi

    resp_file=$(create_temp_file "preload_resp")
    http_code=$(jamf_api_call "${method}" "${endpoint}" "${resp_file}" "${body_file}")

    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]
    then
        log_error "Inventory Preload ${method} failed (HTTP ${http_code})"
        return 1
    fi

    log_info "Inventory Preload record saved (serial=${serial}, assetTag=${asset_tag})"
}

# ── Remove a serial from a PreStage scope (used during reassignment) ─────────
remove_serial_from_prestage() {
    local serial="$1"
    local prestage_id="$2"
    local scope_file
    local body_file
    local resp_file
    local http_code
    local version_lock

    scope_file=$(create_temp_file "old_scope")
    http_code=$(jamf_api_call "GET" \
        "/api/v2/computer-prestages/${prestage_id}/scope" "${scope_file}")

    if [[ "${http_code}" -ne 200 ]]
    then
        log_error "Failed to read scope for PreStage ${prestage_id} (HTTP ${http_code})"
        return 1
    fi

    version_lock=$("${JQ}" -r '.versionLock // empty' "${scope_file}")

    if [[ -z "${version_lock}" ]]
    then
        log_error "Could not determine versionLock for PreStage ${prestage_id}"
        return 1
    fi

    body_file=$(create_temp_file "remove_body")
    "${JQ}" -n \
        --arg s "${serial}" \
        --argjson vl "${version_lock}" \
        '{serialNumbers: [$s], versionLock: $vl}' \
        > "${body_file}"

    resp_file=$(create_temp_file "remove_resp")
    http_code=$(jamf_api_call "POST" \
        "/api/v2/computer-prestages/${prestage_id}/scope/delete-multiple" \
        "${resp_file}" "${body_file}")

    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]
    then
        log_error "Failed to remove serial ${serial} from PreStage ${prestage_id} (HTTP ${http_code})"
        return 1
    fi

    log_info "Removed serial ${serial} from PreStage ${prestage_id}"
}

# ── Assign a serial to the selected PreStage scope (idempotent) ──────────────
assign_prestage() {
    local serial="$1"
    local target_prestage_id="$2"
    local all_scope_file
    local scope_file
    local body_file
    local resp_file
    local http_code
    local current_prestage_id
    local version_lock
    local attempt
    local max_attempts

    # Determine where the serial is currently scoped (a serial can only be in
    # one PreStage scope at a time).
    all_scope_file=$(create_temp_file "all_scope")
    http_code=$(jamf_api_call "GET" "/api/v2/computer-prestages/scope" "${all_scope_file}")

    if [[ "${http_code}" -ne 200 ]]
    then
        log_error "Failed to read all PreStage scopes (HTTP ${http_code})"
        return 1
    fi

    current_prestage_id=$("${JQ}" -r --arg s "${serial}" \
        '.serialsByPrestageId[$s] // empty' "${all_scope_file}")

    if [[ "${current_prestage_id}" == "${target_prestage_id}" ]]
    then
        log_info "Serial ${serial} is already assigned to PreStage ${target_prestage_id}; nothing to do"
        return 0
    fi

    if [[ -n "${current_prestage_id}" ]]
    then
        log_info "Serial ${serial} is assigned to PreStage ${current_prestage_id}; reassigning"
        if ! remove_serial_from_prestage "${serial}" "${current_prestage_id}"
        then
            return 1
        fi
    fi

    # Add to the target PreStage scope, retrying on optimistic-lock conflicts.
    attempt=0
    max_attempts=3

    while [[ ${attempt} -lt ${max_attempts} ]]
    do
        attempt=$((attempt + 1))

        scope_file=$(create_temp_file "target_scope")
        http_code=$(jamf_api_call "GET" \
            "/api/v2/computer-prestages/${target_prestage_id}/scope" "${scope_file}")

        if [[ "${http_code}" -ne 200 ]]
        then
            log_error "Failed to read scope for PreStage ${target_prestage_id} (HTTP ${http_code})"
            return 1
        fi

        version_lock=$("${JQ}" -r '.versionLock // empty' "${scope_file}")

        if [[ -z "${version_lock}" ]]
        then
            log_error "Could not determine versionLock for PreStage ${target_prestage_id}"
            return 1
        fi

        body_file=$(create_temp_file "add_body")
        "${JQ}" -n \
            --arg s "${serial}" \
            --argjson vl "${version_lock}" \
            '{serialNumbers: [$s], versionLock: $vl}' \
            > "${body_file}"

        resp_file=$(create_temp_file "add_resp")
        http_code=$(jamf_api_call "POST" \
            "/api/v2/computer-prestages/${target_prestage_id}/scope" \
            "${resp_file}" "${body_file}")

        if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]
        then
            log_info "Serial ${serial} assigned to PreStage ${target_prestage_id}"
            return 0
        fi

        if [[ "${http_code}" -eq 409 ]]
        then
            log_warn "Optimistic-lock conflict assigning PreStage (attempt ${attempt}); retrying"
            "${SLEEP}" 1
            continue
        fi

        log_error "Failed to add serial ${serial} to PreStage ${target_prestage_id} (HTTP ${http_code})"
        return 1
    done

    log_error "Exhausted retries assigning serial ${serial} to PreStage ${target_prestage_id} (optimistic lock)"
    return 1
}

# ═══ BULK CSV INVENTORY PRELOAD ══════════════════════════════════════════════

# ── Parse a CSV into "SERIAL<TAB>ASSETTAG" rows ──────────────────────────────
# Locates columns by NORMALIZED header name (case/space/punct-insensitive), so
# "Serial Number", "SerialNumber", "serial_number" all match. Handles RFC-4180
# quoting (embedded commas, "" escapes). A blank Asset Tag falls back to the
# Computer Name when it matches ASSET_TAG_PATTERN (skipped if the pattern is ""). Valid rows go to out_tsv; a
# COUNTS line (and any ERROR) goes to counts_file. Assumes no embedded newlines.
parse_csv_to_tsv() {
    local csv_file="$1"
    local out_tsv="$2"
    local counts_file="$3"

    "${AWK}" -v tagpat="${ASSET_TAG_PATTERN}" '
    function trim(s) {
        gsub(/^[ \t\r]+/, "", s)
        gsub(/[ \t\r]+$/, "", s)
        return s
    }
    function norm(s) {
        s = tolower(s)
        gsub(/[^a-z0-9]/, "", s)
        return s
    }
    function parse_csv(line, arr,   n, i, c, field, inq, nx) {
        n = 0
        field = ""
        inq = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (inq) {
                if (c == "\"") {
                    nx = substr(line, i + 1, 1)
                    if (nx == "\"") {
                        field = field "\""
                        i++
                    } else {
                        inq = 0
                    }
                } else {
                    field = field c
                }
            } else {
                if (c == "\"") {
                    inq = 1
                } else if (c == ",") {
                    arr[++n] = field
                    field = ""
                } else {
                    field = field c
                }
            }
        }
        arr[++n] = field
        return n
    }
    NR == 1 {
        fn = parse_csv($0, hdr)
        for (i = 1; i <= fn; i++) {
            hn = norm(hdr[i])
            if (hn == "serialnumber" && sidx == 0) sidx = i
            if (hn == "assettag" && aidx == 0) aidx = i
            if (hn == "computername" && cidx == 0) cidx = i
        }
        if (sidx == 0) {
            print "ERROR: missing required column: Serial Number" > "/dev/stderr"
            exit 3
        }
        next
    }
    {
        if (trim($0) == "") next
        total++
        fn = parse_csv($0, f)
        serial = toupper(trim(f[sidx]))
        asset = (aidx > 0) ? trim(f[aidx]) : ""
        cn = (cidx > 0) ? trim(f[cidx]) : ""
        if (serial == "") {
            skip_noserial++
            next
        }
        if (asset == "" && tagpat != "") {
            u = toupper(cn)
            if (u ~ tagpat) {
                asset = u
            }
        }
        if (asset == "") {
            skip_noasset++
            next
        }
        if (seen[serial]++) {
            skip_dup++
            next
        }
        printf "%s\t%s\n", serial, asset
        emitted++
    }
    END {
        printf "COUNTS\t%d\t%d\t%d\t%d\t%d\n", total + 0, emitted + 0, skip_noserial + 0, skip_noasset + 0, skip_dup + 0 > "/dev/stderr"
    }
    ' "${csv_file}" > "${out_tsv}" 2> "${counts_file}"
}

# ── Fetch every existing Inventory Preload serial → sorted, uppercased file ──
fetch_existing_preload_serials() {
    local out_file="$1"
    local page=0
    local page_size=200
    local total=-1
    local resp_file
    local http_code
    local got

    : > "${out_file}"
    resp_file=$(create_temp_file "existing_page")

    while true
    do
        http_code=$(jamf_api_call "GET" \
            "/api/v2/inventory-preload/records?page=${page}&page-size=${page_size}" \
            "${resp_file}")

        if [[ "${http_code}" -ne 200 ]]
        then
            log_error "Failed to fetch existing Inventory Preload records (HTTP ${http_code})"
            return 1
        fi

        if [[ "${total}" -lt 0 ]]
        then
            total=$("${JQ}" -r '.totalCount // 0' "${resp_file}")
        fi

        "${JQ}" -r '(.results // [])[] | .serialNumber // empty' "${resp_file}" >> "${out_file}"

        got=$("${JQ}" -r '(.results // []) | length' "${resp_file}")
        page=$((page + 1))

        if [[ "${got}" -eq 0 || $((page * page_size)) -ge "${total}" ]]
        then
            break
        fi
    done

    # Uppercase + sort-unique for fast, case-insensitive exact membership tests.
    "${TR}" '[:lower:]' '[:upper:]' < "${out_file}" | "${AWK}" 'NF' | "${SORT}" -u > "${out_file}.tmp"
    "${MV}" "${out_file}.tmp" "${out_file}"
    log_info "Loaded $("${AWK}" 'END { print NR + 0 }' "${out_file}") existing preload serial(s)"
}

# ── Create one preload record (POST only; body/resp temp files reused) ───────
create_preload_record() {
    local serial="$1"
    local asset="$2"
    local body_file="$3"
    local resp_file="$4"
    local http_code

    "${JQ}" -n \
        --arg serial "${serial}" \
        --arg asset "${asset}" \
        '{serialNumber: $serial, deviceType: "Computer", assetTag: $asset}' \
        > "${body_file}"

    http_code=$(jamf_api_call "POST" "/api/v2/inventory-preload/records" "${resp_file}" "${body_file}")

    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]
    then
        log_error "Preload POST failed for serial ${serial} (HTTP ${http_code})"
        return 1
    fi

    log_info "Created Inventory Preload record: serial=${serial}, assetTag=${asset}"
}

# ── GUI-gated progress + reporting for bulk mode ─────────────────────────────
bulk_progress_start() {
    local total="$1"
    if [[ "${HAS_GUI}" != "true" ]]
    then
        return 0
    fi
    start_progress_dialog "Bulk Inventory Preload — processing **${total}** device(s)..." "${total}"
}

bulk_progress_update() {
    local n="$1"
    local total="$2"
    local serial="$3"
    if [[ "${HAS_GUI}" == "true" ]]
    then
        update_progress "${n}" "(${n}/${total}) ${serial}"
    fi
    if [[ $((n % 25)) -eq 0 || "${n}" -eq "${total}" ]]
    then
        log_info "Bulk progress: ${n}/${total}"
    fi
}

bulk_progress_finish() {
    if [[ "${HAS_GUI}" == "true" ]]
    then
        complete_and_close_progress
    fi
}

bulk_report_error() {
    local msg="$1"
    if [[ "${HAS_GUI}" == "true" ]]
    then
        show_error "## Bulk Preload Could Not Complete\n\n${msg}"
    fi
}

bulk_report_summary() {
    local total="$1"
    local valid="$2"
    local created="$3"
    local already="$4"
    local failed="$5"
    local no_serial="$6"
    local no_asset="$7"
    local dup="$8"

    if [[ "${HAS_GUI}" != "true" ]]
    then
        return 0
    fi

    if [[ "${failed}" -gt 0 ]]
    then
        show_error "## Bulk Preload Finished With Errors\n\n| Result | Count |\n| --- | --- |\n| ✅ Created | ${created} |\n| ⏭️ Already existed | ${already} |\n| ❌ Failed | ${failed} |\n| ⚠️ Skipped — no serial | ${no_serial} |\n| ⚠️ Skipped — no asset tag | ${no_asset} |\n| ⚠️ Skipped — duplicate in file | ${dup} |\n\nParsed **${total}** rows, **${valid}** valid. Failed serials are in the log: _${LOG_LABEL}_"
    else
        show_success "## Bulk Preload Complete ✅\n\n| Result | Count |\n| --- | --- |\n| ✅ Created | ${created} |\n| ⏭️ Already existed | ${already} |\n| ⚠️ Skipped — no serial | ${no_serial} |\n| ⚠️ Skipped — no asset tag | ${no_asset} |\n| ⚠️ Skipped — duplicate in file | ${dup} |\n\nParsed **${total}** rows, **${valid}** valid. New records apply at each device's next enrollment."
    fi
}

# ── Bulk orchestrator: parse CSV → skip existing → create new → report ───────
run_bulk_preload() {
    local csv_file="$1"
    local tsv
    local counts_file
    local existing_file
    local body_file
    local resp_file
    local total=0
    local emitted=0
    local skip_noserial=0
    local skip_noasset=0
    local skip_dup=0
    local created=0
    local already=0
    local failed=0
    local processed=0
    local serial
    local asset
    local err

    if [[ ! -f "${csv_file}" || ! -r "${csv_file}" ]]
    then
        log_error "CSV file not found or unreadable: ${csv_file}"
        bulk_report_error "The CSV file could not be read:\n\n\`${csv_file}\`"
        return 1
    fi

    tsv=$(create_temp_file "bulk_tsv")
    counts_file=$(create_temp_file "bulk_counts")

    if ! parse_csv_to_tsv "${csv_file}" "${tsv}" "${counts_file}"
    then
        err=""
        if "${GREP}" -q '^ERROR' "${counts_file}"
        then
            err=$("${GREP}" -m1 '^ERROR' "${counts_file}")
        fi
        log_error "CSV parse failed: ${err:-unknown error}"
        bulk_report_error "The CSV could not be parsed.\n\nMake sure it has a **Serial Number** column."
        return 1
    fi

    if ! IFS=$'\t' read -r _ total emitted skip_noserial skip_noasset skip_dup < <("${GREP}" '^COUNTS' "${counts_file}")
    then
        total=0
        emitted=0
    fi

    log_info "CSV parsed: rows=${total}, valid=${emitted}, no-serial=${skip_noserial}, no-assettag=${skip_noasset}, duplicates=${skip_dup}"

    if [[ "${emitted}" -eq 0 ]]
    then
        bulk_report_error "No valid rows to import.\n\nParsed **${total}** rows — none had both a serial and a resolvable asset tag."
        return 1
    fi

    existing_file=$(create_temp_file "existing_serials")
    if ! fetch_existing_preload_serials "${existing_file}"
    then
        bulk_report_error "Could not read existing Inventory Preload records from Jamf. Please retry or contact IT."
        return 1
    fi

    body_file=$(create_temp_file "bulk_body")
    resp_file=$(create_temp_file "bulk_resp")

    bulk_progress_start "${emitted}"

    while IFS=$'\t' read -r serial asset
    do
        processed=$((processed + 1))
        bulk_progress_update "${processed}" "${emitted}" "${serial}"

        if "${GREP}" -Fxq "${serial}" "${existing_file}"
        then
            already=$((already + 1))
            continue
        fi

        if create_preload_record "${serial}" "${asset}" "${body_file}" "${resp_file}"
        then
            created=$((created + 1))
        else
            failed=$((failed + 1))
        fi
    done < "${tsv}"

    bulk_progress_finish

    log_info "Bulk preload complete: created=${created}, already-existed=${already}, failed=${failed}"

    bulk_report_summary "${total}" "${emitted}" "${created}" "${already}" "${failed}" \
        "${skip_noserial}" "${skip_noasset}" "${skip_dup}"

    if [[ "${failed}" -gt 0 ]]
    then
        return 1
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

# ── Preflight ────────────────────────────────────────────────────────────────
require_param "API Client ID (\$4)" "${JAMF_CLIENT_ID}"
require_param "API Client Secret (\$5)" "${JAMF_CLIENT_SECRET}"
require_jq
require_jamf_url

# ── Resolve the console user (needed only for swiftDialog UI) ────────────────
HAS_GUI="false"
if CURRENT_USER=$(get_current_user)
then
    CONSOLE_UID=$(get_current_user_uid "${CURRENT_USER}")
    HAS_GUI="true"
    DIALOG_CMD_FILE=$(create_temp_file "dialog_cmd")
    "${CHMOD}" 644 "${DIALOG_CMD_FILE}"
    log_info "Console user ${CURRENT_USER} (uid ${CONSOLE_UID}); GUI available"
else
    CURRENT_USER=""
    CONSOLE_UID=""
    log_info "No console user detected; running headless (no dialogs)"
fi

if [[ "${HAS_GUI}" == "true" && ! -x "${DIALOG_BIN}" ]]
then
    log_warn "swiftDialog not found at ${DIALOG_BIN}; disabling GUI"
    HAS_GUI="false"
fi

# ── Authenticate to Jamf Pro ─────────────────────────────────────────────────
if ! get_jamf_access_token
then
    show_error "Could not authenticate to Jamf Pro. Please contact IT.\n\n_(OAuth token request failed — check the API client credentials.)_"
    exit 1
fi

# ── Headless / parameterized bulk mode (Parameter 8 = CSV path) ──────────────
if [[ -n "${CSV_PATH_PARAM}" ]]
then
    log_info "Bulk mode: CSV path from Parameter 8 → ${CSV_PATH_PARAM}"
    if run_bulk_preload "${CSV_PATH_PARAM}"
    then
        log_info "${SCRIPT_NAME} completed successfully"
        exit 0
    fi
    exit 1
fi

# ── Everything below is interactive and needs a GUI ──────────────────────────
if [[ "${HAS_GUI}" != "true" ]]
then
    log_error "No GUI (console user + swiftDialog) and no CSV path (Parameter 8) — nothing to do"
    exit 1
fi

PRESTAGE_IDS_FILE=$(create_temp_file "prestage_ids")

# ── Build the Device Type dropdown for the active mode ───────────────────────
if [[ "${ADMIN_MODE}" == "true" ]]
then
    log_info "Admin mode: showing all PreStages"
else
    log_info "Support mode: showing curated device type list"
fi

if ! build_dropdown_values
then
    show_error "Could not load the device type list from Jamf Pro. Please contact IT."
    exit 1
fi

# ── Present the registration form (single device or bulk CSV) ────────────────
DIALOG_OUTPUT=$(create_temp_file "dialog_output")

if ! show_registration_form "${DIALOG_OUTPUT}" "${DROPDOWN_VALUES}"
then
    log_info "User cancelled the registration form"
    exit 0
fi

# ── Bulk path: a CSV was chosen/dropped in the form ──────────────────────────
CSV_FIELD=$("${JQ}" -r '."Bulk CSV" // ""' "${DIALOG_OUTPUT}")
if [[ -n "${CSV_FIELD}" ]]
then
    log_info "Bulk mode: CSV chosen in dialog → ${CSV_FIELD}"
    if run_bulk_preload "${CSV_FIELD}"
    then
        log_info "${SCRIPT_NAME} completed successfully"
        exit 0
    fi
    exit 1
fi

# ── Single-device path — parse and validate ──────────────────────────────────
ASSET_TAG=$("${JQ}" -r '."Asset Tag" // ""' "${DIALOG_OUTPUT}")
SERIAL_NUMBER=$("${JQ}" -r '."Serial Number" // ""' "${DIALOG_OUTPUT}")
# Normalize the manually-entered serial to uppercase (bash 3.2 has no ${x^^}).
SERIAL_NUMBER=$(printf '%s' "${SERIAL_NUMBER}" | "${TR}" '[:lower:]' '[:upper:]')
SELECTED_INDEX=$("${JQ}" -r '(.SelectedIndex // ."Device Type".selectedIndex // -1)' "${DIALOG_OUTPUT}")
SELECTED_VALUE=$("${JQ}" -r '(.SelectedOption // ."Device Type".selectedValue // "")' "${DIALOG_OUTPUT}")

if [[ -z "${ASSET_TAG}" ]]
then
    show_error "No asset tag was entered and no CSV was chosen. Fill in the single-device fields, or pick a CSV for bulk import."
    exit 1
fi

if [[ -z "${SERIAL_NUMBER}" ]]
then
    show_error "No serial number was provided. Please run the registration again."
    exit 1
fi

# Serials are alphanumeric; reject anything else before it is placed in an
# RSQL filter in the Jamf API query string.
if [[ ! "${SERIAL_NUMBER}" =~ ^[A-Z0-9]+$ ]]
then
    log_error "Serial number contains invalid characters: ${SERIAL_NUMBER}"
    show_error "The serial number may only contain letters and numbers. Please check it and try again."
    exit 1
fi

# Index 0 is the "Select a device type" placeholder; a real choice is >= 1.
if [[ -z "${SELECTED_INDEX}" || "${SELECTED_INDEX}" -lt 1 ]]
then
    show_error "No device type was selected. Please choose one and try again."
    exit 1
fi

# ── Resolve the selected device type to a PreStage id (placeholder at index 0)─
if [[ "${ADMIN_MODE}" == "true" ]]
then
    # Placeholder occupies index 0, so selection N maps to ids-file line N.
    PRESTAGE_NAME="${SELECTED_VALUE}"
    PRESTAGE_ID=$("${SED}" -n "${SELECTED_INDEX}p" "${PRESTAGE_IDS_FILE}")

    if [[ -z "${PRESTAGE_ID}" ]]
    then
        log_error "Could not map selected index ${SELECTED_INDEX} to a PreStage id"
        show_error "Something went wrong selecting the device type. Please contact IT."
        exit 1
    fi
else
    # Placeholder at index 0, so selection N maps to curated element N-1.
    if [[ "${SELECTED_INDEX}" -gt "${#CURATED_DEVICE_TYPES[@]}" ]]
    then
        log_error "Selected index ${SELECTED_INDEX} is out of range for the curated list"
        show_error "Something went wrong selecting the device type. Please contact IT."
        exit 1
    fi

    PRESTAGE_NAME="${CURATED_DEVICE_TYPES[$((SELECTED_INDEX - 1))]}"

    if ! lookup_prestage_id_by_name "${PRESTAGE_NAME}"
    then
        show_error "The selected device type (**${PRESTAGE_NAME}**) could not be matched to a PreStage in Jamf Pro.\n\nThe curated list may be out of sync with Jamf. Please contact IT."
        exit 1
    fi
fi

log_info "Single-device input — assetTag='${ASSET_TAG}', serial='${SERIAL_NUMBER}', deviceType='${PRESTAGE_NAME}' (PreStage id ${PRESTAGE_ID})"

# ── Execute the registration with a progress dialog ──────────────────────────
start_progress_dialog "Registering **${SERIAL_NUMBER}** with Jamf Pro..." 2

update_progress 1 "Saving Inventory Preload record (asset tag ${ASSET_TAG})..."
if ! upsert_inventory_preload "${SERIAL_NUMBER}" "${ASSET_TAG}"
then
    close_progress_dialog
    show_error "## Registration Failed\n\nThe **Inventory Preload** step did not complete for serial **${SERIAL_NUMBER}**.\n\nNo device type change was made. Please retry or contact IT.\n\n_See unified log: ${LOG_LABEL}_"
    exit 1
fi

update_progress 2 "Applying device type (${PRESTAGE_NAME})..."
if ! assign_prestage "${SERIAL_NUMBER}" "${PRESTAGE_ID}"
then
    close_progress_dialog
    show_error "## Partially Completed\n\nThe Inventory Preload record was saved, but applying the **device type** failed for serial **${SERIAL_NUMBER}**.\n\nPlease retry or contact IT.\n\n_See unified log: ${LOG_LABEL}_"
    exit 1
fi

complete_and_close_progress

# ── Success ──────────────────────────────────────────────────────────────────
show_success "## Registration Complete ✅\n\nThis Mac is ready for its next enrollment.\n\n| Field | Value |\n| --- | --- |\n| **Asset Tag** | ${ASSET_TAG} |\n| **Serial Number** | ${SERIAL_NUMBER} |\n| **Device Type** | ${PRESTAGE_NAME} |\n\nThe asset tag and device type take effect the next time this device is wiped and re-enrolled via Automated Device Enrollment."

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

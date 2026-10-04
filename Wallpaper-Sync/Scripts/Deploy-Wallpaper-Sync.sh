#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Deploy-Wallpaper-Sync.sh
# Author: Heath Jones
# Date: 07-02-2026
# Modified: 10-04-2026
# Purpose: Jamf policy installer (runs as root). Writes the user-context
#          Wallpaper-Sync.sh and its LaunchAgent plist to disk via heredocs,
#          then bootstraps the agent into the logged-in user's GUI session.
#          Self-contained: one Jamf Script payload, no companion pkg/plist.
# Version: 1.0 - Initial Script
# Version: 1.1 - Fixed RunAtLoad never firing: launchd does not reliably expand
#                '~' in WatchPaths/StandardOutPath/StandardErrorPath, so an
#                unresolved tilde made launchd refuse to spawn the job. Agent is
#                now installed PER-USER into ~/Library/LaunchAgents with the
#                user's LITERAL home path. Added resolve_user_home(),
#                cleanup_legacy_agent() to remove the old shared
#                /Library/LaunchAgents copy, and a launchctl kickstart after
#                bootstrap. Updated do_install/do_uninstall/do_status for the
#                per-user plist path.
# Version: 1.2 - Fixed WatchPaths never re-firing on macOS 14+: the wallpaper is
#                no longer stored in Dock/desktoppicture.db (frozen since the
#                Sonoma wallpaper rewrite). Now watch
#                com.apple.wallpaper/Store/Index.plist as well, keeping the
#                legacy DB for macOS 13 coverage (harmless no-op on newer OSes).
# Version: 1.3 - Added optional MANAGED_ONLY mode (off by default): when enabled,
#                only wallpapers whose source file lives under
#                MANAGED_WALLPAPER_DIR are synced, locking the JCL background to
#                corporate wallpapers. Embedded Wallpaper-Sync.sh bumped to v1.1.
# Version: 1.4 - Fixed intermittent JCL background: the written file inherited
#                mktemp's 0600 mode (root-only readable), so the loginwindow
#                context read it inconsistently. Now chmod 644 the staged file
#                before the atomic move. Embedded Wallpaper-Sync.sh bumped to v1.2.
# Version: 1.5 - Fixed the wrong (default) wallpaper being synced: macOS injects
#                a transient "default" wallpaper during login/wallpaper changes,
#                which the agent captured mid-flash. Added a settle loop
#                (detect_settled_wallpaper) that waits for desktoppr to report
#                the same value twice before syncing. Embedded Wallpaper-Sync.sh
#                bumped to v1.3.
# Version: 1.6 - Settle loop alone was insufficient at the login/logout boundary,
#                where the default wallpaper is STABLE for seconds (not a flash).
#                Added a denylist (IGNORE_WALLPAPER_PREFIXES + is_ignored_wallpaper)
#                that skips syncing macOS default/stock wallpapers entirely,
#                leaving the last real wallpaper on the JCL background. Embedded
#                Wallpaper-Sync.sh bumped to v1.4.
# Version: 1.7 - Public release prep: sanitized identifiers, expert-bash
#                conformance. Org identity reset to template placeholders;
#                JCL/managed wallpaper paths now derive from ORG_NAME
#                (CHANGE_ME). Fixed malformed shellcheck directive (SC1125
#                silently voided the SC2230 disable). bash -n now called via
#                a $(which) binary var. Added Requirements + check_dependencies
#                preflight. Embedded Wallpaper-Sync.sh bumped to v1.5: render
#                step sets a global instead of having a logging function's
#                stdout captured; '|| log_warn' fallbacks rewritten as if-blocks.
# Version: 1.8 - Renamed to Name-Of-Script.sh convention (this file and the
#                deployed agent script, now Wallpaper-Sync.sh). do_install
#                removes the pre-rename agent script from INSTALL_DIR on
#                upgrade. Embedded Wallpaper-Sync.sh bumped to v1.6.
#
# Requirements:
#   - Runs as root (Jamf policy); a logged-in console user is needed to
#     install the per-user LaunchAgent (otherwise only the sync script is
#     written and a warning is logged)
#   - desktoppr at /usr/local/bin/desktoppr (installer warns if missing; the
#     deployed agent aborts at runtime without it)
#   - JCL_BACKGROUND_DIR must exist, be writable by standard users, and match
#     the Jamf Connect Login BackgroundImage key (installer warns if missing)
#   - ORG_NAME_FRIENDLY / ORG_PLIST_DOMAIN edited from the template defaults
#     (validate_config refuses to run otherwise)
#   - Jamf parameter $4 (optional): mode - install (default) | uninstall | status
#   - Companion: Managed Login Items profile (com.apple.servicemanagement)
#     matching the agent Label, delivered by MDM
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

# File-wide directives (placed before the first command so they apply to the
# whole file): `which` is preferred over `command -v` per the style guide
# (SC2230); readonly/local declare-and-assign is the template convention for
# binary paths and log lines (SC2155); awk programs are intentionally
# single-quoted (SC2016).
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
# Template core binary; unused by the installer itself.
# shellcheck disable=SC2034
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
#   >>> EDIT ME <<< — this is the SINGLE source of truth. These values are
#   interpolated into both the sync script and the LaunchAgent plist written
#   below, so the Label / paths / log location all stay in sync automatically.
#   validate_config() refuses to run while these are still the template defaults.
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: your org display name
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"      # CHANGE_ME: your org reverse-DNS prefix

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.8"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"
# Template variable, reserved for future use.
# shellcheck disable=SC2034
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
readonly CAT=$(which cat)
readonly CHOWN=$(which chown)
readonly CHMOD=$(which chmod)
readonly MKDIR=$(which mkdir)
readonly PLUTIL=$(which plutil)
readonly LAUNCHCTL=$(which launchctl)
readonly SCUTIL=$(which scutil)
readonly DSCL=$(which dscl)
readonly BASH_BIN=$(which bash)

# desktoppr is third-party and outside the stock PATH set, so its full path is
# assigned directly. The installer only checks for it; the agent invokes it.
readonly DESKTOPPR_BIN="/usr/local/bin/desktoppr"

# ─────────────────────────────────────────────────────────────────────────────
# >>> EDIT ME <<< — JCL BACKGROUND DESTINATION
# These MUST match the `BackgroundImage` value in your Jamf Connect Login
# configuration profile. The directory's permissions must already be loosened
# (done separately) so the user-context agent can write here.
# ─────────────────────────────────────────────────────────────────────────────
readonly JCL_BACKGROUND_DIR="/Library/Application Support/${ORG_NAME}/JamfConnect/Backgrounds"    # CHANGE_ME: dir your JCL BackgroundImage points into
readonly JCL_BACKGROUND_FILENAME="Jamf_Connect_Login_Background.png"                               # CHANGE_ME: exact filename JCL expects

# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL — MANAGED-ONLY MODE (off by default)
# When MANAGED_ONLY="true", the sync only fires if the user's CURRENT wallpaper
# is a file living under MANAGED_WALLPAPER_DIR (a corporate/managed path). Any
# personal wallpaper is ignored, so the JCL login background stays locked to the
# last corporate wallpaper. When "false" (default), any wallpaper syncs.
# Accepts exactly "true" to enable; anything else is treated as disabled.
# ─────────────────────────────────────────────────────────────────────────────
readonly MANAGED_ONLY="false"
readonly MANAGED_WALLPAPER_DIR="/Library/Application Support/${ORG_NAME}/Wallpapers"    # CHANGE_ME: your managed wallpaper directory

# ── Derived install paths (do not normally need editing) ─────────────────────
readonly INSTALL_DIR="/Library/Application Support/${ORG_NAME}/WallpaperSync"
readonly INSTALL_SCRIPT_PATH="${INSTALL_DIR}/Wallpaper-Sync.sh"
# Pre-rename (installer <= v1.7) agent script filename, removed on upgrade.
readonly LEGACY_INSTALL_SCRIPT_PATH="${INSTALL_DIR}/wallpaperSync.sh"
readonly AGENT_LABEL="${ORG_PLIST_DOMAIN}.wallpapersync.agent"
readonly AGENT_PLIST_FILENAME="${AGENT_LABEL}.plist"
# The LaunchAgent is installed PER-USER into ~/Library/LaunchAgents with the
# user's LITERAL home path baked into WatchPaths/Std paths — launchd does NOT
# reliably expand '~' in those keys, and an unresolved tilde makes launchd
# refuse to spawn the job (RunAtLoad never fires). Full path resolved at runtime.

# ── Jamf parameters ($1-$3 reserved by Jamf: mount, computer name, username) ──
# $4 optional mode override: install (default) | uninstall | status
readonly PARAM_MODE="${4:-}"

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
        log_error "Must run as root (Jamf policy context)"
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

# ── Refuse to deploy with placeholder org identity still in place ────────────
validate_config() {
    if [[ "${ORG_PLIST_DOMAIN}" == "com.company" || "${ORG_NAME_FRIENDLY}" == "Company Name" ]]
    then
        log_error "Org identity still set to placeholder values — edit ORG_NAME_FRIENDLY and ORG_PLIST_DOMAIN before deploying"
        exit 1
    fi
}

# ── Requirements preflight (warn-only; see Requirements in the header) ───────
# Neither dependency blocks install: the agent re-checks desktoppr at runtime
# and ensure_dest_dir() re-checks the JCL directory on every sync.
check_dependencies() {
    if [[ ! -x "${DESKTOPPR_BIN}" ]]
    then
        log_warn "desktoppr not found at ${DESKTOPPR_BIN} — the agent will install but abort at runtime until it is deployed"
    fi

    if [[ ! -d "${JCL_BACKGROUND_DIR}" ]]
    then
        log_warn "JCL background directory does not exist yet: ${JCL_BACKGROUND_DIR} — create it (user-writable) and match your JCL BackgroundImage key"
    fi
}

# ── Resolve the current console user (empty if none / at loginwindow) ─────────
get_console_user() {
    local console_user

    console_user=$("${SCUTIL}" <<< "show State:/Users/ConsoleUser" | "${AWK}" '/Name :/ { print $3 }')

    case "${console_user}" in
        ""|"loginwindow"|"root"|"_mbsetupuser")
            printf ''
            ;;
        *)
            printf '%s' "${console_user}"
            ;;
    esac
}

# ── Resolve a user's home directory (empty if not found) ─────────────────────
resolve_user_home() {
    local user="$1"

    "${DSCL}" . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | "${AWK}" '{ print $2 }'
}

# ── Remove any legacy /Library/LaunchAgents copy from pre-per-user builds ─────
# Early builds installed a shared /Library/LaunchAgents plist with '~' paths
# that launchd could not resolve. Boot it out and delete it so it can't shadow
# the per-user copy or sit broken.
cleanup_legacy_agent() {
    local console_user="$1"
    local uid
    local legacy_path="/Library/LaunchAgents/${AGENT_PLIST_FILENAME}"

    if [[ -n "${console_user}" ]]
    then
        uid=$("${ID}" -u "${console_user}" 2>/dev/null || printf '')
        if [[ -n "${uid}" ]] && "${LAUNCHCTL}" print "gui/${uid}/${AGENT_LABEL}" >/dev/null 2>&1
        then
            "${LAUNCHCTL}" bootout "gui/${uid}/${AGENT_LABEL}" 2>/dev/null || true
        fi
    fi

    if [[ -f "${legacy_path}" ]]
    then
        "${RM}" -f "${legacy_path}"
        log_info "Removed legacy shared LaunchAgent: ${legacy_path}"
    fi
}

# ── Write the user-context sync script (config header + literal body) ────────
# The config header is an UNQUOTED heredoc so the installer's org/JCL constants
# are interpolated in. The body is a SINGLE-QUOTED heredoc so the sync script's
# own ${...} expansions stay literal and evaluate at the agent's runtime.
write_sync_script() {
    "${MKDIR}" -p "${INSTALL_DIR}"

    "${CAT}" > "${INSTALL_SCRIPT_PATH}" <<SYNC_CONFIG_EOF
#! /bin/bash
# shellcheck disable=SC2230,SC2155,SC2016

######################################################################
# Name: Wallpaper-Sync.sh  (deployed by ${SCRIPT_NAME} v${SCRIPT_VERSION})
# Purpose: Sync the JCL login background to the user's current wallpaper.
#          Runs in USER context via a WatchPaths LaunchAgent. Do not edit
#          on-disk — edit the deploy installer and re-run the Jamf policy.
######################################################################

set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ===== Config injected at install time by ${SCRIPT_NAME} =====
readonly ORG_NAME_FRIENDLY="${ORG_NAME_FRIENDLY}"
readonly ORG_PLIST_DOMAIN="${ORG_PLIST_DOMAIN}"
readonly JCL_BACKGROUND_DIR="${JCL_BACKGROUND_DIR}"
readonly JCL_BACKGROUND_FILENAME="${JCL_BACKGROUND_FILENAME}"
readonly MANAGED_ONLY="${MANAGED_ONLY}"
readonly MANAGED_WALLPAPER_DIR="${MANAGED_WALLPAPER_DIR}"
SYNC_CONFIG_EOF

    "${CAT}" >> "${INSTALL_SCRIPT_PATH}" <<'SYNC_BODY_EOF'

# ── Core binary paths ────────────────────────────────────────────────────────
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# ── Task-specific binary paths ───────────────────────────────────────────────
readonly SIPS=$(which sips)
readonly CP=$(which cp)
readonly MV=$(which mv)
readonly CHMOD=$(which chmod)
readonly MKDIR=$(which mkdir)
readonly STAT=$(which stat)
readonly SHASUM=$(which shasum)
readonly HEAD=$(which head)
readonly SLEEP=$(which sleep)
readonly DESKTOPPR="/usr/local/bin/desktoppr"

# ── Derived identity / paths ─────────────────────────────────────────────────
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.6"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"

readonly JCL_BACKGROUND_PATH="${JCL_BACKGROUND_DIR}/${JCL_BACKGROUND_FILENAME}"

readonly LOG_DIR="${HOME}/Library/Logs/${ORG_NAME}"
readonly LOG_FILE="${LOG_DIR}/wallpaperSync.log"

readonly STATE_DIR="${HOME}/Library/Application Support/${ORG_NAME}/WallpaperSync"
readonly STATE_FILE="${STATE_DIR}/last_source.state"

# Settle window — macOS briefly injects a "default" wallpaper during login and
# wallpaper changes, so we wait for desktoppr to report the SAME value twice
# before acting. Increase SETTLE_SECS if the default flash lasts longer on your
# fleet. Worst-case added latency = SETTLE_SECS * SETTLE_MAX_TRIES.
readonly WALLPAPER_SETTLE_SECS="2"
readonly WALLPAPER_SETTLE_MAX_TRIES="4"

# Source-path prefixes to NEVER sync (macOS default / stock wallpapers). At
# early login and at logout, macOS reports the DEFAULT wallpaper as the current
# one — and it's stable for several seconds, so the settle loop alone can't tell
# it apart from a real choice. Any wallpaper whose resolved source path starts
# with one of these prefixes is ignored: we skip and leave the existing JCL
# background in place. If your default resolves somewhere not listed here, read
# the "Current wallpaper:" line in the log and add that prefix.
IGNORE_WALLPAPER_PREFIXES=(
    "/System/Library/"
    "/Library/Desktop Pictures/"
    "/Library/Application Support/com.apple.idleassetsd/"
)

declare -a TEMP_FILES=()

# Set by render_to_temp_png() — a global, so the caller never has to capture
# the stdout of a function that also logs.
RENDERED_PNG=""

# ── Logging (per-user; this agent runs as the user, never root) ──────────────
log_info() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    if ! printf '%s\n' "${log_msg}" | tee -ai "${LOG_FILE}" >/dev/null 2>&1
    then
        printf '%s\n' "${log_msg}"
    fi
}

log_warn() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    if ! printf '%s\n' "${log_msg}" | tee -ai "${LOG_FILE}" >/dev/null 2>&1
    then
        printf '%s\n' "${log_msg}"
    fi
}

log_error() {
    local log_msg
    log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    if ! printf '%s\n' "${log_msg}" | tee -ai "${LOG_FILE}" >/dev/null 2>&1
    then
        printf '%s\n' "${log_msg}"
    fi
}

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

refuse_root() {
    if [[ "$("${ID}" -u)" -eq 0 ]]
    then
        log_error "This agent must run in user context, not as root. Aborting."
        exit 1
    fi
}

ensure_log_dir() {
    if [[ ! -d "${LOG_DIR}" ]]
    then
        "${MKDIR}" -p "${LOG_DIR}" 2>/dev/null || true
    fi
}

detect_wallpaper() {
    "${DESKTOPPR}" 2>/dev/null | "${HEAD}" -n 1
}

# ── Is the given wallpaper file under the managed/corporate directory? ────────
is_managed_wallpaper() {
    local wp="$1"
    local dir="${MANAGED_WALLPAPER_DIR%/}"

    if [[ "${wp}" == "${dir}/"* ]]
    then
        return 0
    fi
    return 1
}

# ── Is the wallpaper a macOS default/stock image we should never sync? ────────
is_ignored_wallpaper() {
    local wp="$1"
    local prefix

    if [[ ${#IGNORE_WALLPAPER_PREFIXES[@]} -eq 0 ]]
    then
        return 1
    fi

    for prefix in "${IGNORE_WALLPAPER_PREFIXES[@]}"
    do
        if [[ "${wp}" == "${prefix}"* ]]
        then
            return 0
        fi
    done
    return 1
}

# ── Read the wallpaper, then wait until it stops changing before returning ────
# macOS injects a transient "default" wallpaper during login and wallpaper
# changes; acting on it copies the wrong image into the JCL background. We poll
# desktoppr until two consecutive reads agree (or we exhaust the retries), so a
# brief flash never gets synced. Stays SILENT — its stdout is the return value.
detect_settled_wallpaper() {
    local prev
    local current
    local tries=0

    prev=$(detect_wallpaper)

    while [[ ${tries} -lt ${WALLPAPER_SETTLE_MAX_TRIES} ]]
    do
        "${SLEEP}" "${WALLPAPER_SETTLE_SECS}"
        current=$(detect_wallpaper)

        if [[ -n "${current}" && "${current}" == "${prev}" ]]
        then
            printf '%s' "${current}"
            return 0
        fi

        prev="${current}"
        tries=$((tries + 1))
    done

    printf '%s' "${prev}"
}

source_signature() {
    local f="$1"
    local meta

    meta=$("${STAT}" -f '%z:%m' "${f}" 2>/dev/null || printf 'unknown')
    printf '%s|%s' "${f}" "${meta}"
}

file_hash() {
    local f="$1"

    "${SHASUM}" -a 256 "${f}" 2>/dev/null | "${AWK}" '{ print $1 }'
}

ensure_dest_dir() {
    if [[ -d "${JCL_BACKGROUND_DIR}" ]]
    then
        return 0
    fi

    log_warn "JCL background directory missing, attempting to create: ${JCL_BACKGROUND_DIR}"
    if "${MKDIR}" -p "${JCL_BACKGROUND_DIR}" 2>/dev/null
    then
        return 0
    fi

    log_error "Could not create JCL background directory (permissions?): ${JCL_BACKGROUND_DIR}"
    return 1
}

render_to_temp_png() {
    local source="$1"
    local out_png

    RENDERED_PNG=""
    out_png=$("${MKTEMP}" -t wallpaperSync)
    TEMP_FILES+=("${out_png}")

    if "${SIPS}" -s format png "${source}" --out "${out_png}" >/dev/null 2>&1
    then
        RENDERED_PNG="${out_png}"
        return 0
    fi

    log_warn "sips conversion failed, falling back to a raw copy of the source"
    if "${CP}" "${source}" "${out_png}" >/dev/null 2>&1
    then
        RENDERED_PNG="${out_png}"
        return 0
    fi

    log_error "Both sips conversion and raw copy failed for: ${source}"
    return 1
}

install_background() {
    local rendered="$1"
    local dest_tmp="${JCL_BACKGROUND_DIR}/.wallpaperSync.tmp.$$"

    TEMP_FILES+=("${dest_tmp}")

    if ! "${CP}" "${rendered}" "${dest_tmp}" >/dev/null 2>&1
    then
        log_error "Failed to stage image into JCL directory (permissions loosened?): ${dest_tmp}"
        return 1
    fi

    # Force world-readable mode. The source temp comes from mktemp (0600), which
    # cp carries over — a 0600 JCL background is only readable by root, so the
    # loginwindow context reads it inconsistently. 644 makes it deterministic.
    if ! "${CHMOD}" 644 "${dest_tmp}" 2>/dev/null
    then
        log_warn "Could not chmod 644 the staged JCL background: ${dest_tmp}"
    fi

    if ! "${MV}" -f "${dest_tmp}" "${JCL_BACKGROUND_PATH}" >/dev/null 2>&1
    then
        log_error "Failed to move staged image into place: ${JCL_BACKGROUND_PATH}"
        return 1
    fi

    return 0
}

write_state() {
    local sig="$1"

    if [[ ! -d "${STATE_DIR}" ]]
    then
        "${MKDIR}" -p "${STATE_DIR}" 2>/dev/null || true
    fi
    if ! printf '%s' "${sig}" > "${STATE_FILE}" 2>/dev/null
    then
        log_warn "Could not persist state file: ${STATE_FILE}"
    fi
}

sync_wallpaper() {
    local current_wallpaper
    local current_sig
    local last_sig
    local rendered

    # Wait for the wallpaper to settle so we never capture the transient macOS
    # "default" flash that appears during login and wallpaper changes.
    current_wallpaper=$(detect_settled_wallpaper)

    if [[ -z "${current_wallpaper}" ]]
    then
        log_warn "desktoppr returned no wallpaper path — nothing to sync"
        return 0
    fi

    if [[ ! -f "${current_wallpaper}" ]]
    then
        log_error "Detected wallpaper path does not exist on disk: ${current_wallpaper}"
        return 1
    fi

    log_info "Current wallpaper: ${current_wallpaper}"

    # Never sync the macOS default/stock wallpaper. This is what appears at
    # early login and at logout; skipping it keeps the last real wallpaper on
    # the JCL login background instead of flipping it to the default.
    if is_ignored_wallpaper "${current_wallpaper}"
    then
        log_info "Ignoring system/default wallpaper (${current_wallpaper}) — leaving JCL background unchanged"
        return 0
    fi

    # Managed-only mode: skip anything that isn't a corporate/managed wallpaper,
    # leaving the existing JCL background locked in place.
    if [[ "${MANAGED_ONLY}" == "true" ]]
    then
        if ! is_managed_wallpaper "${current_wallpaper}"
        then
            log_info "Managed-only mode: wallpaper is not under ${MANAGED_WALLPAPER_DIR} — leaving JCL background unchanged"
            return 0
        fi
        log_info "Managed-only mode: wallpaper is managed — proceeding"
    fi

    current_sig=$(source_signature "${current_wallpaper}")

    if [[ -f "${STATE_FILE}" && -f "${JCL_BACKGROUND_PATH}" ]]
    then
        last_sig="$(< "${STATE_FILE}")"
        if [[ "${last_sig}" == "${current_sig}" ]]
        then
            log_info "Wallpaper unchanged since last sync — skipping"
            return 0
        fi
    fi

    if ! ensure_dest_dir
    then
        return 1
    fi

    if ! render_to_temp_png "${current_wallpaper}"
    then
        return 1
    fi
    rendered="${RENDERED_PNG}"
    if [[ -z "${rendered}" || ! -f "${rendered}" ]]
    then
        return 1
    fi

    if [[ -f "${JCL_BACKGROUND_PATH}" ]]
    then
        if [[ "$(file_hash "${rendered}")" == "$(file_hash "${JCL_BACKGROUND_PATH}")" ]]
        then
            log_info "Rendered image matches existing JCL background — skipping write"
            write_state "${current_sig}"
            return 0
        fi
    fi

    if ! install_background "${rendered}"
    then
        return 1
    fi

    write_state "${current_sig}"
    log_info "JCL background updated: ${JCL_BACKGROUND_PATH}"
    return 0
}

# ── Run ──────────────────────────────────────────────────────────────────────
ensure_log_dir

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting"

refuse_root

if [[ ! -x "${DESKTOPPR}" ]]
then
    log_error "desktoppr not found or not executable at ${DESKTOPPR} — cannot detect wallpaper. Aborting."
    exit 1
fi

sync_wallpaper

log_info "${SCRIPT_NAME} completed successfully"
SYNC_BODY_EOF

    "${CHOWN}" root:wheel "${INSTALL_SCRIPT_PATH}"
    "${CHMOD}" 755 "${INSTALL_SCRIPT_PATH}"

    if ! "${BASH_BIN}" -n "${INSTALL_SCRIPT_PATH}"
    then
        log_error "Generated Wallpaper-Sync.sh failed bash -n syntax check"
        return 1
    fi

    log_info "Wrote sync script: ${INSTALL_SCRIPT_PATH}"
    return 0
}

# ── Write the LaunchAgent plist into the user's ~/Library/LaunchAgents ───────
# Literal home path (no '~') in WatchPaths/Std paths so launchd can resolve them
# and actually honor RunAtLoad + arm the watch.
write_agent_plist() {
    local console_user="$1"
    local user_home="$2"
    local agents_dir="${user_home}/Library/LaunchAgents"
    local log_dir="${user_home}/Library/Logs/${ORG_NAME}"
    local plist_path="${agents_dir}/${AGENT_PLIST_FILENAME}"

    "${MKDIR}" -p "${agents_dir}" 2>/dev/null || true
    "${MKDIR}" -p "${log_dir}" 2>/dev/null || true

    "${CAT}" > "${plist_path}" <<AGENT_PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_SCRIPT_PATH}</string>
    </array>
    <!--
        Fire the agent when the wallpaper changes. macOS 14+ (Sonoma/Sequoia/
        Tahoe) NO LONGER updates Dock/desktoppicture.db on a wallpaper change —
        it writes com.apple.wallpaper/Store/Index.plist instead. Watch both so
        one agent covers the whole fleet; on newer OSes the legacy DB is simply
        a harmless no-op watch, and on macOS 13 the modern path is absent (also
        a no-op until/if it appears).
    -->
    <key>WatchPaths</key>
    <array>
        <string>${user_home}/Library/Application Support/com.apple.wallpaper/Store/Index.plist</string>
        <string>${user_home}/Library/Application Support/Dock/desktoppicture.db</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_dir}/wallpaperSync.agent.out.log</string>
    <key>StandardErrorPath</key>
    <string>${log_dir}/wallpaperSync.agent.err.log</string>
</dict>
</plist>
AGENT_PLIST_EOF

    "${CHMOD}" 644 "${plist_path}"
    "${CHOWN}" "${console_user}" "${plist_path}" 2>/dev/null || true
    "${CHOWN}" -R "${console_user}" "${log_dir}" 2>/dev/null || true

    if ! "${PLUTIL}" -lint "${plist_path}" >/dev/null 2>&1
    then
        log_error "Generated LaunchAgent plist failed plutil -lint: ${plist_path}"
        return 1
    fi

    log_info "Wrote LaunchAgent plist: ${plist_path}"
    return 0
}

# ── Bootstrap the agent into the console user's GUI session ──────────────────
bootstrap_agent() {
    local console_user="$1"
    local user_home="$2"
    local uid
    local plist_path="${user_home}/Library/LaunchAgents/${AGENT_PLIST_FILENAME}"

    uid=$("${ID}" -u "${console_user}" 2>/dev/null || printf '')
    if [[ -z "${uid}" ]]
    then
        log_warn "Could not resolve uid for ${console_user} — agent will load at next login"
        return 0
    fi

    # Reload cleanly: bootout if already loaded (upgrade path), then bootstrap.
    if "${LAUNCHCTL}" print "gui/${uid}/${AGENT_LABEL}" >/dev/null 2>&1
    then
        "${LAUNCHCTL}" bootout "gui/${uid}/${AGENT_LABEL}" 2>/dev/null || true
    fi

    if ! "${LAUNCHCTL}" bootstrap "gui/${uid}" "${plist_path}" 2>/dev/null
    then
        log_warn "launchctl bootstrap failed for gui/${uid} — agent will load at next login"
        return 0
    fi

    # Nudge it to run now even if RunAtLoad is debounced by a prior load.
    "${LAUNCHCTL}" kickstart "gui/${uid}/${AGENT_LABEL}" 2>/dev/null || true

    log_info "Bootstrapped ${AGENT_LABEL} into gui/${uid} (${console_user})"
    return 0
}

do_install() {
    local console_user
    local user_home

    log_info "Installing ${AGENT_LABEL} v${SCRIPT_VERSION}"

    write_sync_script || exit 1

    if [[ -f "${LEGACY_INSTALL_SCRIPT_PATH}" ]]
    then
        "${RM}" -f "${LEGACY_INSTALL_SCRIPT_PATH}"
        log_info "Removed pre-rename agent script: ${LEGACY_INSTALL_SCRIPT_PATH}"
    fi

    console_user=$(get_console_user)
    if [[ -z "${console_user}" ]]
    then
        log_warn "No active console user — sync script installed, but the per-user LaunchAgent needs a logged-in user. Re-run this policy at/after login (e.g. a Login trigger)."
        return 0
    fi

    user_home=$(resolve_user_home "${console_user}")
    if [[ -z "${user_home}" || ! -d "${user_home}" ]]
    then
        log_error "Could not resolve home directory for ${console_user} — cannot install per-user LaunchAgent"
        return 0
    fi

    cleanup_legacy_agent "${console_user}"
    write_agent_plist "${console_user}" "${user_home}" || exit 1
    bootstrap_agent "${console_user}" "${user_home}"
    log_info "Install complete"
    return 0
}

do_uninstall() {
    local console_user
    local uid
    local user_home
    local plist_path=""

    log_info "Uninstalling ${AGENT_LABEL}"

    console_user=$(get_console_user)
    if [[ -n "${console_user}" ]]
    then
        uid=$("${ID}" -u "${console_user}" 2>/dev/null || printf '')
        if [[ -n "${uid}" ]] && "${LAUNCHCTL}" print "gui/${uid}/${AGENT_LABEL}" >/dev/null 2>&1
        then
            "${LAUNCHCTL}" bootout "gui/${uid}/${AGENT_LABEL}" 2>/dev/null || true
        fi
        user_home=$(resolve_user_home "${console_user}")
        if [[ -n "${user_home}" ]]
        then
            plist_path="${user_home}/Library/LaunchAgents/${AGENT_PLIST_FILENAME}"
        fi
    fi

    cleanup_legacy_agent "${console_user}"

    if [[ -n "${plist_path}" && -f "${plist_path}" ]]
    then
        "${RM}" -f "${plist_path}"
    fi

    if [[ -d "${INSTALL_DIR}" ]]
    then
        "${RM}" -rf "${INSTALL_DIR}"
    fi

    log_warn "Note: this removes only the current console user's copy. Remove per-user copies in other users' ~/Library/LaunchAgents separately, along with the MDM-delivered Managed Login Items profile in Jamf Pro."
    log_info "Uninstall complete"
    return 0
}

do_status() {
    log_info "Status for ${AGENT_LABEL}:"

    if [[ -f "${INSTALL_SCRIPT_PATH}" ]]
    then
        log_info "  sync script:  present  (${INSTALL_SCRIPT_PATH})"
    else
        log_info "  sync script:  MISSING  (${INSTALL_SCRIPT_PATH})"
    fi

    local console_user
    local uid
    local user_home
    local plist_path=""
    console_user=$(get_console_user)
    if [[ -n "${console_user}" ]]
    then
        user_home=$(resolve_user_home "${console_user}")
        if [[ -n "${user_home}" ]]
        then
            plist_path="${user_home}/Library/LaunchAgents/${AGENT_PLIST_FILENAME}"
        fi
    fi

    if [[ -n "${plist_path}" && -f "${plist_path}" ]]
    then
        log_info "  launchagent:  present  (${plist_path})"
    else
        log_info "  launchagent:  MISSING  (per-user ~/Library/LaunchAgents/${AGENT_PLIST_FILENAME})"
    fi

    if [[ -n "${console_user}" ]]
    then
        uid=$("${ID}" -u "${console_user}" 2>/dev/null || printf '')
        if [[ -n "${uid}" ]] && "${LAUNCHCTL}" print "gui/${uid}/${AGENT_LABEL}" >/dev/null 2>&1
        then
            log_info "  agent state:  loaded in gui/${uid} (${console_user})"
        else
            log_info "  agent state:  not loaded for ${console_user}"
        fi
    else
        log_info "  agent state:  no active console user to check"
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
validate_config
check_dependencies

# Resolve mode. Jamf passes $1=mountpoint; a direct CLI call may pass a flag.
MODE="install"

case "${1:-}" in
    install|uninstall|status)
        MODE="${1}"
        ;;
    /*|"")
        # Jamf Script payload ($1 = mount point) or no args — use $4 if provided.
        if [[ -n "${PARAM_MODE}" ]]
        then
            MODE="${PARAM_MODE}"
        fi
        ;;
    *)
        log_error "Unknown argument: ${1:-} (expected install|uninstall|status)"
        exit 1
        ;;
esac

case "${MODE}" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    status)
        do_status
        ;;
    *)
        log_error "Unknown mode: ${MODE} (expected install|uninstall|status)"
        exit 1
        ;;
esac

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

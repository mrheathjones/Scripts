#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Install-Microsoft-App.sh
# Author: Heath Jones
# Date: 10-07-2026
# Modified: 10-07-2026
# Purpose: Download and install a single Microsoft app (Office, Teams, Edge, VS Code, etc.) from Microsoft's CDN, selected via Jamf parameter $4
# Version: 1.0 - Initial Script
# Version: 1.1 - Rewritten to expert-bash template; Visual Studio Code now installs from the universal DMG
# Version: 1.2 - DMG mount via diskutil image attach (macOS 26+) with hdiutil fallback; detach via diskutil eject; touch bundle after copy so Finder refreshes the icon
# Version: 1.3 - Search system directories only (no /usr/local/bin in PATH); pin curl redirects to HTTPS
#
# Requirements:
#   - Runs as root (Jamf policy)
#   - Outbound HTTPS to go.microsoft.com, *.microsoft.com, and code.visualstudio.com
#   - Jamf parameter $4: app to install (case-insensitive) — one of:
#       word, excel, powerpoint, outlook, onenote, onedrive, teams,
#       companyportal, edge, windowsapp, visualstudiocode, copilot, mau
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

# File-level ShellCheck disables (must precede the first command):
#   SC2230: `which` preferred over `command -v` per style guide
#   SC2155: readonly NAME=$(which ...) is the template's binary-path style
#   SC2034: ORG_NAME / TIMESTAMP are template constants kept for consistency
#   SC2016: awk programs legitimately use $0/$2/$NF inside single quotes
# shellcheck disable=SC2230,SC2155,SC2034,SC2016
set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context.
# System directories only: everything this script runs ships with macOS, and
# /usr/local/bin can be user-owned on Intel Macs where Homebrew was installed.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
# `which` is preferred over `command -v` per the style guide (file-level SC2230 disable above).
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY: human-readable display name; MAY contain spaces. Use it for
#   user-facing text and swiftDialog banners. e.g. "Example Corp".
# ORG_NAME: path-safe — ORG_NAME_FRIENDLY with spaces removed — for filesystem
#   paths like /Library/Application Support/${ORG_NAME}/ and /Library/Logs/${ORG_NAME}/.
#   e.g. "ExampleCorp". (${var// /} is bash 3.2-safe; avoid '/' in the friendly name.)
# ORG_PLIST_DOMAIN: reverse-DNS — used for LOG_LABEL, LaunchDaemon/LaunchAgent
#   labels, and defaults preference domains. e.g. "com.example".
readonly ORG_NAME_FRIENDLY="Company Name"
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.3"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"
readonly TIMESTAMP=$("${DATE}" +%Y%m%d_%H%M%S)
readonly JAMF_LOG="/var/log/jamf.log"

declare -a TEMP_FILES=()
declare -a TEMP_DIRS=()

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# Task-specific binary paths
readonly CHMOD=$(which chmod)
readonly CHOWN=$(which chown)
readonly CODESIGN=$(which codesign)
readonly CP=$(which cp)
readonly CURL=$(which curl)
readonly DISKUTIL=$(which diskutil)
readonly HDIUTIL=$(which hdiutil)
readonly INSTALLER=$(which installer)
readonly PGREP=$(which pgrep)
readonly PKGUTIL=$(which pkgutil)
readonly STAT=$(which stat)
readonly TOUCH=$(which touch)
readonly TR=$(which tr)

# Jamf parameters ($1-$3 reserved by Jamf: mount point, computer name, username)
# $4 is the app to install. When run outside Jamf (no mount point in $1), $1 is
# accepted as the app name for local testing: sudo ./Install-Microsoft-App.sh edge
PARAM_APP_NAME="${4:-}"
if [[ -z "${PARAM_APP_NAME}" && "${1:-}" != /* ]]
then
    PARAM_APP_NAME="${1:-}"
fi
readonly PARAM_APP_NAME

# Microsoft download endpoints
readonly MSFT_FWLINK_BASE="https://go.microsoft.com/fwlink/?linkid="
readonly VSCODE_DOWNLOAD_URL="https://code.visualstudio.com/sha/download?build=stable&os=darwin-universal-dmg"

# Apple Developer Team ID that signs every Microsoft pkg and app bundle
readonly MSFT_TEAM_ID="UBF8T346G9"

# curl behaviour: retry transient failures, cap total time (large installers on slow links)
readonly CURL_RETRIES="3"
readonly CURL_MAX_TIME="1800"

# Resolved per-app values (set by resolve_app)
APP_KEY=""
APP_DOWNLOAD_URL=""
APP_INSTALL_TYPE=""      # pkg | dmg
APP_BUNDLE_NAME=""       # for dmg installs: name of the .app inside the image

# Working state
WORK_DIR=""
INSTALLER_PATH=""
DMG_MOUNT_POINT=""

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
    local d

    # Detach any DMG still mounted (error path or interrupt)
    if [[ -n "${DMG_MOUNT_POINT}" && -d "${DMG_MOUNT_POINT}" ]]
    then
        if ! "${DISKUTIL}" eject "${DMG_MOUNT_POINT}" >/dev/null 2>&1
        then
            if ! "${HDIUTIL}" detach "${DMG_MOUNT_POINT}" -quiet -force
            then
                log_warn "Failed to detach ${DMG_MOUNT_POINT} during cleanup"
            fi
        fi
    fi

    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -f "${f}" ]]
        then
            "${RM}" -f "${f}"
        fi
    done

    for d in "${TEMP_DIRS[@]:-}"
    do
        if [[ -n "${d}" && -d "${d}" ]]
        then
            "${RM}" -rf "${d}"
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

# Map the requested app name to a download URL and install method.
# Sets APP_KEY, APP_DOWNLOAD_URL, APP_INSTALL_TYPE, APP_BUNDLE_NAME.
resolve_app() {
    local requested="$1"
    local normalized

    # Bash 3.2 has no ${var,,}; lowercase via tr
    normalized=$(printf '%s' "${requested}" | "${TR}" '[:upper:]' '[:lower:]')

    case "${normalized}" in
        word)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}525134"
            APP_INSTALL_TYPE="pkg"
            ;;
        excel)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}525135"
            APP_INSTALL_TYPE="pkg"
            ;;
        powerpoint)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}525136"
            APP_INSTALL_TYPE="pkg"
            ;;
        outlook)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}2228621"
            APP_INSTALL_TYPE="pkg"
            ;;
        onenote)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}820886"
            APP_INSTALL_TYPE="pkg"
            ;;
        onedrive)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}823060"
            APP_INSTALL_TYPE="pkg"
            ;;
        teams)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}2249065"
            APP_INSTALL_TYPE="pkg"
            ;;
        companyportal)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}853070"
            APP_INSTALL_TYPE="pkg"
            ;;
        edge)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}2093504"
            APP_INSTALL_TYPE="pkg"
            ;;
        windowsapp)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}868963"
            APP_INSTALL_TYPE="pkg"
            ;;
        visualstudiocode)
            APP_DOWNLOAD_URL="${VSCODE_DOWNLOAD_URL}"
            APP_INSTALL_TYPE="dmg"
            APP_BUNDLE_NAME="Visual Studio Code"
            ;;
        copilot)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}2325438"
            APP_INSTALL_TYPE="pkg"
            ;;
        mau)
            APP_DOWNLOAD_URL="${MSFT_FWLINK_BASE}830196"
            APP_INSTALL_TYPE="pkg"
            ;;
        *)
            log_error "Unknown app '${requested}'. Valid values: word excel powerpoint outlook onenote onedrive teams companyportal edge windowsapp visualstudiocode copilot mau"
            exit 1
            ;;
    esac

    APP_KEY="${normalized}"
    log_info "Resolved '${requested}' -> ${APP_KEY} (${APP_INSTALL_TYPE}) from ${APP_DOWNLOAD_URL}"
}

# Create a private working directory under mktemp (never a predictable /tmp path)
create_work_dir() {
    WORK_DIR=$("${MKTEMP}" -d "/private/tmp/${SCRIPT_NAME%.sh}.XXXXXX")
    TEMP_DIRS+=("${WORK_DIR}")
    "${CHMOD}" 700 "${WORK_DIR}"
    log_debug "Working directory: ${WORK_DIR}"
}

# Download the installer. Sets INSTALLER_PATH.
download_installer() {
    local file_size

    INSTALLER_PATH="${WORK_DIR}/microsoft_${APP_KEY}.${APP_INSTALL_TYPE}"
    log_info "Downloading ${APP_KEY} installer"

    if ! "${CURL}" --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry "${CURL_RETRIES}" --retry-delay 5 \
        --connect-timeout 30 --max-time "${CURL_MAX_TIME}" \
        --output "${INSTALLER_PATH}" \
        "${APP_DOWNLOAD_URL}"
    then
        log_error "Download failed for ${APP_DOWNLOAD_URL}"
        exit 1
    fi

    if [[ ! -s "${INSTALLER_PATH}" ]]
    then
        log_error "Downloaded file is missing or empty: ${INSTALLER_PATH}"
        exit 1
    fi

    file_size=$("${STAT}" -f %z "${INSTALLER_PATH}")
    log_info "Download complete: ${INSTALLER_PATH} (${file_size} bytes)"
}

# Verify a pkg carries a Developer ID Installer signature from Microsoft
verify_pkg_signature() {
    local pkg_path="$1"
    local sig_output

    if ! sig_output=$("${PKGUTIL}" --check-signature "${pkg_path}" 2>&1)
    then
        log_error "Package signature check failed for ${pkg_path}"
        log_debug "${sig_output}"
        exit 1
    fi

    if ! printf '%s' "${sig_output}" | "${AWK}" -v team="${MSFT_TEAM_ID}" 'index($0, "(" team ")") { found = 1 } END { exit !found }'
    then
        log_error "Package is not signed by Microsoft (Team ID ${MSFT_TEAM_ID})"
        log_debug "${sig_output}"
        exit 1
    fi

    log_info "Package signature verified (Team ID ${MSFT_TEAM_ID})"
}

# Verify an app bundle's code signature and that its Team ID is Microsoft's
verify_app_signature() {
    local app_path="$1"
    local team_id

    if ! "${CODESIGN}" --verify --deep --strict "${app_path}" >/dev/null 2>&1
    then
        log_error "Code signature verification failed for ${app_path}"
        exit 1
    fi

    team_id=$("${CODESIGN}" -dv --verbose=4 "${app_path}" 2>&1 \
        | "${AWK}" -F= '/^TeamIdentifier=/ { print $2 }')

    if [[ "${team_id}" != "${MSFT_TEAM_ID}" ]]
    then
        log_error "App Team ID '${team_id}' does not match Microsoft (${MSFT_TEAM_ID})"
        exit 1
    fi

    log_info "App signature verified (Team ID ${MSFT_TEAM_ID})"
}

# Write the Teams installer choice-changes XML into the working directory
write_teams_choices() {
    local choices_path="${WORK_DIR}/teamsChoices.xml"

    cat > "${choices_path}" <<'TEAMS_CHOICES_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>attributeSetting</key>
		<true/>
		<key>choiceAttribute</key>
		<string>visible</string>
		<key>choiceIdentifier</key>
		<string>Teams</string>
	</dict>
	<dict>
		<key>attributeSetting</key>
		<false/>
		<key>choiceAttribute</key>
		<string>enabled</string>
		<key>choiceIdentifier</key>
		<string>Teams</string>
	</dict>
	<dict>
		<key>attributeSetting</key>
		<integer>1</integer>
		<key>choiceAttribute</key>
		<string>selected</string>
		<key>choiceIdentifier</key>
		<string>Teams</string>
	</dict>
	<dict>
		<key>attributeSetting</key>
		<false/>
		<key>choiceAttribute</key>
		<string>visible</string>
		<key>choiceIdentifier</key>
		<string>TeamsApp</string>
	</dict>
	<dict>
		<key>attributeSetting</key>
		<false/>
		<key>choiceAttribute</key>
		<string>enabled</string>
		<key>choiceIdentifier</key>
		<string>TeamsApp</string>
	</dict>
	<dict>
		<key>attributeSetting</key>
		<integer>1</integer>
		<key>choiceAttribute</key>
		<string>selected</string>
		<key>choiceIdentifier</key>
		<string>TeamsApp</string>
	</dict>
	<dict>
		<key>attributeSetting</key>
		<true/>
		<key>choiceAttribute</key>
		<string>visible</string>
		<key>choiceIdentifier</key>
		<string>AudioDevice</string>
	</dict>
	<dict>
		<key>attributeSetting</key>
		<true/>
		<key>choiceAttribute</key>
		<string>enabled</string>
		<key>choiceIdentifier</key>
		<string>AudioDevice</string>
	</dict>
	<dict>
		<key>attributeSetting</key>
		<integer>1</integer>
		<key>choiceAttribute</key>
		<string>selected</string>
		<key>choiceIdentifier</key>
		<string>AudioDevice</string>
	</dict>
</array>
</plist>
TEAMS_CHOICES_EOF

    "${CHMOD}" 600 "${choices_path}"
    TEMP_FILES+=("${choices_path}")
    printf '%s' "${choices_path}"
}

# Install a .pkg with the system installer (Teams gets its choice-changes XML)
install_from_pkg() {
    local pkg_path="$1"
    local choices_path
    local exit_code

    verify_pkg_signature "${pkg_path}"

    if [[ "${APP_KEY}" == "teams" ]]
    then
        choices_path=$(write_teams_choices)
        log_info "Installing Teams with choice changes"
        "${INSTALLER}" -pkg "${pkg_path}" -target / -applyChoiceChangesXML "${choices_path}"
        exit_code=$?
    else
        log_info "Installing package"
        "${INSTALLER}" -pkg "${pkg_path}" -target /
        exit_code=$?
    fi

    if [[ ${exit_code} -ne 0 ]]
    then
        log_error "installer exited with code ${exit_code}"
        exit 1
    fi

    log_info "Package installed: $("${BASENAME}" "${pkg_path}")"
}

# Mount a .dmg without showing it in Finder. Sets DMG_MOUNT_POINT.
# macOS 26+ provides `diskutil image attach`; `hdiutil attach` is deprecated
# there (prints a warning on 27) but remains the only option on older releases.
# Both print "<dev>\t<type>\t<mount point>" lines, so one parse serves both.
attach_dmg() {
    local dmg_path="$1"
    local attach_output

    if "${DISKUTIL}" image attach --help >/dev/null 2>&1
    then
        log_debug "Attaching via diskutil image attach"
        attach_output=$("${DISKUTIL}" image attach --nobrowse --readOnly "${dmg_path}" 2>&1) || true
    else
        log_debug "Attaching via hdiutil attach (diskutil image unavailable)"
        attach_output=$("${HDIUTIL}" attach "${dmg_path}" -nobrowse -noverify -noautoopen 2>&1) || true
    fi

    DMG_MOUNT_POINT=$(printf '%s\n' "${attach_output}" \
        | "${AWK}" -F'\t' '/\/Volumes\// { print $NF }')

    if [[ -z "${DMG_MOUNT_POINT}" || ! -d "${DMG_MOUNT_POINT}" ]]
    then
        log_error "Failed to mount ${dmg_path}"
        log_debug "${attach_output}"
        exit 1
    fi
    log_debug "Mounted at ${DMG_MOUNT_POINT}"
}

# Eject the mounted image. diskutil eject works on every supported macOS and
# emits no deprecation warning; hdiutil detach is the fallback.
detach_dmg() {
    if [[ -z "${DMG_MOUNT_POINT}" ]]
    then
        return 0
    fi

    if "${DISKUTIL}" eject "${DMG_MOUNT_POINT}" >/dev/null 2>&1
    then
        DMG_MOUNT_POINT=""
        return 0
    fi

    if "${HDIUTIL}" detach "${DMG_MOUNT_POINT}" -quiet
    then
        DMG_MOUNT_POINT=""
        return 0
    fi

    log_warn "Failed to detach ${DMG_MOUNT_POINT}; cleanup will force it"
}

# Mount a .dmg, verify the app inside, copy it to /Applications, detach
install_from_dmg() {
    local dmg_path="$1"
    local app_name="$2"
    local source_app
    local target_app="/Applications/${app_name}.app"

    log_info "Mounting ${dmg_path}"
    attach_dmg "${dmg_path}"

    source_app="${DMG_MOUNT_POINT}/${app_name}.app"
    if [[ ! -d "${source_app}" ]]
    then
        log_error "${app_name}.app not found in ${DMG_MOUNT_POINT}"
        exit 1
    fi

    verify_app_signature "${source_app}"

    if "${PGREP}" -xq "${app_name}"
    then
        log_warn "${app_name} is running; the new version takes effect on next launch"
    fi

    if [[ -d "${target_app}" ]]
    then
        log_info "Removing existing ${target_app}"
        "${RM}" -rf "${target_app}"
    fi

    log_info "Copying ${app_name}.app to /Applications"
    if ! "${CP}" -R "${source_app}" "${target_app}"
    then
        log_error "Copy to ${target_app} failed"
        exit 1
    fi

    "${CHOWN}" -R root:wheel "${target_app}"
    "${CHMOD}" -R go-w "${target_app}"

    # Finder caches a generic icon when it sees the bundle appear mid-copy;
    # bumping the bundle's mtime after the copy makes it re-read the icon.
    "${TOUCH}" "${target_app}"

    detach_dmg

    log_info "Installed ${target_app}"
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

if [[ -z "${PARAM_APP_NAME}" ]]
then
    log_error "Parameter 4 (app name) is required"
    exit 1
fi

resolve_app "${PARAM_APP_NAME}"
create_work_dir
download_installer

case "${APP_INSTALL_TYPE}" in
    pkg)
        install_from_pkg "${INSTALLER_PATH}"
        ;;
    dmg)
        install_from_dmg "${INSTALLER_PATH}" "${APP_BUNDLE_NAME}"
        ;;
    *)
        log_error "Unsupported install type: ${APP_INSTALL_TYPE}"
        exit 1
        ;;
esac

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

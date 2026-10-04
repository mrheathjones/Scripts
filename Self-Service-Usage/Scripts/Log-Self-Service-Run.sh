#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Log-Self-Service-Run.sh
# Author: Heath Jones
# Date: 06-26-2026
# Modified: 10-04-2026
# Purpose: Record a Self Service policy run to a local JSON usage file
#          (per-policy count, first/last run, capped timestamp history)
#          for collection by the Self Service Usage Extension Attribute.
# Version: 1.0 - Initial Script
# Version: 1.1 - Public release prep: sanitized identifiers, expert-bash conformance.
#                Added Requirements section + require_param preflight; slugify now
#                sets a global instead of being captured; fixed lock handling so a
#                run that timed out waiting no longer removes another run's lock
#                (stale locks are now broken explicitly); fixed malformed
#                ShellCheck directive; removed unused awk binary var.
# Version: 1.2 - Renamed to Name-Of-Script.sh convention
#
# Requirements:
#   - Runs as root (Jamf policy, typically a Self Service policy)
#   - jq at /usr/bin/jq (ships with macOS 15+) or elsewhere in PATH
#   - Jamf parameter $4 (required): policy display name, e.g. "Install Zoom"
#   - Jamf parameter $5 (optional): stable policy slug/id; derived from $4 if blank
#   - Jamf parameter $6 (optional): history cap per policy; default 50
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
# jq/sed programs are intentionally single-quoted (SC2016); both are deliberate.
# shellcheck disable=SC2155,SC2016

set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
# `which` is preferred over `command -v` per the style guide, so the directive below is deliberate.
# shellcheck disable=SC2230
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY: human-readable display name, e.g. "Example Corp". MUST match
#   EA-Self-Service-Usage.sh so both resolve the same data path.
# ORG_NAME: path-safe form (spaces stripped), derived — never set by hand.
# ORG_PLIST_DOMAIN: reverse-DNS used for LOG_LABEL, e.g. "com.example".
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: your organization's display name
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"      # CHANGE_ME: your organization's reverse-DNS domain

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.2"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"
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
readonly JQ=$(which jq)
readonly MKDIR=$(which mkdir)
readonly MV=$(which mv)
readonly CHOWN=$(which chown)
readonly CHMOD=$(which chmod)
readonly RMDIR=$(which rmdir)
readonly SLEEP=$(which sleep)
readonly TR=$(which tr)
readonly SED=$(which sed)

# Jamf parameters ($1-$3 reserved by Jamf: mount point, computer name, username)
# $4 = Policy display name (REQUIRED) — e.g. "Install Zoom"
# $5 = Stable policy slug/id (optional) — e.g. "install-zoom"; derived from $4 if blank
# $6 = History cap (optional) — max timestamps retained per policy; default 50
readonly PARAM_POLICY_NAME="${4:-}"
readonly PARAM_POLICY_SLUG="${5:-}"
readonly PARAM_HISTORY_CAP="${6:-}"

# Data locations
readonly DATA_DIR="/Library/Application Support/${ORG_NAME}/SelfServiceUsage"
readonly USAGE_JSON="${DATA_DIR}/usage.json"
readonly LOCK_DIR="${DATA_DIR}/.usage.lock"

# Default retained-history length when $6 is absent/invalid
readonly DEFAULT_HISTORY_CAP=50

# Runtime globals (set by helpers; never captured from function stdout)
LOCK_HELD=0
SLUG_RESULT=""

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

# Confirm jq is present and executable — required for all JSON handling.
require_jq() {
    if [[ ! -x "${JQ}" ]]
    then
        log_error "jq is required but not found in PATH"
        exit 1
    fi
}

# Derive a stable, filesystem/JSON-key-safe slug from a display name and store
# it in SLUG_RESULT (global). "Install Zoom 6.2" -> "install-zoom-6-2"
slugify() {
    local raw="$1"
    SLUG_RESULT=$(printf '%s' "${raw}" \
        | "${TR}" '[:upper:]' '[:lower:]' \
        | "${SED}" -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
}

# Acquire a coarse lock so two near-simultaneous Self Service runs don't
# lost-update the counter. mkdir is atomic. Best-effort: after a bounded wait
# (~5s) the lock is treated as stale (left by a killed run) and broken once;
# if that still fails, proceed unlocked rather than failing the user's policy.
# Sets LOCK_HELD=1 only when this run owns the lock.
acquire_lock() {
    local attempts=0
    local max_attempts=50
    while ! "${MKDIR}" "${LOCK_DIR}" 2>/dev/null
    do
        attempts=$((attempts + 1))
        if [[ "${attempts}" -ge "${max_attempts}" ]]
        then
            log_warn "Usage lock still held after ${attempts} tries; treating it as stale and breaking it"
            "${RMDIR}" "${LOCK_DIR}" 2>/dev/null || true
            if "${MKDIR}" "${LOCK_DIR}" 2>/dev/null
            then
                LOCK_HELD=1
            else
                log_warn "Could not acquire usage lock; proceeding unlocked"
            fi
            return 0
        fi
        "${SLEEP}" 0.1
    done
    LOCK_HELD=1
    return 0
}

# Release the lock only if this run owns it.
release_lock() {
    if [[ "${LOCK_HELD}" -eq 1 ]]
    then
        "${RMDIR}" "${LOCK_DIR}" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

# Ensure the data directory and a valid JSON object file exist.
ensure_store() {
    "${MKDIR}" -p "${DATA_DIR}"
    "${CHOWN}" root:wheel "${DATA_DIR}"
    "${CHMOD}" 755 "${DATA_DIR}"

    if [[ -f "${USAGE_JSON}" ]]
    then
        if ! "${JQ}" -e . "${USAGE_JSON}" >/dev/null 2>&1
        then
            log_warn "usage.json was missing/invalid JSON; reinitializing"
            printf '{}\n' > "${USAGE_JSON}"
        fi
    else
        printf '{}\n' > "${USAGE_JSON}"
    fi

    "${CHOWN}" root:wheel "${USAGE_JSON}"
    "${CHMOD}" 644 "${USAGE_JSON}"
}

# Record one run for the given slug/name into usage.json (atomic write).
record_run() {
    local slug="$1"
    local name="$2"
    local cap="$3"
    local now
    now=$("${DATE}" -u +%Y-%m-%dT%H:%M:%SZ)

    local tmp
    tmp=$("${MKTEMP}")
    TEMP_FILES+=("${tmp}")

    if ! "${JQ}" \
        --arg slug "${slug}" \
        --arg name "${name}" \
        --arg now "${now}" \
        --argjson cap "${cap}" \
        '
        .[$slug] = (
            (.[$slug] // {}) as $cur
            | {
                policyName: $name,
                policyId: $slug,
                count: (($cur.count // 0) + 1),
                firstRun: ($cur.firstRun // $now),
                lastRun: $now,
                history: (
                    (($cur.history // []) + [$now])
                    | if (length > $cap) then .[length - $cap :] else . end
                )
            }
        )
        ' "${USAGE_JSON}" > "${tmp}"
    then
        log_error "jq failed to update usage record for slug '${slug}'"
        return 1
    fi

    if ! "${JQ}" -e . "${tmp}" >/dev/null 2>&1
    then
        log_error "Refusing to write: updated usage JSON failed validation"
        return 1
    fi

    "${MV}" -f "${tmp}" "${USAGE_JSON}"
    "${CHOWN}" root:wheel "${USAGE_JSON}"
    "${CHMOD}" 644 "${USAGE_JSON}"
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
require_param "policy display name (\$4)" "${PARAM_POLICY_NAME}"
require_jq

# Resolve the stable slug: use $5 if provided, else derive from the name.
if [[ -z "${PARAM_POLICY_SLUG}" ]]
then
    slugify "${PARAM_POLICY_NAME}"
else
    slugify "${PARAM_POLICY_SLUG}"
fi
policy_slug="${SLUG_RESULT}"

if [[ -z "${policy_slug}" ]]
then
    log_error "Could not derive a usable policy slug from name '${PARAM_POLICY_NAME}'"
    exit 1
fi

# Resolve and validate the history cap.
history_cap="${PARAM_HISTORY_CAP}"
if ! [[ "${history_cap}" =~ ^[0-9]+$ ]] || [[ "${history_cap}" -lt 1 ]]
then
    history_cap="${DEFAULT_HISTORY_CAP}"
fi

acquire_lock
ensure_store
record_run "${policy_slug}" "${PARAM_POLICY_NAME}" "${history_cap}"
release_lock

log_info "Recorded Self Service run: name='${PARAM_POLICY_NAME}' slug='${policy_slug}' cap=${history_cap}"

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

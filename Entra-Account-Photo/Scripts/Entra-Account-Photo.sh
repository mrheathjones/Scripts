#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Entra-Account-Photo.sh
# Author: Heath Jones
# Date: 07-10-2026
# Modified: 10-04-2026
# Purpose: Set a Mac's local account picture from the user's Microsoft
#          Entra ID (Azure AD) profile photo. Defaults to a one-time
#          apply ("once" mode) so the user's own choice always wins,
#          with a built-in toggle for ongoing sync ("sync" mode).
# Version: 1.0 - Initial Script
#          1.1 - PSSO UPN is a Kerberos principal
#                (first.last\@example.com@KERBEROS.MICROSOFTONLINE.COM); parse the
#                "upn" field explicitly, strip the realm, and unescape
#                instead of scanning for the first email token.
#          1.2 - Added CRED_SOURCE toggle ($11): params (default) | profile
#                | auto. profile reads client_id/tenant_id/client_secret from
#                a Custom Settings config profile (managed prefs) instead of
#                Jamf script parameters, shrinking the secret read surface.
#          1.3 - Promoted CONFIG_PROFILE_DOMAIN to a prominent, standalone
#                editable variable so the config-profile preference domain can
#                be set to any value without touching the credential logic.
#          1.4 - Added certificate auth (PS256 client assertion), preferred over
#                client secret. Cert+key PEM delivered via the config profile
#                (CertificatePEM key); signed with openssl via process
#                substitution (private key never written to disk). Mirrors the
#                Erase-And-Delete-Devices.sh / ABM cert-auth pattern.
#          1.5 - Log the Graph JSON error code/message on non-2xx responses
#                (user lookup, photo metadata, photo download) so failures like
#                403 Authorization_RequestDenied are self-explaining; added a
#                hint pointing at the User.Read.All admin-consent requirement.
#          1.6 - PSSO UPN: when a Mac holds multiple SSO identities, prefer the
#                Entra cloud-Kerberos principal (@KERBEROS.MICROSOFTONLINE.COM)
#                over a legacy on-prem AD principal (a short name in an on-prem AD Kerberos realm) that
#                was being picked incorrectly.
#          1.7 - `app-sso platform -s` output is NOT JSON — jq errored and the
#                script silently fell through to the Jamf Connect source (which
#                returned the legacy AD UPN). Parse the "upn" line with sed
#                instead of jq; keep the cloud-Kerberos-realm preference.
#          1.8 - Public release prep: sanitized identifiers/credentials,
#                expert-bash conformance. Fixes: SCRIPT_NAME was derived from
#                an empty string instead of $0 (broke LOG_LABEL / log file
#                name); temp files created inside $(...) were registered in a
#                subshell and never cleaned up (token response body and photo
#                left in /tmp) - create_temp_file now sets a global;
#                build_graph_assertion now sets a global instead of having its
#                logging stdout captured; added Requirements + require_jq
#                preflight; replaced statement-level `||` fallbacks with
#                multi-line if blocks; tee via binary-path variable;
#                config-profile credentials left as REPLACE-WITH-* placeholders
#                are now rejected (exit 3) instead of attempting OAuth.
#          1.9 - Renamed to Name-Of-Script.sh convention
#
# Requirements:
#   - Runs as root (Jamf policy) with a logged-in console user
#     (no console user = clean no-op, exit 0)
#   - jq (ships at /usr/bin/jq on macOS 15+; install it on older macOS)
#   - Entra app registration with Microsoft Graph User.Read.All
#     (Application) and admin consent
#   - Credentials via Jamf parameters $5-$7 (CRED_SOURCE=params) OR the
#     Custom Settings profile at CONFIG_PROFILE_DOMAIN (profile/auto);
#     certificate auth (CertificatePEM) is profile-only
#   - Jamf parameter $4: SYNC_MODE once (default) | sync
#   - Jamf parameter $5: Entra client ID (params mode)
#   - Jamf parameter $6: Entra tenant ID (params mode)
#   - Jamf parameter $7: Entra client secret (params mode)
#   - Jamf parameter $8: fallback UPN domain suffix (optional)
#   - Jamf parameter $9: Jamf Connect ID-token path (optional)
#   - Jamf parameter $10: UPN_SOURCE auto (default) | psso | jamfconnect | domain
#   - Jamf parameter $11: CRED_SOURCE params (default) | profile | auto
#   - Network: login.microsoftonline.com and graph.microsoft.com
#     (a failed request exits 5/6/7)
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

# File-level, intentional shellcheck disables (justified house style):
#   SC2230 - `which` is preferred over `command -v` per the style guide.
#   SC2155 - `readonly X=$(...)`: return-value masking is immaterial here;
#            this declare+assign pattern is the required convention.
#   SC2034 - TIMESTAMP is mandated template boilerplate.
#   SC2016 - single quotes are REQUIRED for jq filters / awk programs; the
#            `$` tokens are jq/awk variables, not shell expansions.
# shellcheck disable=SC2230,SC2155,SC2034,SC2016

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
readonly TEE=$(which tee)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY: human-readable display name; MAY contain spaces.
# ORG_NAME: path-safe (spaces stripped) — used in filesystem paths.
# ORG_PLIST_DOMAIN: reverse-DNS — LOG_LABEL / preference domains.
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: your organization display name
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"    # CHANGE_ME: your reverse-DNS prefix

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.9"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"
readonly TIMESTAMP=$("${DATE}" +%Y%m%d_%H%M%S)
readonly JAMF_LOG="/var/log/jamf.log"

# Dedicated log file for this workflow (in addition to unified log + jamf.log)
readonly LOG_DIR="/Library/Logs/${ORG_NAME}"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME%.sh}.log"

declare -a TEMP_FILES=()

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# ── Task-specific binary paths ───────────────────────────────────────────────
readonly SCUTIL=$(which scutil)
readonly DSCL=$(which dscl)
readonly DSIMPORT=$(which dsimport)
readonly DEFAULTS=$(which defaults)
readonly CURL=$(which curl)
readonly JQ=$(which jq)
readonly MKDIR=$(which mkdir)
readonly CHOWN=$(which chown)
readonly CHMOD=$(which chmod)
readonly CP=$(which cp)
readonly FILE=$(which file)
readonly BASE64=$(which base64)
readonly TR=$(which tr)
readonly CUT=$(which cut)
readonly HEAD=$(which head)
readonly SED=$(which sed)
readonly CAT=$(which cat)
readonly LAUNCHCTL=$(which launchctl)
readonly SUDO=$(which sudo)
readonly APP_SSO=$(which app-sso)
readonly OPENSSL=$(which openssl)
readonly UUIDGEN=$(which uuidgen)

# ──────────────────────────────────────────────────────────────────────────────
# Jamf Pro script parameters ($1-$3 are reserved by Jamf: mount point,
# computer name, username). See the header/deployment notes for the recommended
# way to supply these and the tradeoffs of storing a secret in Jamf.
#
#   $4  SYNC_MODE        "once" (default) | "sync"   <-- THE mode toggle
#   $5  CLIENT_ID        Entra app registration (application) client ID
#   $6  TENANT_ID        Entra tenant ID (GUID or verified domain)
#   $7  CLIENT_SECRET    Entra app registration client secret value
#   $8  DOMAIN_SUFFIX    fallback UPN domain, e.g. "example.com" (source c)
#   $9  TOKEN_PATH       Jamf Connect ID-token file (default /private/tmp/token)
#   $10 UPN_SOURCE       auto (default) | psso | jamfconnect | domain
#   $11 CRED_SOURCE      params (default) | profile | auto  <-- credential toggle
# ──────────────────────────────────────────────────────────────────────────────

# ── THE MODE TOGGLE ───────────────────────────────────────────────────────────
# Switching the fleet from one-time apply to ongoing sync is a ONE-VALUE change:
# set Jamf parameter $4 (or SYNC_MODE_DEFAULT below) from "once" to "sync".
#   once -> apply the Entra photo exactly once, then never overwrite it again.
#   sync -> re-apply whenever the Entra photo changes (compared via mediaEtag).
readonly SYNC_MODE_DEFAULT="once"
readonly SYNC_MODE="${4:-${SYNC_MODE_DEFAULT}}"

# ── Credentials ───────────────────────────────────────────────────────────────
# SECURITY NOTICE — credential read surface & auth methods:
#   * Graph app-only auth supports TWO methods; a CERTIFICATE (PS256 client
#     assertion) is PREFERRED and used automatically when a cert is present, with
#     a client SECRET as the fallback.
#   * A secret passed as a Jamf script parameter ($7) is readable by anyone with
#     "Read Scripts" (or policy-read) in Jamf Pro, and appears in the policy log.
#   * Delivering credentials via a Custom Settings CONFIGURATION PROFILE
#     (CRED_SOURCE=profile) moves them out of the script/policy and into a
#     managed preferences plist readable only as root on the endpoint. This is
#     the preferred posture — and the ONLY place the certificate PEM is read
#     from (a PEM is too large / sensitive for a Jamf parameter). Set $11=profile
#     (or "auto" to prefer the profile and fall back to parameters).
#   * Either way, use a dedicated Entra app registration scoped to ONLY
#     User.Read.All (application) so leaked auth material cannot do more than read
#     directory users' basic profile + photo. Rotate on a schedule / on suspicion.
#
# THE CREDENTIAL TOGGLE — one value to switch where credentials come from:
#   params  -> read CLIENT_ID/TENANT_ID/CLIENT_SECRET from Jamf params $5-$7
#              (secret auth only; certificate is not supported via parameters).
#   profile -> read from the Custom Settings config profile at
#              CONFIG_PROFILE_DOMAIN. Keys: ClientID, TenantID, and ONE of
#              CertificatePEM (preferred) or ClientSecret.
#   auto    -> use the profile if present & complete, else fall back to params.
readonly CRED_SOURCE="${11:-params}"

# Raw Jamf-parameter credential inputs (consumed only in params/auto mode).
readonly PARAM_CLIENT_ID="${5:-}"
readonly PARAM_TENANT_ID="${6:-}"
readonly PARAM_CLIENT_SECRET="${7:-}"

# ── Config profile preference domain — EDIT TO MATCH YOUR PROFILE ─────────────
# When CRED_SOURCE=profile (or auto), the script reads the Graph credentials
# from the Custom Settings Configuration Profile that uses THIS preference
# domain (String keys: ClientID, TenantID, ClientSecret). Set it to whatever
# domain you want to use — it must match BOTH:
#   * the profile's "Preference Domain" in Jamf Pro, and
#   * the plist filename in ConfigurationProfiles/ (<domain>.plist).
# It defaults to "<ORG_PLIST_DOMAIN>.entraphoto" for convenience, but you can
# replace the whole value with any literal you like, e.g.:
#   readonly CONFIG_PROFILE_DOMAIN="com.example.graphcreds"
#
# Recognized String keys in that profile:
#   ClientID        (required)  Entra app (client) ID
#   TenantID        (required)  Entra tenant ID
#   CertificatePEM  (preferred) full PEM containing BOTH the certificate
#                               block AND its private-key block (PKCS#8,
#                               BEGIN/END lines included). Used for
#                               PS256 client-assertion auth.
#   ClientSecret    (fallback)  app client secret, used only if no CertificatePEM
readonly CONFIG_PROFILE_DOMAIN="${ORG_PLIST_DOMAIN}.entraphoto"    # CHANGE_ME: must match the profile Preference Domain

# Managed-preferences path — derived from the domain above; no need to edit.
# Device-scoped Custom Settings profiles land here and are root-readable only.
readonly CONFIG_PROFILE_PLIST="/Library/Managed Preferences/${CONFIG_PROFILE_DOMAIN}.plist"

# ── UPN resolution config ─────────────────────────────────────────────────────
readonly DOMAIN_SUFFIX="${8:-}"
readonly TOKEN_PATH="${9:-/private/tmp/token}"
readonly UPN_SOURCE="${10:-auto}"

# ── Storage locations ─────────────────────────────────────────────────────────
# Persistent per-user marker/receipt directory.
readonly MARKER_DIR="/Library/Application Support/${ORG_NAME}/entra-photo-set"
# Where the downloaded JPEG is stored persistently.
readonly USER_PICTURES_DIR="/Library/User Pictures/${ORG_NAME}"

# ── Microsoft Graph endpoints ─────────────────────────────────────────────────
readonly LOGIN_HOST="https://login.microsoftonline.com"   # public Microsoft endpoint (sanitize:ignore)
readonly GRAPH_HOST="https://graph.microsoft.com/v1.0"
readonly GRAPH_SCOPE="https://graph.microsoft.com/.default"
readonly CURL_MAX_TIME="30"

# ── Mutable globals set at runtime (populated by functions that also log, so
#    they set a global instead of echoing — capturing a logging function's
#    stdout would pollute the value). ──────────────────────────────────────────
CONSOLE_USER=""
CONSOLE_UID=""
RESOLVED_UPN=""
ACCESS_TOKEN=""
GRAPH_USER_ID=""
CURRENT_ETAG=""
MARKER_FILE=""
# Path of the most recent temp file from create_temp_file() (set in the parent
# shell so the cleanup trap actually sees it in TEMP_FILES).
TEMP_FILE_PATH=""
# Signed client-assertion JWT set by build_graph_assertion().
GRAPH_ASSERTION=""
# Effective credentials, populated at runtime by load_credentials() from either
# Jamf parameters or the config profile (per CRED_SOURCE). Auth material is a
# certificate PEM (preferred, config-profile only) or a client secret (fallback).
CLIENT_ID=""
TENANT_ID=""
CLIENT_SECRET=""
CERT_PEM=""

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

# ── Logging (dual to unified log + jamf.log + dedicated LOG_FILE) ─────────────
log_info() {
    local ts msg
    ts=$("${DATE}" '+%Y-%m-%d %H:%M:%S')
    msg="${ts} ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    # Never let a log-file write failure abort the run under `set -e`.
    if ! echo -e "${msg}" | "${TEE}" -ai "${JAMF_LOG}" "${LOG_FILE}"
    then
        true
    fi
}

log_warn() {
    local ts msg
    ts=$("${DATE}" '+%Y-%m-%d %H:%M:%S')
    msg="${ts} ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    # Never let a log-file write failure abort the run under `set -e`.
    if ! echo -e "${msg}" | "${TEE}" -ai "${JAMF_LOG}" "${LOG_FILE}"
    then
        true
    fi
}

log_error() {
    local ts msg
    ts=$("${DATE}" '+%Y-%m-%d %H:%M:%S')
    msg="${ts} ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    # Never let a log-file write failure abort the run under `set -e`.
    if ! echo -e "${msg}" | "${TEE}" -ai "${JAMF_LOG}" "${LOG_FILE}"
    then
        true
    fi
}

log_debug() {
    local ts msg
    ts=$("${DATE}" '+%Y-%m-%d %H:%M:%S')
    msg="${ts} ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    # Never let a log-file write failure abort the run under `set -e`.
    if ! echo -e "${msg}" | "${TEE}" -ai "${JAMF_LOG}" "${LOG_FILE}"
    then
        true
    fi
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

# Creates a temp file and sets global TEMP_FILE_PATH. Must be called directly
# (NOT inside $(...)) so the TEMP_FILES registration happens in the parent shell
# and the cleanup trap removes the file.
create_temp_file() {
    local prefix="${1:-entraphoto}"
    TEMP_FILE_PATH=$("${MKTEMP}" -t "${prefix}")
    TEMP_FILES+=("${TEMP_FILE_PATH}")
}

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

# ── Console user detection ────────────────────────────────────────────────────
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

# ── Preflight: jq (all JSON parsing). Exit 3 matches the documented
#    "credentials/jq unavailable" code. ─────────────────────────────────────────
require_jq() {
    if [[ -z "${JQ}" || ! -x "${JQ}" ]]
    then
        log_error "jq is required but not found in PATH"
        exit 3
    fi
}

# ── Config validation ─────────────────────────────────────────────────────────
validate_sync_mode() {
    case "${SYNC_MODE}" in
        once|sync)
            log_info "SYNC_MODE = ${SYNC_MODE}"
            ;;
        *)
            log_error "Invalid SYNC_MODE '${SYNC_MODE}' (expected 'once' or 'sync')"
            exit 8
            ;;
    esac
}

# Read a String value from the delivered Custom Settings managed-prefs plist.
read_managed_pref() {
    local key="$1"
    local val=""
    if [[ -f "${CONFIG_PROFILE_PLIST}" ]]
    then
        val=$("${DEFAULTS}" read "${CONFIG_PROFILE_PLIST}" "${key}" 2>/dev/null || true)
    fi
    printf '%s' "${val}"
}

# Populate CLIENT_ID/TENANT_ID + auth material (CERT_PEM preferred, else
# CLIENT_SECRET) from the config profile. Returns 0 only if the IDs are present
# and at least one auth method is available.
load_credentials_from_profile() {
    CLIENT_ID=$(read_managed_pref "ClientID")
    TENANT_ID=$(read_managed_pref "TenantID")
    CERT_PEM=$(read_managed_pref "CertificatePEM")
    CLIENT_SECRET=$(read_managed_pref "ClientSecret")
    # Treat unedited REPLACE-WITH-* placeholders from the sample plist as absent
    # so an unconfigured profile fails as "credentials missing" (exit 3).
    if [[ "${CERT_PEM}" == REPLACE-WITH-* ]]
    then
        CERT_PEM=""
    fi
    if [[ "${CLIENT_SECRET}" == REPLACE-WITH-* ]]
    then
        CLIENT_SECRET=""
    fi
    if [[ -z "${CLIENT_ID}" || -z "${TENANT_ID}" \
        || "${CLIENT_ID}" == REPLACE-WITH-* || "${TENANT_ID}" == REPLACE-WITH-* ]]
    then
        return 1
    fi
    if [[ -z "${CERT_PEM}" && -z "${CLIENT_SECRET}" ]]
    then
        return 1
    fi
    return 0
}

# Populate CLIENT_ID/TENANT_ID/CLIENT_SECRET from Jamf parameters $5-$7
# (secret auth only — a certificate is never read from parameters).
# Returns 0 only if all three are present and not left as placeholders.
load_credentials_from_params() {
    CLIENT_ID="${PARAM_CLIENT_ID}"
    TENANT_ID="${PARAM_TENANT_ID}"
    CLIENT_SECRET="${PARAM_CLIENT_SECRET}"
    CERT_PEM=""
    if [[ -z "${CLIENT_ID}" || -z "${TENANT_ID}" || -z "${CLIENT_SECRET}" \
        || "${CLIENT_ID}" == REPLACE-WITH-* ]]
    then
        return 1
    fi
    return 0
}

# Resolve effective credentials per CRED_SOURCE. Exits 3 on any failure.
load_credentials() {
    case "${CRED_SOURCE}" in
        params)
            if ! load_credentials_from_params
            then
                log_error "CRED_SOURCE=params but client_id/tenant_id/client_secret are not all set (Jamf \$5-\$7)."
                exit 3
            fi
            log_info "Graph credentials loaded from Jamf parameters (auth: $(auth_method_label))"
            ;;
        profile)
            if ! load_credentials_from_profile
            then
                log_error "CRED_SOURCE=profile but config profile '${CONFIG_PROFILE_DOMAIN}' is missing or incomplete (need ClientID/TenantID + CertificatePEM or ClientSecret) at ${CONFIG_PROFILE_PLIST}."
                exit 3
            fi
            log_info "Graph credentials loaded from config profile '${CONFIG_PROFILE_DOMAIN}' (auth: $(auth_method_label))"
            ;;
        auto)
            if load_credentials_from_profile
            then
                log_info "Graph credentials loaded from config profile '${CONFIG_PROFILE_DOMAIN}' (auto; auth: $(auth_method_label))"
            elif load_credentials_from_params
            then
                log_info "Graph credentials loaded from Jamf parameters (auto; no complete config profile found; auth: $(auth_method_label))"
            else
                log_error "CRED_SOURCE=auto but no complete credentials found in config profile ('${CONFIG_PROFILE_DOMAIN}') or Jamf parameters (\$5-\$7)."
                exit 3
            fi
            ;;
        *)
            log_error "Invalid CRED_SOURCE '${CRED_SOURCE}' (expected params|profile|auto)"
            exit 3
            ;;
    esac

    # A certificate requires openssl to build the client assertion.
    if [[ -n "${CERT_PEM}" && ! -x "${OPENSSL}" ]]
    then
        log_error "A certificate was provided but openssl is not available to sign the client assertion"
        exit 3
    fi
}

# Human-readable label for the selected Graph auth method (cert vs secret).
auth_method_label() {
    if [[ -n "${CERT_PEM}" ]]
    then
        printf '%s' "certificate (PS256 client assertion)"
    else
        printf '%s' "client secret"
    fi
}

# ── UPN resolution: (a) PSSO -> (b) Jamf Connect -> (c) username+domain ───────

# Normalize a PSSO "upn" value into a plain Entra UPN.
# Platform SSO stores the UPN as a Kerberos principal, e.g.
#   first.last\@example.com@KERBEROS.MICROSOFTONLINE.COM
# where the real UPN's '@' is backslash-escaped and the Kerberos realm is
# appended after an unescaped '@'. Strip the trailing @REALM and unescape to
# recover user@domain. A value that is already a plain UPN passes through.
normalize_psso_upn() {
    local raw="$1"
    # An escaped '@' (\@) is the reliable signal this is a Kerberos principal
    # with a realm appended. Only then strip the realm and unescape.
    if [[ "${raw}" == *'\@'* ]]
    then
        raw="${raw%@*}"     # drop the trailing @REALM (last, unescaped '@')
        raw="${raw//\\/}"   # unescape: remove backslashes ( \@ -> @ )
    fi
    printf '%s' "${raw}"
}

# (a) PSSO registration — query the Platform SSO extension as the console user
# and read its "upn" field (a Kerberos principal), then normalize it.
#
# IMPORTANT: `app-sso platform -s` prints a human-readable (NON-JSON) dictionary
# on macOS — e.g.  "upn" : "first.last\@example.com@KERBEROS.MICROSOFTONLINE.COM"
# — so we parse the "upn" line textually with sed. (Do NOT pipe it to jq; it is
# not valid JSON and jq errors out.) A Mac can expose more than one SSO identity;
# we PREFER the Entra cloud-Kerberos principal (…@KERBEROS.MICROSOFTONLINE.COM)
# over a legacy on-prem AD principal (a short name in an on-prem AD Kerberos realm), falling back to the
# first "upn" only if none carries the cloud realm.
get_upn_from_psso() {
    local out=""
    local raw=""
    local upn=""

    if [[ ! -x "${APP_SSO}" ]]
    then
        return 1
    fi

    out=$("${LAUNCHCTL}" asuser "${CONSOLE_UID}" "${SUDO}" -u "${CONSOLE_USER}" \
        "${APP_SSO}" platform -s 2>/dev/null || true)
    if [[ -z "${out}" ]]
    then
        return 1
    fi

    # First choice: a "upn" carrying the Entra cloud-Kerberos realm.
    raw=$(printf '%s' "${out}" \
        | "${SED}" -n 's/.*"upn"[[:space:]]*:[[:space:]]*"\([^"]*KERBEROS\.MICROSOFTONLINE\.COM\)".*/\1/p' \
        | "${HEAD}" -n 1 || true)

    # Fallback: the first "upn" value of any form.
    if [[ -z "${raw}" ]]
    then
        raw=$(printf '%s' "${out}" \
            | "${SED}" -n 's/.*"upn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | "${HEAD}" -n 1 || true)
    fi

    if [[ -z "${raw}" ]]
    then
        return 1
    fi

    upn=$(normalize_psso_upn "${raw}")
    if [[ -z "${upn}" || "${upn}" != *@*.* ]]
    then
        return 1
    fi
    printf '%s' "${upn}"
}

# Decode a JWT and pull the UPN claim (upn / preferred_username / unique_name).
decode_jwt_upn() {
    local token_file="$1"
    local jwt=""
    local payload=""
    local decoded=""
    local upn=""

    if [[ ! -s "${token_file}" ]]
    then
        return 1
    fi

    jwt=$("${CAT}" "${token_file}" | "${TR}" -d '[:space:]')
    payload=$(printf '%s' "${jwt}" | "${CUT}" -d. -f2)
    if [[ -z "${payload}" ]]
    then
        return 1
    fi

    # base64url -> base64 and pad to a multiple of 4
    payload=$(printf '%s' "${payload}" | "${TR}" '_-' '/+')
    while [[ $(( ${#payload} % 4 )) -ne 0 ]]
    do
        payload="${payload}="
    done

    decoded=$(printf '%s' "${payload}" | "${BASE64}" -D 2>/dev/null || true)
    if [[ -z "${decoded}" ]]
    then
        return 1
    fi

    upn=$(printf '%s' "${decoded}" \
        | "${JQ}" -r '.upn // .preferred_username // .unique_name // empty' 2>/dev/null || true)
    if [[ -z "${upn}" ]]
    then
        return 1
    fi
    printf '%s' "${upn}"
}

# (b) Jamf Connect — prefer the state plist, fall back to the ID-token file.
get_upn_from_jamf_connect() {
    local state_plist="/Users/${CONSOLE_USER}/Library/Preferences/com.jamf.connect.state.plist"
    local upn=""

    if [[ -f "${state_plist}" ]]
    then
        upn=$("${DEFAULTS}" read "${state_plist}" UserPrincipal 2>/dev/null || true)
        if [[ -z "${upn}" ]]
        then
            upn=$("${DEFAULTS}" read "${state_plist}" UserEmail 2>/dev/null || true)
        fi
    fi

    if [[ -z "${upn}" && -s "${TOKEN_PATH}" ]]
    then
        upn=$(decode_jwt_upn "${TOKEN_PATH}" || true)
    fi

    if [[ -z "${upn}" ]]
    then
        return 1
    fi
    printf '%s' "${upn}"
}

# (c) Last resort — local username + configurable domain suffix.
get_upn_from_domain() {
    if [[ -z "${DOMAIN_SUFFIX}" ]]
    then
        return 1
    fi
    printf '%s@%s' "${CONSOLE_USER}" "${DOMAIN_SUFFIX}"
}

# Orchestrator — honors UPN_SOURCE, sets global RESOLVED_UPN.
resolve_upn() {
    local upn=""

    case "${UPN_SOURCE}" in
        psso)
            upn=$(get_upn_from_psso || true)
            ;;
        jamfconnect)
            upn=$(get_upn_from_jamf_connect || true)
            ;;
        domain)
            upn=$(get_upn_from_domain || true)
            ;;
        auto)
            upn=$(get_upn_from_psso || true)
            if [[ -n "${upn}" ]]
            then
                log_info "UPN resolved via PSSO"
            else
                upn=$(get_upn_from_jamf_connect || true)
                if [[ -n "${upn}" ]]
                then
                    log_info "UPN resolved via Jamf Connect"
                else
                    upn=$(get_upn_from_domain || true)
                    if [[ -n "${upn}" ]]
                    then
                        log_info "UPN resolved via username+domain fallback"
                    fi
                fi
            fi
            ;;
        *)
            log_error "Invalid UPN_SOURCE '${UPN_SOURCE}' (expected auto|psso|jamfconnect|domain)"
            exit 4
            ;;
    esac

    # Basic sanity: must look like an email/UPN.
    if [[ -z "${upn}" || "${upn}" != *@*.* ]]
    then
        log_error "Could not resolve a valid Entra UPN for user '${CONSOLE_USER}' (source=${UPN_SOURCE})"
        exit 4
    fi

    RESOLVED_UPN="${upn}"
    log_info "Resolved UPN: ${RESOLVED_UPN}"
}

# ── Marker / receipt helpers ──────────────────────────────────────────────────
read_marker_field() {
    local field="$1"
    if [[ -f "${MARKER_FILE}" ]]
    then
        "${JQ}" -r --arg f "${field}" '.[$f] // empty' "${MARKER_FILE}" 2>/dev/null || true
    fi
}

write_marker() {
    local status="$1"
    local etag="$2"
    local now=""

    "${MKDIR}" -p "${MARKER_DIR}"
    "${CHMOD}" 755 "${MARKER_DIR}"
    now=$("${DATE}" '+%Y-%m-%dT%H:%M:%S')

    "${JQ}" -n \
        --arg upn "${RESOLVED_UPN}" \
        --arg status "${status}" \
        --arg etag "${etag}" \
        --arg date "${now}" \
        --arg mode "${SYNC_MODE}" \
        --arg ver "${SCRIPT_VERSION}" \
        '{upn:$upn, status:$status, mediaEtag:$etag, appliedDate:$date, syncMode:$mode, scriptVersion:$ver}' \
        > "${MARKER_FILE}"

    "${CHMOD}" 644 "${MARKER_FILE}"
    "${CHOWN}" root:wheel "${MARKER_FILE}"
    log_info "Wrote marker (${status}) for ${CONSOLE_USER}: ${MARKER_FILE}"
}

# ── Microsoft Graph ───────────────────────────────────────────────────────────

# base64url of stdin (text or binary): base64 -> url-safe alphabet -> strip pad.
b64url() {
    "${OPENSSL}" enc -base64 -A | "${TR}" '+/' '-_' | "${TR}" -d '='
}

# Build a PS256 client-assertion JWT for certificate auth. Sets global
# GRAPH_ASSERTION (it logs on failure, so its stdout must never be captured).
# Per Microsoft's certificate-credentials spec: header alg=PS256, typ=JWT, and
# x5t#S256 = base64url(SHA-256(cert DER)); claims aud/iss/sub/jti/nbf/exp/iat;
# signature is RSA-PSS/SHA-256. The certificate AND its private key are read from
# the combined CERT_PEM (delivered via the config profile) using process
# substitution, so the private key never touches disk. Verified on macOS system
# LibreSSL 3.3+.
build_graph_assertion() {
    local x5t header payload h_b64 p_b64 signing_input sig now exp jti aud
    now=$("${DATE}" +%s)
    exp=$(( now + 300 ))
    jti=$("${UUIDGEN}")
    aud="${LOGIN_HOST}/${TENANT_ID}/oauth2/v2.0/token"

    # Fail clearly if the PEM has no readable certificate (bad paste, key-only
    # PEM, etc.) instead of hashing empty input and failing later at signing.
    if ! "${OPENSSL}" x509 -in <(printf '%s\n' "${CERT_PEM}") -noout 2>/dev/null
    then
        log_error "CertificatePEM does not contain a readable certificate (need cert + private key in one PEM)"
        return 1
    fi

    x5t=$("${OPENSSL}" x509 -in <(printf '%s\n' "${CERT_PEM}") -outform DER 2>/dev/null \
        | "${OPENSSL}" dgst -sha256 -binary 2>/dev/null | b64url || true)
    if [[ -z "${x5t}" ]]
    then
        log_error "Could not compute x5t#S256 from CertificatePEM"
        return 1
    fi

    header=$("${JQ}" -c -n --arg x5t "${x5t}" '{alg:"PS256", typ:"JWT", "x5t#S256":$x5t}')
    payload=$("${JQ}" -c -n \
        --arg iss "${CLIENT_ID}" \
        --arg aud "${aud}" \
        --arg jti "${jti}" \
        --argjson now "${now}" \
        --argjson exp "${exp}" \
        '{aud:$aud, iss:$iss, sub:$iss, jti:$jti, nbf:$now, exp:$exp, iat:$now}')

    h_b64=$(printf '%s' "${header}" | b64url)
    p_b64=$(printf '%s' "${payload}" | b64url)
    signing_input="${h_b64}.${p_b64}"

    sig=$(printf '%s' "${signing_input}" \
        | "${OPENSSL}" dgst -sha256 -sign <(printf '%s\n' "${CERT_PEM}") \
            -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:digest -binary 2>/dev/null \
        | b64url || true)
    if [[ -z "${sig}" ]]
    then
        log_error "OpenSSL failed to sign the Graph client assertion (check the private key in CertificatePEM)"
        return 1
    fi

    GRAPH_ASSERTION="${signing_input}.${sig}"
    return 0
}

# Sets global ACCESS_TOKEN. Uses certificate (client assertion) when a
# CertificatePEM is present, else a client secret. Returns non-zero on failure.
get_access_token() {
    local body=""
    local http_code=""
    local -a auth_args=()

    if [[ -n "${CERT_PEM}" ]]
    then
        GRAPH_ASSERTION=""
        if ! build_graph_assertion
        then
            return 1
        fi
        auth_args=( --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                    --data-urlencode "client_assertion=${GRAPH_ASSERTION}" )
    elif [[ -n "${CLIENT_SECRET}" ]]
    then
        auth_args=( --data-urlencode "client_secret=${CLIENT_SECRET}" )
    else
        log_error "No Graph auth material available (neither certificate nor client secret)"
        return 1
    fi

    create_temp_file "entra_token"
    body="${TEMP_FILE_PATH}"
    http_code=$("${CURL}" -sS --max-time "${CURL_MAX_TIME}" \
        -o "${body}" -w '%{http_code}' \
        -X POST "${LOGIN_HOST}/${TENANT_ID}/oauth2/v2.0/token" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "scope=${GRAPH_SCOPE}" \
        --data-urlencode "grant_type=client_credentials" \
        "${auth_args[@]}" 2>/dev/null || echo "000")

    if [[ "${http_code}" != "200" ]]
    then
        local err
        err=$("${JQ}" -r '.error // "unknown"' "${body}" 2>/dev/null || echo "unknown")
        log_error "OAuth token request failed (HTTP ${http_code}, error=${err})"
        return 1
    fi

    ACCESS_TOKEN=$("${JQ}" -r '.access_token // empty' "${body}" 2>/dev/null || true)
    if [[ -z "${ACCESS_TOKEN}" ]]
    then
        log_error "OAuth token response contained no access_token"
        return 1
    fi
    log_info "Acquired Graph access token via $(auth_method_label)"
    return 0
}

# Extract "code: message" from a Graph JSON error body (for clearer logging).
graph_error() {
    local body="$1"
    "${JQ}" -r '.error | "\(.code // "?"): \(.message // "?")"' "${body}" 2>/dev/null \
        || printf '%s' "unparseable error body"
}

# Sets global GRAPH_USER_ID. Returns: 0 ok, 2 user-not-found, 1 other error.
resolve_object_id() {
    local body=""
    local http_code=""
    create_temp_file "entra_user"
    body="${TEMP_FILE_PATH}"

    http_code=$("${CURL}" -sS --max-time "${CURL_MAX_TIME}" \
        -o "${body}" -w '%{http_code}' \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${GRAPH_HOST}/users/${RESOLVED_UPN}" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "404" ]]
    then
        log_error "Entra user not found for UPN '${RESOLVED_UPN}' (HTTP 404)"
        return 2
    fi
    if [[ "${http_code}" != "200" ]]
    then
        log_error "Graph user lookup failed (HTTP ${http_code}) — $(graph_error "${body}")"
        if [[ "${http_code}" == "403" ]]
        then
            log_error "403 usually means the app registration lacks 'User.Read.All' (Application) with admin consent. Check API permissions in Entra."
        fi
        return 1
    fi

    GRAPH_USER_ID=$("${JQ}" -r '.id // empty' "${body}" 2>/dev/null || true)
    if [[ -z "${GRAPH_USER_ID}" ]]
    then
        log_error "Graph user lookup returned no object id"
        return 1
    fi
    log_info "Resolved Graph object id for ${RESOLVED_UPN}"
    return 0
}

# Sets global CURRENT_ETAG. Returns: 0 ok, 44 no-photo (404), 1 other error.
get_photo_metadata() {
    local body=""
    local http_code=""
    create_temp_file "entra_photometa"
    body="${TEMP_FILE_PATH}"

    http_code=$("${CURL}" -sS --max-time "${CURL_MAX_TIME}" \
        -o "${body}" -w '%{http_code}' \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${GRAPH_HOST}/users/${GRAPH_USER_ID}/photo" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "404" ]]
    then
        return 44
    fi
    if [[ "${http_code}" != "200" ]]
    then
        log_error "Graph photo metadata request failed (HTTP ${http_code}) — $(graph_error "${body}")"
        return 1
    fi

    CURRENT_ETAG=$("${JQ}" -r '.["@odata.mediaEtag"] // empty' "${body}" 2>/dev/null || true)
    log_debug "Current Entra photo mediaEtag: ${CURRENT_ETAG:-<none>}"
    return 0
}

# Download the photo binary to $1. Returns: 0 ok, 44 no-photo (404), 1 other.
download_photo() {
    local dest="$1"
    local http_code=""

    # NOTE: the '$value' segment must reach Graph literally — escape the '$' so
    # bash does not expand it.
    http_code=$("${CURL}" -sS --max-time "${CURL_MAX_TIME}" \
        -o "${dest}" -w '%{http_code}' \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: image/jpeg" \
        "${GRAPH_HOST}/users/${GRAPH_USER_ID}/photo/\$value" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "404" ]]
    then
        return 44
    fi
    if [[ "${http_code}" != "200" ]]
    then
        log_error "Graph photo download failed (HTTP ${http_code}) — $(graph_error "${dest}")"
        return 1
    fi
    return 0
}

# ── Apply the photo to the local account (dscl + dsimport) ────────────────────
apply_photo() {
    local jpeg_src="$1"
    local pic_dir="${USER_PICTURES_DIR}"
    local pic_path="${pic_dir}/${CONSOLE_USER}.jpg"
    local import_file=""
    local mime=""

    # Validate the download is actually an image before touching the account.
    if [[ ! -s "${jpeg_src}" ]]
    then
        log_error "Downloaded photo is empty; refusing to apply"
        return 1
    fi
    mime=$("${FILE}" --brief --mime-type "${jpeg_src}" 2>/dev/null || echo "")
    if [[ "${mime}" != image/* ]]
    then
        log_error "Downloaded photo is not an image (mime=${mime:-unknown}); refusing to apply"
        return 1
    fi

    # 1. Store the JPEG persistently.
    "${MKDIR}" -p "${pic_dir}"
    "${CHOWN}" root:wheel "${pic_dir}"
    "${CHMOD}" 755 "${pic_dir}"
    "${CP}" -f "${jpeg_src}" "${pic_path}"
    "${CHOWN}" root:wheel "${pic_path}"
    "${CHMOD}" 644 "${pic_path}"

    # 2. Delete existing keys first so the re-create applies reliably.
    if ! "${DSCL}" . delete "/Users/${CONSOLE_USER}" JPEGPhoto 2>/dev/null
    then
        log_debug "No existing JPEGPhoto attribute to delete for ${CONSOLE_USER}"
    fi
    if ! "${DSCL}" . delete "/Users/${CONSOLE_USER}" Picture 2>/dev/null
    then
        log_debug "No existing Picture attribute to delete for ${CONSOLE_USER}"
    fi

    # Point Picture at the stored file (used by some UI surfaces).
    "${DSCL}" . create "/Users/${CONSOLE_USER}" Picture "${pic_path}"

    # 3. Import the binary JPEGPhoto via dsimport (dscl cannot write binary).
    create_temp_file "entra_dsimport"
    import_file="${TEMP_FILE_PATH}"
    {
        printf '%s\n' "0x0A 0x5C 0x3A 0x2C dsRecordTypeStandard:Users 2 dsAttrTypeStandard:RecordName externalbinary:dsAttrTypeStandard:JPEGPhoto"
        printf '%s:%s\n' "${CONSOLE_USER}" "${pic_path}"
    } > "${import_file}"

    if ! "${DSIMPORT}" "${import_file}" /Local/Default M 2>/dev/null
    then
        log_error "dsimport failed to set JPEGPhoto for ${CONSOLE_USER}"
        return 1
    fi

    # Soft verify the attribute now exists.
    if "${DSCL}" . -read "/Users/${CONSOLE_USER}" JPEGPhoto >/dev/null 2>&1
    then
        log_info "Applied Entra photo to local account '${CONSOLE_USER}'"
    else
        log_warn "dsimport reported success but JPEGPhoto is not readable for ${CONSOLE_USER}"
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

# Ensure the dedicated log directory exists before the first log call.
if ! "${MKDIR}" -p "${LOG_DIR}" 2>/dev/null
then
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] Could not create ${LOG_DIR}; continuing with unified log + jamf.log"
fi

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting"

require_root
require_jq
validate_sync_mode

# Safe no-op if no console user (should not happen — this is a post-login step).
if ! CONSOLE_USER=$(get_current_user)
then
    log_warn "No console user logged in — nothing to do, exiting cleanly"
    exit 0
fi
CONSOLE_UID=$("${ID}" -u "${CONSOLE_USER}")
MARKER_FILE="${MARKER_DIR}/${CONSOLE_USER}"
log_info "Console user: ${CONSOLE_USER} (uid ${CONSOLE_UID})"

load_credentials

# Resolve the Entra UPN (sets RESOLVED_UPN or exits 4).
resolve_upn

# ── Early skip: avoid any network call when the decision is already made ──────
marker_status=$(read_marker_field "status")
if [[ -n "${marker_status}" ]]
then
    if [[ "${marker_status}" == "no-photo" ]]
    then
        # A prior 404 recorded no Entra photo — stop retrying in BOTH modes and
        # never touch the existing local picture.
        log_info "Marker shows no Entra photo on file; leaving local picture untouched. Exiting."
        exit 0
    fi
    if [[ "${SYNC_MODE}" == "once" ]]
    then
        # once mode + already applied -> the user's own choice wins forever.
        log_info "once mode and marker present (applied ${marker_status}); not overwriting. Exiting."
        exit 0
    fi
    # sync mode with an existing 'applied' marker falls through to compare etags.
fi

# ── Graph work ────────────────────────────────────────────────────────────────
if ! get_access_token
then
    exit 5
fi

if resolve_object_id
then
    rc=0
else
    rc=$?
fi
if [[ "${rc}" -eq 2 ]]
then
    # User not found is a configuration/UPN issue, not a "no photo" condition;
    # do not poison the marker — surface it so it can be fixed.
    exit 6
elif [[ "${rc}" -ne 0 ]]
then
    exit 6
fi

if get_photo_metadata
then
    rc=0
else
    rc=$?
fi
if [[ "${rc}" -eq 44 ]]
then
    log_info "No Entra photo for ${RESOLVED_UPN} (HTTP 404). Recording marker so future runs skip; local picture untouched."
    write_marker "no-photo" ""
    exit 0
elif [[ "${rc}" -ne 0 ]]
then
    exit 7
fi

# ── Apply/skip decision ──────────────────────────────────────────────────────
# In sync mode with a prior applied marker, only re-apply when the photo changed.
if [[ "${SYNC_MODE}" == "sync" && -n "${marker_status}" ]]
then
    stored_etag=$(read_marker_field "mediaEtag")
    if [[ -n "${stored_etag}" && "${stored_etag}" == "${CURRENT_ETAG}" ]]
    then
        log_info "sync mode: Entra photo unchanged (mediaEtag match). Nothing to do. Exiting."
        exit 0
    fi
    log_info "sync mode: Entra photo changed (stored='${stored_etag:-<none>}' current='${CURRENT_ETAG:-<none>}'). Re-applying."
fi

# ── Download + apply ─────────────────────────────────────────────────────────
create_temp_file "entra_photo"
photo_file="${TEMP_FILE_PATH}"
if download_photo "${photo_file}"
then
    rc=0
else
    rc=$?
fi
if [[ "${rc}" -eq 44 ]]
then
    log_info "Photo metadata existed but \$value returned 404. Recording no-photo marker; local picture untouched."
    write_marker "no-photo" ""
    exit 0
elif [[ "${rc}" -ne 0 ]]
then
    exit 7
fi

if ! apply_photo "${photo_file}"
then
    exit 7
fi

write_marker "applied" "${CURRENT_ETAG}"

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################

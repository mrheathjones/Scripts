#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: JC-Demobilize-Phase-A.sh
# Author: Heath Jones
# Date: 04-23-2026
# Modified: 10-04-2026
# Purpose: Phase A installer for the Jamf Connect demobilization
#          workflow. Self-contained Jamf script payload — writes:
#            * /Library/Application Support/${ORG_NAME}/JCDemobilize/config.plist
#              (creds Phase B reads at runtime; mode 600)
#            * The recurring user-facing nudge script + LaunchDaemon
#              (only when mobile accounts exist on the device)
#            * Phase B script + LaunchDaemon. Phase B fires at install
#              time (RunAtLoad) and every PHASEB_RETRY_INTERVAL seconds
#              (StartInterval) until it self-uninstalls.
# Version: 4.20 - Phase B v2.14: the throwaway dsconfigad password is no
#                 longer written to the logs (redacted); username and
#                 hostname are still logged for audit.
# Version: 4.19 - Renamed to Name-Of-Script.sh convention (Phase A file
#                 only; embedded nudge / Phase B install filenames and
#                 launchd labels are unchanged).
# Version: 4.18 - Public release prep: sanitized identifiers, expert-bash
#                 conformance. Org identity now uses the template
#                 ORG_NAME_FRIENDLY / derived ORG_NAME / ORG_PLIST_DOMAIN
#                 trio; Phase A injects those values into the embedded
#                 nudge and Phase B at write time (inject_org_identity)
#                 so there is one place to set them. Branding asset
#                 paths/URLs are CHANGE_ME placeholders. Logging
#                 functions now follow the dual-log convention (unified
#                 log + /var/log/jamf.log via tee) and still append to
#                 the shared workflow log. Required parameters use
#                 require_param; added Requirements section + preflight
#                 (require_dialog_warn, require_jq_warn). Generated
#                 plists are plutil -lint checked and generated scripts
#                 are bash -n checked before launchd loads them.
#                 Bug fixes:
#                 (1) Nudge v1.8: read_state_value() was called but never
#                     defined, so the force-logout threshold ($11) never
#                     fired. Function added.
#                 (2) Phase B v2.13: dsconfigad's exit code was captured
#                     with `OUT=$(cmd)` + `RC=$?` under set -e, so an
#                     unbind failure killed the script before the
#                     mark_failed / user-message path could run.
#                 (3) Phase B v2.13: the jss_url read and config.plist key
#                     reads aborted under set -e/pipefail when the value
#                     was missing, skipping the intended mark_failed
#                     handling. Now guarded with `|| true`.
#                 (4) reset_authchanger's awk range ended on its own start
#                     line, so only one line of the auth chain was logged.
#                 (5) Phase B token / computer-ID helpers no longer return
#                     data via stdout capture of functions that log; they
#                     set ACCESS_TOKEN / COMPUTER_ID globals instead.
# Version: 4.17 - Two related changes from pilot feedback:
#                 (1) IGNORED_USERS hardcoded array added to Phase A's
#                     User Defined Variables block — local service /
#                     break-glass admin shortnames that this workflow
#                     must never nudge, demobilize, or auto-unlock.
#                     Phase A writes the list into config.plist; both
#                     the embedded nudge and Phase B read it at runtime
#                     so there is one place to maintain it. The
#                     SecureToken admin (parameter $7) is implicitly
#                     ignored — no need to list it separately. The
#                     install-time has_any_mobile_accounts check now
#                     filters ignored users so the nudge daemon isn't
#                     installed on Macs whose only "mobile" accounts
#                     are service accounts.
#                 (2) auto_unlock_locked_mobile_users added to Phase B.
#                     A pilot user kept getting locked out of the
#                     mobile account in the demobilization queue
#                     (AD-side lockout policy + password sync churn),
#                     and the tech workaround — log in as the local
#                     SecureToken admin and unlock manually — was
#                     stalling the workflow because Phase B was waiting
#                     for a console user that could never appear.
#                     Phase B now enumerates non-ignored mobile users,
#                     detects locked-out accounts via `pwpolicy
#                     -authentication-allowed`, and clears the lockout
#                     using the SecureToken admin credentials already
#                     in config.plist. Runs BEFORE wait_for_console_user
#                     so the auto-unlock happens at the StartInterval
#                     tick — worst-case lockout duration is now
#                     PHASEB_RETRY_INTERVAL seconds (default 600).
#                     Unlock events are recorded per-user in state.plist
#                     with a rolling LOCKOUT_LOOP_WINDOW_HOURS window;
#                     once LOCKOUT_LOOP_THRESHOLD unlocks accumulate
#                     within the window, Phase B flags a lockout-loop
#                     status in state.plist for IT review. Unlocking
#                     still happens every time — without it, the
#                     demobilization can never complete.
#                 PWPOLICY added to Phase B's binary list.
# Version: 4.16 - Two pilot fixes that share the same v4.15 root cause:
#                 the BTM "touch can run in the background" notification
#                 was still appearing on Macs upgraded from any prior
#                 build, and after demobilization users saw the macOS
#                 login window instead of JC Login at logout.
#                 (1) Added cleanup_legacy_phaseb_agent() — boots out
#                     the legacy LaunchAgent
#                     (${ORG_PLIST_DOMAIN}.jc-demobilize-phaseB-trigger)
#                     from every active GUI session, removes the plist,
#                     and clears the legacy sentinel files at both
#                     /tmp/jc-demobilize-phaseB.trigger and
#                     /var/run/jc-demobilize-phaseB.trigger. Called
#                     early in main, before bootstrapping the new daemon.
#                     Idempotent — safe on a fresh Mac, safe to re-run.
#                 (2) Fixed reset_authchanger() — the function was
#                     making TWO sequential `authchanger -reset` calls,
#                     and `-reset` is destructive, so the second call
#                     (`-reset -preAuth JamfConnectLogin:DeMobilize,
#                     privileged`) was overwriting the first
#                     (`-reset -JamfConnect`) and leaving the chain
#                     with the macOS login window in place. The function
#                     now makes a single `-reset -JamfConnect` call.
#                     This bug was present from v4.9 through v4.15 and
#                     explains the post-demobilization "I see the macOS
#                     login window" reports throughout pilot.
#                 (3) Companion change in Phase B v2.11 (see Phase B
#                     change log) — re-applies authchanger as the final
#                     step before self-uninstall, so even if something
#                     mutates the auth chain mid-flight (dsconfigad,
#                     sysadminctl) the JC Login window is guaranteed
#                     active when the user logs out next.
#                 Removed the unused TOUCH binary constant left behind
#                 from the v4.15 LaunchAgent removal.
# Version: 4.15 - Removed the Phase B LaunchAgent + sentinel-file
#                 (/tmp/jc-demobilize-phaseB.trigger) trigger machinery.
#                 The agent's `/usr/bin/touch` invocation surfaced a
#                 macOS BTM "touch can run in the background" notification
#                 to every user on every install. Phase B's LaunchDaemon
#                 already fires on RunAtLoad + StartInterval=600 (added
#                 in v4.13), so the agent + WatchPaths trigger was
#                 redundant — the worst-case Phase B delay after a
#                 successful login is now PHASEB_RETRY_INTERVAL seconds
#                 (default 600). Removed: PHASEB_AGENT_LABEL,
#                 PHASEB_AGENT_PATH, PHASEB_TRIGGER_FILE constants;
#                 write_phaseb_launchagent(),
#                 bootstrap_phaseb_agent_for_current_user() functions;
#                 WatchPaths key from the Phase B LaunchDaemon plist;
#                 the LaunchAgent bootout loop in Phase B's
#                 self_uninstall(). The Phase B LaunchDaemon's own BTM
#                 notification is suppressed by the org's
#                 com.apple.servicemanagement.managed payload, scoped
#                 alongside the JC Demobilize config profile (the
#                 profile is removed when Phase B self-uninstalls).
# Version: 4.14 - Phase B static-group removal switched from the modern
#                 Jamf Pro v1 endpoint (PATCH
#                 /api/v1/static-computer-groups/<id> with
#                 removedComputerIds) to the Classic API (PUT
#                 /JSSResource/computergroups/id/<id> with an XML
#                 <computer_deletions> body). The v1 endpoint does NOT
#                 exist on Jamf Pro 11.26.x — every removal call was
#                 returning HTTP 404, leaving demobilized Macs stuck
#                 in the static group forever. Confirmed working
#                 against Jamf Pro 11.26.1 in pilot. The API role still
#                 needs Read + Update Static Computer Groups; the
#                 Classic endpoint accepts the same OAuth bearer token,
#                 so no new credentials are required. Also: every API
#                 helper (OAuth, GET, Classic PUT) now logs the Jamf-
#                 supplied response body on non-2xx so future
#                 permission/auth errors surface inline instead of
#                 requiring a separate curl repro. CAT added to Phase B
#                 binary list (needed by the new error-body logging).
# Version: 4.13 - Phase B LaunchDaemon now fires on three triggers:
#                 RunAtLoad (when bootstrapped), WatchPaths on the
#                 sentinel (LaunchAgent → user login), AND StartInterval
#                 every 600s (PHASEB_RETRY_INTERVAL). This means Phase B
#                 retries automatically without waiting for a login —
#                 fixes the external-demobilize stall and any partial-
#                 failure recovery scenario. Plus
#                 bootstrap_phaseb_agent_for_current_user now boots out
#                 stale agent loads first and captures the actual
#                 launchctl error message when bootstrap fails.
# Version: 4.12 - Real fix for the AD unbind: macOS requires `-u`/`-p`
#                 with `dsconfigad -remove -force` but doesn't actually
#                 authenticate them. Phase B now fabricates throwaway
#                 per-device credentials (username =
#                 "svc_demobilze_users_<LocalHostName>", password =
#                 24-byte openssl random) at unbind time and logs both
#                 in the workflow log for audit. No new Jamf script
#                 parameters needed — params unchanged from v4.11.
# Version: 4.11 - Phase B now captures dsconfigad's stderr on unbind
#                 failure and logs the actual error message + exit
#                 code, rather than discarding it.
# Version: 4.10 - CRITICAL bug fix: PHASEB_TRIGGER_FILE moved from
#                /var/run/ to /tmp/. The LaunchAgent runs in user
#                context and was attempting to `touch` the sentinel
#                file in /var/run/ — which is root-owned and not
#                user-writable. The touch failed with permission
#                denied, the LaunchAgent exited with code 1, the
#                sentinel file was never created, the LaunchDaemon
#                WatchPaths never fired, and Phase B never ran. This
#                bug existed since the LaunchAgent + WatchPaths
#                architecture was added in v4.0 — Phase B has never
#                actually fired in any test. /tmp is world-writable
#                with sticky bit and is the standard macOS location
#                for transient inter-process trigger files; both user
#                context and root context can write to it.
# Version: 4.9 - Two fixes after the first real test run:
#                 (1) reset_authchanger now uses `-JamfConnectLogin`
#                     instead of `-preAuth JamfConnectLogin:DeMobilize,
#                     privileged`. The -preAuth form does NOT replace
#                     the macOS login window — it only adds DeMobilize
#                     as a follow-up mech. Result: users saw the macOS
#                     login window instead of JC Login, the demobilize
#                     mech ran out of order and hit a compose failure,
#                     and the user was left partially mobile. The new
#                     command replaces loginwindow:login with JC Login's
#                     auth UI; demobilization happens cleanly during
#                     login when DemobilizeUsers=true is set in the
#                     profile.
#                 (2) log_info/warn/error/debug now also echo to
#                     stdout (info/debug) and stderr (warn/error), so
#                     every Phase A log line lands in /var/log/jamf.log
#                     via Jamf's policy stdout capture. The same
#                     change in the embedded nudge and Phase B
#                     populates their LaunchDaemon stdout/stderr logs
#                     (previously empty). reset_authchanger also dumps
#                     the resulting `authchanger -print` chain to the
#                     log so an audit trail proves what was installed.
# Version: 4.8 - Bug fix: the nudge was incorrectly checking JC Login /
#                JC Demobilize profile presence by grep'ing `profiles
#                show` for a specific payload identifier. Profile
#                identifiers vary per org and almost never match the
#                preference domain — this caused the nudge to silently
#                skip on Macs where the JC profiles WERE installed.
#                Replaced with a managed-prefs file existence check
#                plus the existing DemobilizeUsers=true check, which
#                together prove the profiles are delivering correctly.
#                Removed JC_LOGIN_PROFILE_ID, JC_DEMOBILIZE_PROFILE_ID,
#                and is_profile_installed() — no longer needed.
# Version: 4.7 - swiftDialog branding (APP_NAME, banner local/URL,
#                icon local/URL) is now a single source of truth at
#                the top of Phase A's User Defined Variables. Phase A
#                writes the values into config.plist; both embedded
#                scripts read them at startup. Editing branding no
#                longer requires hunting through the heredocs.
# Version: 4.6 - Added a force-logout threshold (parameter $11, in
#                days). The friendly nudge now shows the user how many
#                days they have remaining before automatic logout.
#                When the threshold is crossed, the nudge skips its
#                friendly dialog and instead shows a 5-minute
#                "logging out now" countdown, then forces logout
#                regardless of user input. Threshold = 0 (default)
#                disables the feature entirely (no enforcement, no
#                "days remaining" line).
# Version: 4.5 - Three pre-fleet hardening fixes:
#                 (1) Phase B now takes a mkdir-based lock at startup
#                     so concurrent fires from rapid WatchPaths events
#                     can't race on state, elevation, or API calls.
#                 (2) The SecureToken admin demote is now driven from
#                     Phase B's cleanup trap, so SIGTERM/SIGINT or any
#                     mid-flight error path still demotes the account
#                     (no leaked elevation).
#                 (3) bootstrap_phaseb_agent_for_current_user skips
#                     system / service console users (underscore-
#                     prefixed accounts, daemon, nobody) so Phase B
#                     never fires against a non-real user.
# Version: 4.4 - If JC Login isn't installed when Phase A runs, fall
#                back to `jamf policy -event <trigger>` to invoke a
#                separate install policy. The trigger name is passed
#                via parameter $10. Requires JC Login to be present
#                after the trigger runs; hard-fail otherwise.
# Version: 4.3 - Phase A now confirms Jamf Connect Login is installed
#                (looks for /usr/local/bin/authchanger) and resets the
#                authchanger to enforce the JC Login window with the
#                Demobilize preAuth mech. The JC Login pkg is expected
#                to be installed earlier in the same policy.
# Version: 4.2 - Embedded nudge + Phase B now follow the swiftdialog
#                skill conventions: full branding block (APP_NAME,
#                ORG_NAME, brandingBanner, appIcon, size constants),
#                run_dialog wrapper, --bannertext / --bannerimage on
#                every dialog. Phase B now elevates the SecureToken
#                admin from standard to admin before grant_secure_token
#                and demotes back to standard afterwards (security
#                hygiene). DIALOG renamed to DIALOG_BIN per swiftdialog
#                convention. Dropped AD binding account parameters
#                ($7/$8) and config keys — `dsconfigad -remove -force`
#                is local-only and never contacts a DC, so the binding
#                creds were dead weight. Phase A parameters now stop
#                at $9 (static group ID).
# Version: 4.1 - Removed AD DC reachability gate. AD unbind uses
#                dsconfigad -remove -force (local-only) and runs
#                regardless of network state — a separate process
#                cleans up stale AD computer objects. Phase B now
#                only waits on Jamf URL reachability, which is the
#                one step that genuinely needs network.
# Version: 4.0 - Phase A now also writes Phase B artifacts (script,
#                LaunchAgent, LaunchDaemon) and a creds config.plist.
#                Phase B is fired by a sentinel-file LaunchAgent +
#                WatchPaths LaunchDaemon — no Jamf login trigger
#                dependency. Self-uninstalls (incl. config.plist)
#                on success.
# Version: 3.1 - Detect Macs already demobilized outside this workflow.
# Version: 3.0 - Embedded nudge inline via heredoc so the installer
#                ships as a single Jamf script payload.
# Version: 2.0 - Converted from single-prompt to recurring-nudge
#                installer.
# Version: 1.0 - Initial Script
#
# Requirements:
#   - Runs as root (Jamf policy script payload)
#   - Jamf Connect Login installed (/usr/local/bin/authchanger), or $10 set
#     to a custom trigger for a policy that installs it
#   - Jamf binary at /usr/local/bin/jamf (needed for the $10 fallback and
#     Phase B's recon)
#   - swiftDialog at /usr/local/bin/dialog (used by the nudge and Phase B;
#     Phase A only warns if it is missing at install time)
#   - jq (ships with macOS 15+; Phase B requires it, Phase A warns if absent)
#   - Jamf Connect Login config profile with DemobilizeUsers=true
#   - Jamf Pro API client: Read Computers, Read + Update Static Computer Groups
#   - Jamf parameter $4: nudge interval in seconds (optional, default 7200, min 300)
#   - Jamf parameter $5: Jamf Pro API client ID (required)
#   - Jamf parameter $6: Jamf Pro API client secret (required)
#   - Jamf parameter $7: local SecureToken admin username (required)
#   - Jamf parameter $8: local SecureToken admin password (required)
#   - Jamf parameter $9: demobilization static computer group ID (required)
#   - Jamf parameter $10: JC Login install policy custom trigger (optional)
#   - Jamf parameter $11: force-logout threshold in days (optional, 0 = off)
#   - Network: the Mac's Jamf Pro URL (read from com.jamfsoftware.jamf)
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

# readonly NAME=$(which ...) and local log_msg="$(date ...)" are the house
# template pattern; masking those return values is intentional.
# shellcheck disable=SC2155
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
# shellcheck disable=SC2034 # template core binary; kept for consistency
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY: human-readable display name; MAY contain spaces. Used for
#   user-facing text and swiftDialog banners. e.g. "Example Corp".
# ORG_NAME: path-safe — ORG_NAME_FRIENDLY with spaces removed — for filesystem
#   paths like /Library/Application Support/${ORG_NAME}/ and /Library/Logs/${ORG_NAME}/.
# ORG_PLIST_DOMAIN: reverse-DNS — used for LOG_LABEL, LaunchDaemon labels.
#   e.g. "com.example".
# Phase A injects these values into the embedded nudge and Phase B scripts
# when it writes them, so set them ONLY here.
readonly ORG_NAME_FRIENDLY="Company Name"    # CHANGE_ME: your org display name
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"      # CHANGE_ME: your org reverse-DNS prefix

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="4.20"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.jc-demobilize-phaseA"
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
readonly LAUNCHCTL=$(which launchctl)
readonly MKDIR=$(which mkdir)
readonly CHMOD=$(which chmod)
readonly CHOWN=$(which chown)
readonly DIRNAME=$(which dirname)
readonly CAT=$(which cat)
readonly DSCL=$(which dscl)
readonly SED=$(which sed)
readonly GREP=$(which grep)
readonly PLUTIL=$(which plutil)
readonly BASH_BIN=$(which bash)
readonly JQ=$(which jq 2>/dev/null || true)
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly DIALOG_BIN="/usr/local/bin/dialog"
# AUTHCHANGER ships with the Jamf Connect Login pkg. Expected to be
# present by the time this script runs — either because the JC Login
# pkg is installed earlier in the same Jamf policy, or because Phase A
# triggers a separate install policy via PARAM_JCLOGIN_TRIGGER (below).
readonly AUTHCHANGER="/usr/local/bin/authchanger"
readonly JAMF="/usr/local/bin/jamf"

# Jamf script parameters ($1-$3 reserved by Jamf)
# $4  = Nudge interval in seconds (optional; default 7200 = 2 hours)
# $5  = Jamf Pro OAuth client ID
# $6  = Jamf Pro OAuth client secret
# $7  = Local SecureToken admin username
# $8  = Local SecureToken admin password
# $9  = Demobilization static computer group ID
# $10 = Custom event trigger that installs Jamf Connect Login (used
#       only as a fallback if JC Login isn't already installed when
#       this script runs). Optional — leave empty if JC Login is
#       guaranteed to be installed by an earlier step in this policy.
# $11 = Force-logout threshold in days. When the user has been nudged
#       for >= this many days without converting, the nudge skips its
#       friendly dialog and shows a 5-minute force-logout warning
#       instead. 0 (default) disables enforcement.
#
# Note: AD binding account creds are NOT required as script parameters.
# `dsconfigad -remove -force` requires `-u`/`-p` arguments to be present
# but doesn't actually authenticate them — Phase B fabricates throwaway
# per-device credentials at unbind time and logs them.
readonly PARAM_NUDGE_INTERVAL="${4:-7200}"
readonly PARAM_CLIENT_ID="${5:-}"
readonly PARAM_CLIENT_SECRET="${6:-}"
readonly PARAM_ST_ADMIN_USER="${7:-}"
readonly PARAM_ST_ADMIN_PASS="${8:-}"
readonly PARAM_STATIC_GROUP_ID="${9:-}"
readonly PARAM_JCLOGIN_TRIGGER="${10:-}"
readonly PARAM_FORCE_LOGOUT_DAYS="${11:-0}"

# ── Ignored users (local service / break-glass admin accounts) ───────────────
# Shortnames listed here are skipped by the nudge, by Phase B's
# demobilization gate, and by the auto-unlock routine. Use this for local
# IT service accounts and any other account that must never be touched
# by this workflow. One entry per line, quoted, no trailing comma. The
# SecureToken admin (PARAM_ST_ADMIN_USER) is auto-ignored — do NOT list
# it here, the embedded scripts will treat it as ignored by virtue of
# being the admin used to perform privileged operations.
#
# Phase A writes this list into config.plist; the embedded nudge and
# Phase B read it from there at runtime, so a Mac upgraded with a new
# build of Phase A picks up changes the next time the policy runs.
readonly IGNORED_USERS=(
    # "svc.localadmin"
    # "svc.jamf"
    # "svc.helpdesk"
)

# ── Lockout-loop detection ───────────────────────────────────────────────────
# Phase B auto-unlocks any non-ignored mobile user whose account is
# locked, using the SecureToken admin credentials in config.plist. To
# surface persistent lockouts to IT (e.g. an upstream AD policy that
# keeps re-locking the same user), Phase B tracks a per-user unlock
# count in state.plist over a rolling time window. When the count
# reaches the threshold within the window, Phase B writes a
# lockout-loop alert into state.plist. Unlocking still happens every
# time — these constants ONLY control when the alert fires.
readonly LOCKOUT_LOOP_THRESHOLD=3
readonly LOCKOUT_LOOP_WINDOW_HOURS=24

# Deploy paths (derived from ORG_NAME)
readonly STATE_DIR="/Library/Application Support/${ORG_NAME}/JCDemobilize"
readonly STATE_PLIST="${STATE_DIR}/state.plist"
readonly CONFIG_PLIST="${STATE_DIR}/config.plist"

# Nudge artifacts
readonly NUDGE_SCRIPT_PATH="${STATE_DIR}/JC_Demobilize_Nudge.sh"
readonly NUDGE_LAUNCHD_LABEL="${ORG_PLIST_DOMAIN}.jc-demobilize-nudge"
readonly NUDGE_LAUNCHD_PATH="/Library/LaunchDaemons/${NUDGE_LAUNCHD_LABEL}.plist"

# Phase B artifacts
readonly PHASEB_SCRIPT_PATH="${STATE_DIR}/JC_Demobilize_PhaseB.sh"
readonly PHASEB_DAEMON_LABEL="${ORG_PLIST_DOMAIN}.jc-demobilize-phaseB"
readonly PHASEB_DAEMON_PATH="/Library/LaunchDaemons/${PHASEB_DAEMON_LABEL}.plist"
# Phase B's LaunchDaemon fires on two triggers:
#   1. RunAtLoad (when Phase A bootstraps the daemon)
#   2. StartInterval — every PHASEB_RETRY_INTERVAL seconds
# The interval-based firing means Phase B retries automatically
# without needing a login, and the external-demobilize path doesn't
# stall when no user happens to be logging in. The previous
# LaunchAgent + WatchPaths trigger (sentinel-file at user login) was
# removed in v4.15 — it triggered a "touch can run in the background"
# BTM notification on every install, and the StartInterval covers the
# same wake-up case within at most PHASEB_RETRY_INTERVAL seconds.
readonly PHASEB_RETRY_INTERVAL=600

# ── swiftDialog branding (single source of truth) ────────────────────────────
# These values are written into config.plist by write_config_plist; the
# embedded nudge and Phase B read them at startup. To rebrand or change
# the asset URLs, edit ONLY here — not inside the embedded heredocs.
readonly APP_NAME="JC Demobilize"
readonly BRANDING_BANNER_LOCAL="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/banner.jpg"    # CHANGE_ME: local banner image path; empty = use URL only
readonly BRANDING_BANNER_URL="https://example.com/branding/banner.jpg"    # CHANGE_ME: online fallback banner URL
readonly APP_ICON_LOCAL="/Library/Application Support/${ORG_NAME}/YOUR_BRANDING_SUBPATH/icon.png"    # CHANGE_ME: local app icon path; empty = use URL only
readonly APP_ICON_URL="https://example.com/branding/icon.png"    # CHANGE_ME: online fallback icon URL (your Jamf Self Service icon URL works well)

# Logs
readonly LOG_FILE="/Library/Logs/${ORG_NAME}/jc-demobilize.log"
readonly NUDGE_STDOUT_LOG="/Library/Logs/${ORG_NAME}/jc-demobilize-nudge.stdout.log"
readonly NUDGE_STDERR_LOG="/Library/Logs/${ORG_NAME}/jc-demobilize-nudge.stderr.log"
readonly PHASEB_STDOUT_LOG="/Library/Logs/${ORG_NAME}/jc-demobilize-phaseB.stdout.log"
readonly PHASEB_STDERR_LOG="/Library/Logs/${ORG_NAME}/jc-demobilize-phaseB.stderr.log"

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
# Dual-log: unified log (logger) + /var/log/jamf.log (tee, which also echoes
# to stdout for the Jamf policy log). Each line is also appended to the
# shared workflow log (LOG_FILE) that Phase A, the nudge, and Phase B all
# write to.
append_workflow_log() {
    printf '%s\n' "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

log_info() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_debug() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
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

ensure_log_file() {
    local log_dir
    log_dir=$("${DIRNAME}" "${LOG_FILE}")

    if [[ ! -d "${log_dir}" ]]
    then
        "${MKDIR}" -p "${log_dir}"
        "${CHMOD}" 755 "${log_dir}"
    fi

    if [[ ! -f "${LOG_FILE}" ]]
    then
        : > "${LOG_FILE}"
        "${CHMOD}" 644 "${LOG_FILE}"
    fi
}

ensure_state_dir() {
    if [[ ! -d "${STATE_DIR}" ]]
    then
        "${MKDIR}" -p "${STATE_DIR}"
    fi
    "${CHOWN}" root:wheel "${STATE_DIR}"
    "${CHMOD}" 755 "${STATE_DIR}"
}

validate_interval() {
    local value="$1"

    if [[ ! "${value}" =~ ^[0-9]+$ ]]
    then
        log_error "Parameter 4 (nudge interval) must be a positive integer of seconds — got '${value}'"
        return 1
    fi

    if [[ "${value}" -lt 300 ]]
    then
        log_error "Nudge interval ${value}s is too short (minimum 300s)"
        return 1
    fi
}

# swiftDialog is needed by the nudge and Phase B at runtime, not by Phase A
# itself. Documented fallback: warn at install time; the nudge logs an
# error and skips prompting until swiftDialog is installed.
require_dialog_warn() {
    if [[ ! -x "${DIALOG_BIN}" ]]
    then
        log_warn "swiftDialog not found at ${DIALOG_BIN} — the nudge and Phase B dialogs will not display until it is installed"
    fi
}

# jq is required by Phase B (Jamf API JSON parsing). Documented fallback:
# warn at install time; Phase B marks the workflow Failed (step
# "preflight") until jq is present.
require_jq_warn() {
    if [[ -z "${JQ}" || ! -x "${JQ}" ]]
    then
        log_warn "jq not found in PATH — Phase B will mark the workflow Failed until jq is installed (macOS 15+ ships /usr/bin/jq)"
    fi
}

# ── Generated-file validation ────────────────────────────────────────────────
# Embedded scripts are written from quoted heredocs, so ORG identity is
# injected afterwards by replacing tokens. Keeps a single source of truth
# for ORG_NAME_FRIENDLY / ORG_PLIST_DOMAIN in Phase A's Core variables.
sed_escape_replacement() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//|/\\|}"
    s="${s//&/\\&}"
    SED_ESCAPED="${s}"
}

inject_org_identity() {
    local target_file="$1"
    local friendly_escaped
    local domain_escaped

    sed_escape_replacement "${ORG_NAME_FRIENDLY}"
    friendly_escaped="${SED_ESCAPED}"
    sed_escape_replacement "${ORG_PLIST_DOMAIN}"
    domain_escaped="${SED_ESCAPED}"

    if ! "${SED}" -i '' \
        -e "s|YOUR_ORG_NAME_FRIENDLY_INJECTED|${friendly_escaped}|g" \
        -e "s|YOUR_ORG_PLIST_DOMAIN_INJECTED|${domain_escaped}|g" \
        "${target_file}"
    then
        log_error "Failed to inject org identity into ${target_file}"
        return 1
    fi

    if "${GREP}" -q "YOUR_ORG_NAME_FRIENDLY_INJECTED\|YOUR_ORG_PLIST_DOMAIN_INJECTED" "${target_file}"
    then
        log_error "Org identity tokens remain in ${target_file} after injection"
        return 1
    fi
}

validate_generated_script() {
    local target_file="$1"
    local syntax_output

    if ! syntax_output=$("${BASH_BIN}" -n "${target_file}" 2>&1)
    then
        log_error "Generated script failed bash -n: ${target_file} — ${syntax_output}"
        return 1
    fi
}

validate_generated_plist() {
    local target_file="$1"
    local lint_output

    if ! lint_output=$("${PLUTIL}" -lint "${target_file}" 2>&1)
    then
        log_error "Generated plist failed plutil -lint: ${target_file} — ${lint_output}"
        return 1
    fi
}

# ── Jamf Connect Login ───────────────────────────────────────────────────────
# Confirms JC Login is installed and resets authchanger so the JC Login
# window is enforced with the Demobilize preAuth mechanism. The JC Login
# pkg is installed earlier in the same Jamf policy that runs this script.
is_jamf_connect_login_installed() {
    if [[ -x "${AUTHCHANGER}" ]]
    then
        return 0
    fi
    return 1
}

# Fall back to triggering a separate Jamf policy that installs JC Login.
# Used when JC Login isn't present at script start. PARAM_JCLOGIN_TRIGGER
# must hold the custom event name of an install policy in your Jamf Pro
# instance. Returns 0 if `jamf policy -event` succeeded AND JC Login is
# now installed; returns 1 otherwise.
install_jamf_connect_login() {
    if [[ -z "${PARAM_JCLOGIN_TRIGGER}" ]]
    then
        log_error "JC Login is not installed and parameter \$10 (PARAM_JCLOGIN_TRIGGER) is empty"
        log_error "Either install JC Login earlier in this policy, or set the install trigger parameter"
        return 1
    fi

    if [[ ! -x "${JAMF}" ]]
    then
        log_error "Jamf binary not found at ${JAMF} — cannot trigger install policy"
        return 1
    fi

    log_warn "JC Login not installed — triggering install policy '${PARAM_JCLOGIN_TRIGGER}'"
    if ! "${JAMF}" policy -event "${PARAM_JCLOGIN_TRIGGER}" >/dev/null 2>&1
    then
        log_error "jamf policy -event ${PARAM_JCLOGIN_TRIGGER} returned non-zero"
        return 1
    fi

    if ! is_jamf_connect_login_installed
    then
        log_error "JC Login still not installed after triggering '${PARAM_JCLOGIN_TRIGGER}'"
        log_error "Verify the install policy is enabled, scoped to this Mac, and uses that trigger"
        return 1
    fi

    log_info "JC Login installed via custom trigger '${PARAM_JCLOGIN_TRIGGER}'"
    return 0
}

reset_authchanger() {
    local authchanger_output

    log_info "Resetting authchanger to install JC Login as the login window"
    log_info "Running: ${AUTHCHANGER} -reset -JamfConnect"

    # -JamfConnect REPLACES the macOS loginwindow:login mech with JC
    # Login's auth UI mechs. With DemobilizeUsers=true in the JC Login
    # config profile, JC Login demobilizes the user during their login
    # automatically.
    #
    # Do NOT chain a second call like
    # `authchanger -reset -preAuth JamfConnectLogin:DeMobilize,privileged`
    # afterwards — `-reset` is destructive, so a second call overwrites
    # the JC Login chain and leaves the macOS login window in place.
    # That bug existed in v4.9–v4.15 and was the reason Macs reverted to
    # the macOS login window after Phase B finished. Single call only.
    if ! authchanger_output=$("${AUTHCHANGER}" -reset -JamfConnect 2>&1)
    then
        log_error "authchanger -reset -JamfConnect failed: ${authchanger_output}"
        return 1
    fi

    log_info "authchanger reset complete — JC Login window will be active at next login"

    # Echo the new auth chain into the log so we have audit-trail proof
    # of what actually got installed.
    log_info "Active login mechs after reset:"
    # Print from the system.login.console entry up to (not including) the
    # next "Entry:" header. A plain awk range (/start/,/^Entry:/) ends on
    # its own start line because that line also matches the end pattern.
    "${AUTHCHANGER}" -print 2>/dev/null \
        | "${AWK}" '/^Entry: system.login.console/ { in_entry = 1; print; next } /^Entry:/ { in_entry = 0 } in_entry { print }' \
        | while IFS= read -r line
          do
              log_info "  ${line}"
          done

    return 0
}

# ── Mobile account discovery ─────────────────────────────────────────────────
# Returns 0 if ${user} matches any entry in IGNORED_USERS or is the
# SecureToken admin (auto-ignored). Used by has_any_mobile_accounts to
# decide whether to install the nudge daemon — if every mobile account
# on the Mac is in the ignore list, there's nothing for the nudge to
# do. The embedded nudge and Phase B have their own copies of this
# check that read from config.plist; this install-time variant reads
# directly from the Phase A globals.
is_ignored_user_install() {
    local user="$1"
    local entry

    if [[ -n "${PARAM_ST_ADMIN_USER}" && "${user}" == "${PARAM_ST_ADMIN_USER}" ]]
    then
        return 0
    fi

    for entry in "${IGNORED_USERS[@]:-}"
    do
        if [[ -n "${entry}" && "${user}" == "${entry}" ]]
        then
            return 0
        fi
    done

    return 1
}

has_any_mobile_accounts() {
    local listing
    local user

    if ! listing=$("${DSCL}" . -list /Users OriginalNodeName 2>/dev/null)
    then
        return 1
    fi

    while IFS= read -r line
    do
        # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
        user=$("${AWK}" '{ print $1 }' <<< "${line}")

        if [[ -z "${user}" ]]
        then
            continue
        fi

        case "${user}" in
            _*|daemon|nobody|root)
                continue
                ;;
        esac

        if is_ignored_user_install "${user}"
        then
            continue
        fi

        return 0
    done <<< "${listing}"

    return 1
}

# ── External demobilization receipt ──────────────────────────────────────────
write_external_demobilize_state() {
    if [[ -f "${STATE_PLIST}" ]]
    then
        "${RM}" -f "${STATE_PLIST}"
    fi

    "${PLIST_BUDDY}" -c "Add :phase string A_complete" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :status string In Progress" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :step string External demobilization detected — awaiting AD unbind & static group removal" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :username string external" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :detected_externally bool true" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :started_at string $("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')" "${STATE_PLIST}"
    "${CHMOD}" 644 "${STATE_PLIST}"

    log_info "Wrote external-demobilization receipt to ${STATE_PLIST}"
}

# ── XML escape helper for config.plist values ────────────────────────────────
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "${s}"
}

# ── config.plist (creds for Phase B, mode 600) ───────────────────────────────
write_config_plist() {
    local cid sec su sp gid days
    local app_name_xml bb_local_xml bb_url_xml icon_local_xml icon_url_xml
    local ignored_users_xml entry

    cid=$(xml_escape "${PARAM_CLIENT_ID}")
    sec=$(xml_escape "${PARAM_CLIENT_SECRET}")
    su=$(xml_escape "${PARAM_ST_ADMIN_USER}")
    sp=$(xml_escape "${PARAM_ST_ADMIN_PASS}")
    gid=$(xml_escape "${PARAM_STATIC_GROUP_ID}")
    # Coerce non-numeric input to 0 so the embedded nudge's integer
    # comparison never blows up.
    if [[ "${PARAM_FORCE_LOGOUT_DAYS}" =~ ^[0-9]+$ ]]
    then
        days="${PARAM_FORCE_LOGOUT_DAYS}"
    else
        days="0"
    fi

    # Branding values (consumed by both embedded scripts at runtime).
    app_name_xml=$(xml_escape "${APP_NAME}")
    bb_local_xml=$(xml_escape "${BRANDING_BANNER_LOCAL}")
    bb_url_xml=$(xml_escape "${BRANDING_BANNER_URL}")
    icon_local_xml=$(xml_escape "${APP_ICON_LOCAL}")
    icon_url_xml=$(xml_escape "${APP_ICON_URL}")

    # Build the ignored_users array XML fragment. Empty IGNORED_USERS
    # produces an empty <array> element — still valid plist, still
    # iterable by PlistBuddy index lookups in the embedded scripts.
    ignored_users_xml=""
    for entry in "${IGNORED_USERS[@]:-}"
    do
        if [[ -n "${entry}" ]]
        then
            ignored_users_xml+="        <string>$(xml_escape "${entry}")</string>"$'\n'
        fi
    done

    if [[ -f "${CONFIG_PLIST}" ]]
    then
        "${RM}" -f "${CONFIG_PLIST}"
    fi

    "${CAT}" > "${CONFIG_PLIST}" <<CONFIG_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>jamf_client_id</key>
    <string>${cid}</string>
    <key>jamf_client_secret</key>
    <string>${sec}</string>
    <key>st_admin_user</key>
    <string>${su}</string>
    <key>st_admin_pass</key>
    <string>${sp}</string>
    <key>static_group_id</key>
    <string>${gid}</string>
    <key>force_logout_days</key>
    <integer>${days}</integer>
    <key>app_name</key>
    <string>${app_name_xml}</string>
    <key>branding_banner_local</key>
    <string>${bb_local_xml}</string>
    <key>branding_banner_url</key>
    <string>${bb_url_xml}</string>
    <key>app_icon_local</key>
    <string>${icon_local_xml}</string>
    <key>app_icon_url</key>
    <string>${icon_url_xml}</string>
    <key>ignored_users</key>
    <array>
${ignored_users_xml}    </array>
    <key>lockout_loop_threshold</key>
    <integer>${LOCKOUT_LOOP_THRESHOLD}</integer>
    <key>lockout_loop_window_hours</key>
    <integer>${LOCKOUT_LOOP_WINDOW_HOURS}</integer>
</dict>
</plist>
CONFIG_EOF

    "${CHOWN}" root:wheel "${CONFIG_PLIST}"
    "${CHMOD}" 600 "${CONFIG_PLIST}"

    if ! validate_generated_plist "${CONFIG_PLIST}"
    then
        return 1
    fi

    log_info "Wrote credential config to ${CONFIG_PLIST} (mode 600)"
}

# ── Embedded nudge script (quoted heredoc — content is literal) ──────────────
write_nudge_script() {
    "${CAT}" > "${NUDGE_SCRIPT_PATH}" <<'NUDGE_EOF'
#! /bin/bash

######################################################################
# Name: JC_Demobilize_Nudge.sh
# Purpose: Recurring user nudge deployed by Phase A.
# Version: 1.8 - Public release prep: sanitized identifiers, expert-bash
#                conformance. ORG identity tokens are injected by Phase A
#                at write time; dual-log functions (unified log + jamf.log
#                via tee + shared workflow log); swiftDialog banner text
#                uses ORG_NAME_FRIENDLY.
#                Bug fix: read_state_value() was called by the
#                force-logout check but never defined, so the threshold
#                never fired. Function added.
# Version: 1.7 - Ignored-user list is now read from config.plist (key
#                :ignored_users) instead of the previously-empty
#                hardcoded SERVICE_ACCOUNTS array. Phase A's User
#                Defined Variables block is the single source of
#                truth — see the IGNORED_USERS array there. The
#                SecureToken admin (config :st_admin_user) is also
#                auto-ignored so the nudge never targets the account
#                techs use to unlock locked-out users. SYSTEM_ACCOUNTS
#                (root/daemon/nobody/_*) check is unchanged.
# Version: 1.6 - log_* functions now also echo to stdout/stderr so
#                their output appears in the LaunchDaemon's
#                StandardOutPath / StandardErrorPath log files
#                (jc-demobilize-nudge.std{out,err}.log) instead of
#                only the unified log + jc-demobilize.log.
# Version: 1.5 - Bug fix: dropped the buggy is_profile_installed()
#                checks that compared profile payload identifiers
#                against a hardcoded preference-domain string. Now
#                gates on managed-prefs file existence + the existing
#                DemobilizeUsers=true check, which is what actually
#                matters.
# Version: 1.4 - swiftDialog branding (APP_NAME, banner, icon) read
#                from config.plist instead of being hardcoded. Single
#                source of truth lives in Phase A's User Defined
#                Variables block.
# Version: 1.3 - Reads force_logout_days from config.plist. Friendly
#                nudge shows days remaining when threshold is set;
#                when threshold is reached, nudge replaces the
#                friendly dialog with a 5-minute force-logout warning
#                and force-logs-out at countdown end regardless of
#                user input.
# Version: 1.2 - swiftDialog branding + run_dialog wrapper.
# Version: 1.1 - System / service account exclusion list.
# Version: 1.0 - Initial Script
######################################################################

# readonly NAME=$(which ...) and local log_msg="$(date ...)" are the house
# template pattern; masking those return values is intentional.
# shellcheck disable=SC2155
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck disable=SC2230
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly RM=$(which rm)
readonly SCUTIL=$(which scutil)
readonly DSCL=$(which dscl)
readonly DEFAULTS=$(which defaults)
readonly LAUNCHCTL=$(which launchctl)
readonly SUDO=$(which sudo)
readonly MKDIR=$(which mkdir)
readonly CHMOD=$(which chmod)
readonly DIRNAME=$(which dirname)
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"

# Org identity — tokens replaced by Phase A (inject_org_identity) at write
# time from Phase A's ORG_NAME_FRIENDLY / ORG_PLIST_DOMAIN. Do not edit here.
readonly ORG_NAME_FRIENDLY="YOUR_ORG_NAME_FRIENDLY_INJECTED"
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="YOUR_ORG_PLIST_DOMAIN_INJECTED"
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.8"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.jc-demobilize-nudge"
readonly JAMF_LOG="/var/log/jamf.log"

readonly STATE_DIR="/Library/Application Support/${ORG_NAME}/JCDemobilize"
readonly STATE_PLIST="${STATE_DIR}/state.plist"
readonly CONFIG_PLIST="${STATE_DIR}/config.plist"

# ── swiftDialog branding (read from config.plist; written by Phase A) ────────
# To rebrand, edit Phase A's User Defined Variables block, NOT here. The
# fallbacks in this block apply only if config.plist is missing or hasn't
# been refreshed yet (first nudge tick before Phase A finishes — shouldn't
# happen in practice).
APP_NAME=$("${PLIST_BUDDY}" -c "Print :app_name" "${CONFIG_PLIST}" 2>/dev/null || echo "JC Demobilize")

# Banner — local path first, URL fallback
brandingBanner=$("${PLIST_BUDDY}" -c "Print :branding_banner_local" "${CONFIG_PLIST}" 2>/dev/null || echo "")
if [[ ! -f "${brandingBanner}" ]]
then
    brandingBanner=$("${PLIST_BUDDY}" -c "Print :branding_banner_url" "${CONFIG_PLIST}" 2>/dev/null || echo "")
fi

# App icon — local path first, URL fallback
appIcon=$("${PLIST_BUDDY}" -c "Print :app_icon_local" "${CONFIG_PLIST}" 2>/dev/null || echo "")
if [[ ! -f "${appIcon}" ]]
then
    appIcon=$("${PLIST_BUDDY}" -c "Print :app_icon_url" "${CONFIG_PLIST}" 2>/dev/null || echo "")
fi
# swiftDialog convention constants. Not every size is used by this script;
# they are kept so dialogs stay consistent across the workflow.
# shellcheck disable=SC2034
appIconSize=125

# Constants — not configurable per deployment
DIALOG_BIN="/usr/local/bin/dialog"
# shellcheck disable=SC2034
APP_DIR="/Library/Application Support/${ORG_NAME}/${APP_NAME}"
# shellcheck disable=SC2034
appSizeXSmall=250
appSizeSmall=500
appSizeMedium=650
# shellcheck disable=SC2034
appSizeLarge=800
# shellcheck disable=SC2034
appSizeXLarge=1000
appName="${ORG_NAME_FRIENDLY} - ${APP_NAME}"

readonly MANAGED_PREFS_PLIST="/Library/Managed Preferences/com.jamf.connect.login.plist"
readonly DEMOBILIZE_KEY="DemobilizeUsers"
# NOTE: JC_LOGIN_PROFILE_ID / JC_DEMOBILIZE_PROFILE_ID were removed in v4.8.
# The previous `profiles show | grep <profile-identifier>` check was wrong:
# it looked at profile identifiers (org-specific, e.g. "com.example.jc-login")
# instead of the preference domain. Profiles are detected indirectly by
# checking that the managed preferences plist exists and has
# DemobilizeUsers=true — which is what we actually care about.

# STATE_DIR / STATE_PLIST / CONFIG_PLIST are declared earlier (before
# the branding block) so the PLIST_BUDDY reads can resolve config keys.
readonly NUDGE_SCRIPT_PATH="${STATE_DIR}/JC_Demobilize_Nudge.sh"
readonly NUDGE_LAUNCHD_LABEL="${ORG_PLIST_DOMAIN}.jc-demobilize-nudge"
readonly NUDGE_LAUNCHD_PATH="/Library/LaunchDaemons/${NUDGE_LAUNCHD_LABEL}.plist"
readonly LOG_FILE="/Library/Logs/${ORG_NAME}/jc-demobilize.log"

readonly PROMPT_TIMER_SECONDS=300
readonly LOGOUT_COUNTDOWN_SECONDS=60
readonly FORCE_LOGOUT_COUNTDOWN_SECONDS=300

readonly SYSTEM_ACCOUNTS=(
    "root"
    "daemon"
    "nobody"
)

# Ignored-user shortnames are loaded from config.plist at runtime —
# see is_ignored_user() below. To maintain the list, edit
# IGNORED_USERS in Phase A's User Defined Variables and re-run the
# Phase A policy.

# ── Logging (unified log + jamf.log via tee + shared workflow log) ──────────
append_workflow_log() {
    printf '%s\n' "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

log_info() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_debug() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

require_root() {
    if [[ "$("${ID}" -u)" -ne 0 ]]
    then
        log_error "Must run as root"
        exit 1
    fi
}

ensure_log_file() {
    local log_dir
    log_dir=$("${DIRNAME}" "${LOG_FILE}")
    if [[ ! -d "${log_dir}" ]]
    then
        "${MKDIR}" -p "${log_dir}"
        "${CHMOD}" 755 "${log_dir}"
    fi
}

get_current_user() {
    local console_user
    # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
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

is_system_or_service_account() {
    local user="$1"
    local acct

    if [[ "${user}" == _* ]]
    then
        return 0
    fi

    for acct in "${SYSTEM_ACCOUNTS[@]}"
    do
        if [[ "${user}" == "${acct}" ]]
        then
            return 0
        fi
    done

    if is_ignored_user "${user}"
    then
        return 0
    fi

    return 1
}

# Returns 0 if ${user} is in config.plist's :ignored_users array OR is
# the SecureToken admin (:st_admin_user). The admin is auto-ignored
# because techs use it to unlock locked-out mobile users — nudging it
# would prompt the tech, not the actual mobile user. Reads the array
# by indexed PlistBuddy lookup so it works on macOS Bash 3.2 without
# associative arrays.
is_ignored_user() {
    local user="$1"
    local idx=0
    local entry
    local st_admin

    if [[ ! -f "${CONFIG_PLIST}" ]]
    then
        return 1
    fi

    st_admin=$("${PLIST_BUDDY}" -c "Print :st_admin_user" "${CONFIG_PLIST}" 2>/dev/null || true)
    if [[ -n "${st_admin}" && "${user}" == "${st_admin}" ]]
    then
        return 0
    fi

    while entry=$("${PLIST_BUDDY}" -c "Print :ignored_users:${idx}" "${CONFIG_PLIST}" 2>/dev/null)
    do
        if [[ -n "${entry}" && "${user}" == "${entry}" ]]
        then
            return 0
        fi
        idx=$((idx + 1))
    done

    return 1
}

is_mobile_account() {
    local user="$1"
    local original_node

    if ! original_node=$("${DSCL}" . -read "/Users/${user}" OriginalNodeName 2>/dev/null)
    then
        return 1
    fi

    if [[ -z "${original_node}" ]]
    then
        return 1
    fi
    return 0
}

is_demobilize_configured() {
    local value
    if [[ ! -f "${MANAGED_PREFS_PLIST}" ]]
    then
        return 1
    fi
    if ! value=$("${DEFAULTS}" read "${MANAGED_PREFS_PLIST}" "${DEMOBILIZE_KEY}" 2>/dev/null)
    then
        return 1
    fi
    if [[ "${value}" == "1" || "${value}" == "true" ]]
    then
        return 0
    fi
    return 1
}

write_state() {
    local username="$1"

    if [[ ! -d "${STATE_DIR}" ]]
    then
        "${MKDIR}" -p "${STATE_DIR}"
        "${CHMOD}" 755 "${STATE_DIR}"
    fi

    if [[ -f "${STATE_PLIST}" ]]
    then
        if "${PLIST_BUDDY}" -c "Print :last_nudge" "${STATE_PLIST}" >/dev/null 2>&1
        then
            "${PLIST_BUDDY}" -c "Set :last_nudge $("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')" "${STATE_PLIST}"
        else
            "${PLIST_BUDDY}" -c "Add :last_nudge string $("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')" "${STATE_PLIST}"
        fi
        return 0
    fi

    "${PLIST_BUDDY}" -c "Add :phase string A_complete" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :status string In Progress" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :step string Awaiting logout/login for Jamf Connect demobilization" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :username string ${username}" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :started_at string $("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')" "${STATE_PLIST}"
    "${PLIST_BUDDY}" -c "Add :last_nudge string $("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')" "${STATE_PLIST}"
    "${CHMOD}" 644 "${STATE_PLIST}"
}

run_dialog() {
    local current_user
    local current_uid

    if ! current_user=$(get_current_user)
    then
        return 1
    fi
    current_uid=$(get_current_user_uid "${current_user}")

    "${LAUNCHCTL}" asuser "${current_uid}" "${SUDO}" -u "${current_user}" \
        "${DIALOG_BIN}" "$@" 2>/dev/null
}

read_config_value() {
    local key="$1"
    if [[ ! -f "${CONFIG_PLIST}" ]]
    then
        return 1
    fi
    "${PLIST_BUDDY}" -c "Print :${key}" "${CONFIG_PLIST}" 2>/dev/null
}

# Used by the force-logout threshold check (started_at). Was missing before
# v1.8, which silently disabled force-logout.
read_state_value() {
    local key="$1"
    if [[ ! -f "${STATE_PLIST}" ]]
    then
        return 1
    fi
    "${PLIST_BUDDY}" -c "Print :${key}" "${STATE_PLIST}" 2>/dev/null
}

show_friendly_nudge() {
    local days_remaining="${1:-}"
    local exit_code=0
    local message="Good news — we're updating your logon experience!\n\nThis update makes password resets more consistent and streamlined going forward. To finalize the change on this Mac, please save your work, log out, and log back in. It only takes about a minute."
    local plural_suffix=""

    # Append days-remaining notice when force-logout is enforced and
    # we're still inside the deferral window.
    if [[ -n "${days_remaining}" && "${days_remaining}" -gt 0 ]]
    then
        if [[ "${days_remaining}" -ne 1 ]]
        then
            plural_suffix="s"
        fi
        message="${message}\n\n**Heads up:** This update will be applied automatically in ${days_remaining} day${plural_suffix}. Please log out at your earliest convenience to avoid an automatic logout."
    else
        message="${message}\n\nThanks for helping keep things running smoothly!"
    fi

    run_dialog \
        --height "${appSizeMedium}" \
        --icon "${appIcon}" \
        --overlayicon "SF=sparkles,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${message}" \
        --button1text "Log Out Now" \
        --button2text "Remind Me Later" \
        --timer "${PROMPT_TIMER_SECONDS}" \
        --hidetimerbar \
        --position centre \
        --ontop \
        --moveable \
        --infotext "${LOG_LABEL} v${SCRIPT_VERSION}" \
        || exit_code=$?
    return ${exit_code}
}

# Shown when the force-logout threshold is reached. Single button,
# 5-minute countdown, force_logout fires regardless of what the user
# clicks (or doesn't).
show_force_logout_warning() {
    local exit_code=0
    run_dialog \
        --height "${appSizeMedium}" \
        --icon "${appIcon}" \
        --overlayicon "SF=hourglass.tophalf.filled,colour=red" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "Your account update is now overdue.\n\nYour Mac will log out automatically in **5 minutes** to apply this required update. Please save any open work right now.\n\nWhen you log back in, your account will finish updating automatically." \
        --button1text "Log Out Now" \
        --timer "${FORCE_LOGOUT_COUNTDOWN_SECONDS}" \
        --position centre \
        --ontop \
        --moveable \
        --infotext "${LOG_LABEL} v${SCRIPT_VERSION}" \
        || exit_code=$?
    return ${exit_code}
}

show_logout_countdown() {
    local exit_code=0
    run_dialog \
        --height "${appSizeSmall}" \
        --icon "${appIcon}" \
        --overlayicon "SF=hourglass,colour=orange" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "Your Mac will log out in ${LOGOUT_COUNTDOWN_SECONDS} seconds. Please save any open work now.\n\nClick Cancel if you need more time — we'll remind you again later." \
        --button1text "Log Out Now" \
        --button2text "Cancel" \
        --timer "${LOGOUT_COUNTDOWN_SECONDS}" \
        --hidetimerbar \
        --position centre \
        --ontop \
        --moveable \
        || exit_code=$?
    return ${exit_code}
}

force_logout() {
    local current_user
    local current_uid
    if ! current_user=$(get_current_user)
    then
        return 0
    fi
    current_uid=$(get_current_user_uid "${current_user}")
    log_info "Evicting user ${current_user} (uid ${current_uid}) from GUI session"
    if ! "${LAUNCHCTL}" bootout "gui/${current_uid}" 2>/dev/null
    then
        log_warn "launchctl bootout failed for gui/${current_uid}"
    fi
}

self_uninstall() {
    log_info "Console user is no longer a mobile account — removing nudge LaunchDaemon and script"

    if [[ -f "${NUDGE_LAUNCHD_PATH}" ]]
    then
        "${RM}" -f "${NUDGE_LAUNCHD_PATH}"
    fi

    if [[ -f "${NUDGE_SCRIPT_PATH}" ]]
    then
        "${RM}" -f "${NUDGE_SCRIPT_PATH}"
    fi

    if "${LAUNCHCTL}" print "system/${NUDGE_LAUNCHD_LABEL}" >/dev/null 2>&1
    then
        "${LAUNCHCTL}" bootout "system/${NUDGE_LAUNCHD_LABEL}" 2>/dev/null || true
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
require_root
ensure_log_file

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} nudge tick"

if ! CURRENT_USER=$(get_current_user)
then
    log_debug "No console user — skipping nudge"
    exit 0
fi

if is_system_or_service_account "${CURRENT_USER}"
then
    log_debug "Console user ${CURRENT_USER} is a system/service account — skipping nudge"
    exit 0
fi

if ! is_mobile_account "${CURRENT_USER}"
then
    log_info "Console user ${CURRENT_USER} is not a mobile account — self-uninstalling"
    self_uninstall
    exit 0
fi

# JC Login config profile must be delivering its managed prefs. We check
# the preference plist directly rather than grepping `profiles show` for a
# specific payload identifier — profile identifiers vary per org, but the
# preference domain (com.jamf.connect.login) is standard.
if [[ ! -f "${MANAGED_PREFS_PLIST}" ]]
then
    log_warn "JC Login managed preferences (${MANAGED_PREFS_PLIST}) not present — skipping nudge"
    exit 0
fi

# DemobilizeUsers must be true. This implicitly proves a JC Demobilize
# config profile (or any profile setting that key) is in effect.
if ! is_demobilize_configured
then
    log_warn "User ${CURRENT_USER} is mobile but ${DEMOBILIZE_KEY} is not true in JC Login prefs — skipping nudge"
    exit 0
fi

if [[ ! -x "${DIALOG_BIN}" ]]
then
    log_error "swiftDialog not installed at ${DIALOG_BIN} — cannot prompt"
    exit 1
fi

write_state "${CURRENT_USER}"

# Check the force-logout threshold against how long we've been
# nudging this user. 0 = feature disabled.
FORCE_LOGOUT_DAYS=$(read_config_value "force_logout_days" || echo 0)
if [[ ! "${FORCE_LOGOUT_DAYS}" =~ ^[0-9]+$ ]]
then
    FORCE_LOGOUT_DAYS=0
fi

DAYS_REMAINING=""

if [[ ${FORCE_LOGOUT_DAYS} -gt 0 ]]
then
    STARTED_AT=$(read_state_value "started_at" || true)
    if [[ -n "${STARTED_AT}" ]]
    then
        STARTED_EPOCH=$("${DATE}" -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${STARTED_AT}" "+%s" 2>/dev/null || echo 0)
        if [[ ${STARTED_EPOCH} -gt 0 ]]
        then
            NOW_EPOCH=$("${DATE}" +%s)
            ELAPSED_DAYS=$(( ( NOW_EPOCH - STARTED_EPOCH ) / 86400 ))
            DAYS_REMAINING=$(( FORCE_LOGOUT_DAYS - ELAPSED_DAYS ))

            if [[ ${DAYS_REMAINING} -le 0 ]]
            then
                log_warn "Force-logout threshold reached for ${CURRENT_USER} (elapsed ${ELAPSED_DAYS}d >= threshold ${FORCE_LOGOUT_DAYS}d) — bypassing friendly nudge"
                show_force_logout_warning || true
                force_logout
                log_info "${SCRIPT_NAME} forced logout (threshold reached)"
                exit 0
            fi
        fi
    fi
fi

log_info "Showing nudge to ${CURRENT_USER} (days_remaining=${DAYS_REMAINING:-n/a})"
PROMPT_EXIT=0
show_friendly_nudge "${DAYS_REMAINING}" || PROMPT_EXIT=$?

case ${PROMPT_EXIT} in
    0)
        log_info "User clicked Log Out Now — showing countdown"
        COUNTDOWN_EXIT=0
        show_logout_countdown || COUNTDOWN_EXIT=$?
        case ${COUNTDOWN_EXIT} in
            0|4)
                force_logout
                ;;
            2)
                log_info "User cancelled logout countdown — will nudge again later"
                ;;
            *)
                log_warn "Logout countdown exited with ${COUNTDOWN_EXIT} — not forcing logout"
                ;;
        esac
        ;;
    2)
        log_info "User chose Remind Me Later"
        ;;
    4)
        log_info "Nudge dialog timer expired"
        ;;
    *)
        log_warn "Nudge dialog exited with ${PROMPT_EXIT}"
        ;;
esac

log_info "${SCRIPT_NAME} nudge tick complete"
NUDGE_EOF

    "${CHOWN}" root:wheel "${NUDGE_SCRIPT_PATH}"
    "${CHMOD}" 755 "${NUDGE_SCRIPT_PATH}"

    if ! inject_org_identity "${NUDGE_SCRIPT_PATH}"
    then
        return 1
    fi

    if ! validate_generated_script "${NUDGE_SCRIPT_PATH}"
    then
        return 1
    fi

    log_info "Wrote nudge script to ${NUDGE_SCRIPT_PATH}"
}

# ── Embedded Phase B script (quoted heredoc — content is literal) ────────────
write_phaseb_script() {
    "${CAT}" > "${PHASEB_SCRIPT_PATH}" <<'PHASEB_EOF'
#! /bin/bash

######################################################################
# Name: JC_Demobilize_PhaseB.sh
# Purpose: Finalize the demobilization workflow — fired by its
#          LaunchDaemon's RunAtLoad (once at install time) and
#          StartInterval (every PHASEB_RETRY_INTERVAL seconds
#          thereafter) until it self-uninstalls. Reads credentials
#          from config.plist (written by Phase A). AD unbind runs
#          regardless of network state (dsconfigad -remove -force);
#          only the Jamf API step waits on network.
# Version: 2.14 - Throwaway dsconfigad unbind password is redacted in the
#                 logs (username + hostname still logged for audit).
# Version: 2.13 - Public release prep: sanitized identifiers, expert-bash
#                 conformance. ORG identity tokens injected by Phase A at
#                 write time; dual-log functions (unified log + jamf.log
#                 via tee + shared workflow log); SLEEP / HOSTNAME_BIN
#                 binary variables; multi-line trap demote.
#                 Bug fixes:
#                 (1) dsconfigad exit code was read via `OUT=$(cmd)` then
#                     `RC=$?` under set -e — a failing unbind killed the
#                     script before mark_failed ran. Now captured with
#                     `|| UNBIND_RC=$?`.
#                 (2) jss_url and config.plist key reads aborted under
#                     set -e/pipefail when missing, skipping the intended
#                     mark_failed handling. Guarded with `|| true`.
#                 (3) get_jamf_access_token / get_jamf_computer_id now set
#                     ACCESS_TOKEN / COMPUTER_ID globals instead of
#                     returning data through stdout capture of functions
#                     that also log.
# Version: 2.12 - Two related additions driven by pilot feedback:
#                 (1) Ignored-user check. is_ignored_user() reads the
#                     :ignored_users array (and :st_admin_user, which
#                     is auto-ignored) from config.plist. If the
#                     console user is in the list, Phase B exits
#                     cleanly — its next StartInterval fire will pick
#                     up the actual mobile user once they log in.
#                     Prevents Phase B from trying to demobilize the
#                     SecureToken admin when a tech logs in as that
#                     account to clear a stuck lockout.
#                 (2) Auto-unlock. auto_unlock_locked_mobile_users()
#                     enumerates non-ignored mobile users on the Mac
#                     and clears any AD-style lockout via pwpolicy
#                     using the SecureToken admin credentials already
#                     in config.plist. Runs BEFORE the console-user
#                     wait — a locked user can never log in, so a
#                     console user would never appear and Phase B
#                     would loop indefinitely waiting. Each unlock is
#                     recorded in state.plist as unlock_count_<user>
#                     with a rolling-window counter (config keys
#                     :lockout_loop_threshold and
#                     :lockout_loop_window_hours, written by Phase A).
#                     When the count crosses the threshold within the
#                     window, Phase B records lockout_loop_user /
#                     lockout_loop_count / lockout_loop_detected_at
#                     into state.plist for IT review. Unlocking still
#                     happens every interval — without it, the
#                     demobilization can never complete.
#                 PWPOLICY binary added.
# Version: 2.11 - Added enforce_jamf_connect_login() — called as the
#                  final step of Phase B's success path, immediately
#                  before self_uninstall. Runs
#                  `authchanger -reset -JamfConnect` to guarantee the
#                  JC Login window is active when the user next logs
#                  out. Empirically, the auth chain reverts to the
#                  macOS default at some point during demobilization
#                  (likely during dsconfigad -remove or the SecureToken
#                  grant — both touch directory services and can trigger
#                  an authd reload). Phase A's reset_authchanger sets up
#                  the chain at install time, but by the time Phase B
#                  finishes the chain can be back to loginwindow:login.
#                  Companion fix: Phase A v4.16 fixed the destructive
#                  double-call bug in its own reset_authchanger that
#                  was leaving the chain in the wrong state at install
#                  time too. Together these two fixes guarantee the JC
#                  Login window is active both during demobilization
#                  AND after demobilization completes. Failure here is
#                  non-fatal (we log a warning and continue to
#                  self_uninstall) — Phase B has already done all the
#                  real demobilization work; if the reset fails for
#                  some reason a tech can run it manually.
#                  AUTHCHANGER constant added to Phase B's binary list.
# Version: 2.10 - LaunchAgent + sentinel-file trigger removed
#                 (see Phase A v4.15 note). PHASEB_AGENT_LABEL,
#                 PHASEB_AGENT_PATH, and PHASEB_TRIGGER_FILE constants
#                 removed; self_uninstall() no longer enumerates GUI
#                 sessions to bootout the agent or remove the trigger
#                 file. The mkdir-based mutex remains in place to
#                 serialize concurrent StartInterval fires.
# Version: 2.9 - Static-group removal switched from PATCH
#                /api/v1/static-computer-groups/<id> (which returns
#                404 on Jamf Pro 11.26.x — the modern endpoint does
#                not exist there) to PUT /JSSResource/computergroups/
#                id/<id> with a Classic-API XML body containing a
#                <computer_deletions> stanza. New helper
#                jamf_classic_api_put_xml replaces the now-removed
#                jamf_api_patch helper. All API helpers (OAuth, GET,
#                Classic PUT) now log the Jamf-supplied response body
#                on non-2xx so future permission/auth errors surface
#                inline. CAT added to the binary list (needed by the
#                new error-body logging).
# Version: 2.8 - dsconfigad now invoked with throwaway per-device
#                credentials (svc_demobilze_users_<LocalHostName> +
#                24-byte openssl random password). macOS requires
#                -u/-p with -force but doesn't authenticate them
#                against AD. Both creds logged for audit.
# Version: 2.7 - Capture dsconfigad's stderr on unbind failure and log
#                both the exit code and the actual error message.
#                Previously stderr was discarded, so unbind failures
#                logged only the exit code with no diagnostic info.
# Version: 2.6 - PHASEB_TRIGGER_FILE moved from /var/run/ to /tmp/
#                to match the Phase A change. (See Phase A v4.10 note.)
# Version: 2.5 - log_* functions now also echo to stdout/stderr so
#                their output appears in the LaunchDaemon's
#                StandardOutPath / StandardErrorPath log files
#                (jc-demobilize-phaseB.std{out,err}.log).
# Version: 2.4 - swiftDialog branding (APP_NAME, banner, icon) read
#                from config.plist instead of being hardcoded. Single
#                source of truth lives in Phase A's User Defined
#                Variables block.
# Version: 2.3 - Concurrent-run mutex via mkdir-based lock. Trap-based
#                demote of the SecureToken admin (cleanup runs the
#                demote no matter how Phase B exits, so SIGTERM can't
#                leak admin elevation).
# Version: 2.2 - swiftDialog branding (banner, icon, sizes, run_dialog
#                wrapper). SecureToken admin is elevated to admin
#                before grant_secure_token and demoted back to standard
#                after. AD binding creds dropped — `dsconfigad -remove
#                -force` is local-only.
# Version: 2.1 - Dropped AD DC reachability gate; unbind always runs.
# Version: 2.0 - Initial Phase B.
######################################################################

# readonly NAME=$(which ...) and local log_msg="$(date ...)" are the house
# template pattern; masking those return values is intentional.
# shellcheck disable=SC2155
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck disable=SC2230
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly CAT=$(which cat)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)
readonly SCUTIL=$(which scutil)
readonly DSCL=$(which dscl)
readonly DEFAULTS=$(which defaults)
readonly LAUNCHCTL=$(which launchctl)
readonly SUDO=$(which sudo)
readonly MKDIR=$(which mkdir)
readonly CHMOD=$(which chmod)
readonly GREP=$(which grep)
readonly SED=$(which sed)
readonly TAIL=$(which tail)
readonly CURL=$(which curl)
readonly JQ=$(which jq)
readonly IOREG=$(which ioreg)
readonly DSCONFIGAD=$(which dsconfigad)
readonly SYSADMINCTL=$(which sysadminctl)
readonly DSEDITGROUP=$(which dseditgroup)
readonly PWPOLICY=$(which pwpolicy)
readonly DIRNAME=$(which dirname)
readonly STAT=$(which stat)
readonly RMDIR=$(which rmdir)
readonly OPENSSL=$(which openssl)
readonly SLEEP=$(which sleep)
readonly HOSTNAME_BIN=$(which hostname)
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly JAMF="/usr/local/bin/jamf"
readonly AUTHCHANGER="/usr/local/bin/authchanger"

# Org identity — tokens replaced by Phase A (inject_org_identity) at write
# time from Phase A's ORG_NAME_FRIENDLY / ORG_PLIST_DOMAIN. Do not edit here.
readonly ORG_NAME_FRIENDLY="YOUR_ORG_NAME_FRIENDLY_INJECTED"
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="YOUR_ORG_PLIST_DOMAIN_INJECTED"
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="2.14"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.jc-demobilize-phaseB"
readonly JAMF_LOG="/var/log/jamf.log"

readonly STATE_DIR="/Library/Application Support/${ORG_NAME}/JCDemobilize"
readonly STATE_PLIST="${STATE_DIR}/state.plist"
readonly CONFIG_PLIST="${STATE_DIR}/config.plist"

# ── swiftDialog branding (read from config.plist; written by Phase A) ────────
# To rebrand, edit Phase A's User Defined Variables block, NOT here.
APP_NAME=$("${PLIST_BUDDY}" -c "Print :app_name" "${CONFIG_PLIST}" 2>/dev/null || echo "JC Demobilize")

# Banner — local path first, URL fallback
brandingBanner=$("${PLIST_BUDDY}" -c "Print :branding_banner_local" "${CONFIG_PLIST}" 2>/dev/null || echo "")
if [[ ! -f "${brandingBanner}" ]]
then
    brandingBanner=$("${PLIST_BUDDY}" -c "Print :branding_banner_url" "${CONFIG_PLIST}" 2>/dev/null || echo "")
fi

# App icon — local path first, URL fallback
appIcon=$("${PLIST_BUDDY}" -c "Print :app_icon_local" "${CONFIG_PLIST}" 2>/dev/null || echo "")
if [[ ! -f "${appIcon}" ]]
then
    appIcon=$("${PLIST_BUDDY}" -c "Print :app_icon_url" "${CONFIG_PLIST}" 2>/dev/null || echo "")
fi
# swiftDialog convention constants. Not every size is used by this script;
# they are kept so dialogs stay consistent across the workflow.
# shellcheck disable=SC2034
appIconSize=125

# Constants — not configurable per deployment
DIALOG_BIN="/usr/local/bin/dialog"
# shellcheck disable=SC2034
APP_DIR="/Library/Application Support/${ORG_NAME}/${APP_NAME}"
# shellcheck disable=SC2034
appSizeXSmall=250
appSizeSmall=500
appSizeMedium=650
# shellcheck disable=SC2034
appSizeLarge=800
# shellcheck disable=SC2034
appSizeXLarge=1000
appName="${ORG_NAME_FRIENDLY} - ${APP_NAME}"

# STATE_DIR / STATE_PLIST / CONFIG_PLIST declared above — see branding block.
readonly PHASEB_SCRIPT_PATH="${STATE_DIR}/JC_Demobilize_PhaseB.sh"
readonly PHASEB_DAEMON_LABEL="${ORG_PLIST_DOMAIN}.jc-demobilize-phaseB"
readonly PHASEB_DAEMON_PATH="/Library/LaunchDaemons/${PHASEB_DAEMON_LABEL}.plist"
readonly PHASEB_LOCK_DIR="${STATE_DIR}/.phaseb.lock"
# Stale-lock threshold (minutes). Phase B's longest non-pathological
# run is the Jamf reachability wait (~2 min); 60 min is comfortable.
readonly PHASEB_LOCK_STALE_MINUTES=60
readonly LOG_FILE="/Library/Logs/${ORG_NAME}/jc-demobilize.log"

# Console-user wait
readonly CONSOLE_USER_MAX_ATTEMPTS=30
readonly CONSOLE_USER_INTERVAL=2

# Jamf API reachability retry — tolerates slow VPN / wifi handshake at login.
# Only the Jamf API portion of Phase B needs network; AD unbind is offline-safe.
readonly JAMF_RETRY_INTERVAL=10
readonly JAMF_TOTAL_TIMEOUT=120

# SecureToken password prompt
readonly MAX_PASSWORD_ATTEMPTS=3

declare -a TEMP_FILES=()

ACCESS_TOKEN=""
TOKEN_EXPIRY=0
COMPUTER_ID=""

# Set to 1 once acquire_phaseb_lock succeeds, so cleanup knows whether
# to release the lock (vs. leave another running instance's lock alone).
LOCK_HELD=0

# Set to 1 once Phase B elevates the SecureToken admin to admin. The
# cleanup trap demotes on every exit path so an interrupted run never
# leaves the service account elevated.
ELEVATED_ADMIN=0

JAMF_URL=""
JAMF_CLIENT_ID=""
JAMF_CLIENT_SECRET=""
ST_ADMIN_USER=""
ST_ADMIN_PASS=""
STATIC_GROUP_ID=""

# ── Logging (unified log + jamf.log via tee + shared workflow log) ──────────
append_workflow_log() {
    printf '%s\n' "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

log_info() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

log_debug() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
    append_workflow_log "${log_msg}"
}

require_root() {
    if [[ "$("${ID}" -u)" -ne 0 ]]
    then
        log_error "Must run as root"
        exit 1
    fi
}

ensure_log_file() {
    local log_dir
    log_dir=$("${DIRNAME}" "${LOG_FILE}")
    if [[ ! -d "${log_dir}" ]]
    then
        "${MKDIR}" -p "${log_dir}"
        "${CHMOD}" 755 "${log_dir}"
    fi
}

create_temp_file() {
    local prefix="${1:-jc_phaseb}"
    local temp_file
    temp_file=$("${MKTEMP}" -t "${prefix}")
    TEMP_FILES+=("${temp_file}")
    printf '%s' "${temp_file}"
}

cleanup() {
    local exit_code=$?
    local f

    # Demote the SecureToken admin if we elevated it during this run,
    # regardless of whether the workflow succeeded. Runs first so even
    # if later cleanup steps fail we don't leak admin elevation.
    if [[ "${ELEVATED_ADMIN}" -eq 1 ]]
    then
        if is_user_admin "${ST_ADMIN_USER}"
        then
            if ! demote_to_standard "${ST_ADMIN_USER}"
            then
                log_warn "Trap-based demote of ${ST_ADMIN_USER} failed — verify manually"
            fi
        fi
        ELEVATED_ADMIN=0
    fi

    if [[ -n "${ACCESS_TOKEN:-}" ]]
    then
        invalidate_jamf_token "${ACCESS_TOKEN}" 2>/dev/null || true
    fi

    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -f "${f}" ]]
        then
            "${RM}" -f "${f}"
        fi
    done

    # Release the Phase B mutex last, so any final logging above still
    # has a coherent view of state.
    release_phaseb_lock

    log_info "${SCRIPT_NAME} exiting with code ${exit_code}"
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ── Phase B mutex (mkdir-based atomic lock) ──────────────────────────────────
# Phase B is fired both by RunAtLoad (once at install) and by
# StartInterval (every PHASEB_RETRY_INTERVAL seconds). If a previous run
# is still working through the AD unbind or Jamf API steps when the next
# interval fires, we don't want two Phase B processes racing on state,
# elevation, password prompts, and API calls. mkdir is atomic on
# APFS/HFS+, so the directory acts as the lock.
acquire_phaseb_lock() {
    local lock_age_seconds lock_age_minutes

    # Stale-lock detection: if the lock dir exists and is older than
    # PHASEB_LOCK_STALE_MINUTES, a previous run was probably killed
    # before it could clean up. Drop the stale dir and retry.
    if [[ -d "${PHASEB_LOCK_DIR}" ]]
    then
        lock_age_seconds=$(( $("${DATE}" +%s) - $("${STAT}" -f '%m' "${PHASEB_LOCK_DIR}" 2>/dev/null || echo 0) ))
        lock_age_minutes=$(( lock_age_seconds / 60 ))
        if [[ ${lock_age_minutes} -ge ${PHASEB_LOCK_STALE_MINUTES} ]]
        then
            log_warn "Stale Phase B lock detected (age ${lock_age_minutes}min) — clearing"
            "${RMDIR}" "${PHASEB_LOCK_DIR}" 2>/dev/null || true
        fi
    fi

    if "${MKDIR}" "${PHASEB_LOCK_DIR}" 2>/dev/null
    then
        LOCK_HELD=1
        log_debug "Phase B lock acquired"
        return 0
    fi

    return 1
}

release_phaseb_lock() {
    if [[ "${LOCK_HELD}" -eq 1 ]] && [[ -d "${PHASEB_LOCK_DIR}" ]]
    then
        "${RMDIR}" "${PHASEB_LOCK_DIR}" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

# ── Config / state ───────────────────────────────────────────────────────────
read_config_value() {
    local key="$1"
    "${PLIST_BUDDY}" -c "Print :${key}" "${CONFIG_PLIST}" 2>/dev/null
}

read_state_value() {
    local key="$1"
    if [[ ! -f "${STATE_PLIST}" ]]
    then
        return 1
    fi
    "${PLIST_BUDDY}" -c "Print :${key}" "${STATE_PLIST}" 2>/dev/null
}

set_state_value() {
    local key="$1"
    local value="$2"

    if [[ ! -f "${STATE_PLIST}" ]]
    then
        return 1
    fi

    if "${PLIST_BUDDY}" -c "Print :${key}" "${STATE_PLIST}" >/dev/null 2>&1
    then
        "${PLIST_BUDDY}" -c "Set :${key} ${value}" "${STATE_PLIST}"
    else
        "${PLIST_BUDDY}" -c "Add :${key} string ${value}" "${STATE_PLIST}"
    fi
}

mark_failed() {
    local failed_step="$1"
    local next_steps="$2"
    set_state_value "status" "Failed"
    set_state_value "step" "${failed_step}"
    set_state_value "next_steps" "${next_steps}"
    set_state_value "failed_at" "$("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')"
    log_error "Marked Failed at step '${failed_step}' — ${next_steps}"
}

mark_in_progress() {
    local step="$1"
    set_state_value "status" "In Progress"
    set_state_value "step" "${step}"
}

mark_complete() {
    set_state_value "status" "Complete"
    set_state_value "step" "Done"
    set_state_value "completed_at" "$("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')"
    set_state_value "phase" "B_complete"
}

# ── Console user / mobile checks ─────────────────────────────────────────────
get_current_user() {
    local console_user
    # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
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

wait_for_console_user() {
    local attempt=0
    local user
    while [[ ${attempt} -lt ${CONSOLE_USER_MAX_ATTEMPTS} ]]
    do
        if user=$(get_current_user)
        then
            printf '%s' "${user}"
            return 0
        fi
        attempt=$((attempt + 1))
        "${SLEEP}" "${CONSOLE_USER_INTERVAL}"
    done
    return 1
}

is_mobile_account() {
    local user="$1"
    local original_node
    if ! original_node=$("${DSCL}" . -read "/Users/${user}" OriginalNodeName 2>/dev/null)
    then
        return 1
    fi
    if [[ -z "${original_node}" ]]
    then
        return 1
    fi
    return 0
}

# ── Ignored users ────────────────────────────────────────────────────────────
# Returns 0 if ${user} is in config.plist's :ignored_users array OR is
# the SecureToken admin (ST_ADMIN_USER, loaded earlier from
# :st_admin_user). Auto-ignoring the admin matters because techs use it
# to unlock locked-out mobile users — Phase B should never try to
# demobilize the account a tech logged in as just to do that.
is_ignored_user() {
    local user="$1"
    local idx=0
    local entry

    if [[ -n "${ST_ADMIN_USER:-}" && "${user}" == "${ST_ADMIN_USER}" ]]
    then
        return 0
    fi

    while entry=$("${PLIST_BUDDY}" -c "Print :ignored_users:${idx}" "${CONFIG_PLIST}" 2>/dev/null)
    do
        if [[ -n "${entry}" && "${user}" == "${entry}" ]]
        then
            return 0
        fi
        idx=$((idx + 1))
    done

    return 1
}

# Enumerate non-ignored mobile users on this Mac. Used by the
# auto-unlock routine to find candidates regardless of who (if anyone)
# is at the console. dscl . -list /Users OriginalNodeName returns the
# subset of accounts that have a mobile-account directory backing —
# i.e. cached AD users.
get_mobile_users_for_unlock() {
    local listing
    local user

    if ! listing=$("${DSCL}" . -list /Users OriginalNodeName 2>/dev/null)
    then
        return 1
    fi

    while IFS= read -r line
    do
        # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
        user=$("${AWK}" '{ print $1 }' <<< "${line}")
        if [[ -z "${user}" ]]
        then
            continue
        fi
        case "${user}" in
            _*|daemon|nobody|root)
                continue
                ;;
        esac
        if is_ignored_user "${user}"
        then
            continue
        fi
        printf '%s\n' "${user}"
    done <<< "${listing}"
}

# ── Account lockout detection / clearing ─────────────────────────────────────
# Returns 0 if ${user} is currently locked out (authentication disabled
# at the account-policy level). pwpolicy's -authentication-allowed
# output is human-prose, so we string-match on "NOT allowed". Empirically
# stable across macOS 13 / 14 / 15.
is_account_locked() {
    local user="$1"
    local output

    if [[ ! -x "${PWPOLICY}" ]]
    then
        return 1
    fi

    output=$("${PWPOLICY}" -u "${user}" -authentication-allowed 2>&1 || true)

    if [[ "${output}" == *"NOT allowed"* ]]
    then
        return 0
    fi
    return 1
}

# Clear the account-policy lockout for ${user}. Tries three approaches
# in order of preference:
#   1. pwpolicy with the SecureToken admin's auth (-a/-p)
#   2. pwpolicy as root (no admin auth)
#   3. Direct dscl delete of accountPolicyData
# All three are non-destructive — they clear only the lockout state, not
# the user's password or SecureToken status. The admin-auth form is
# preferred because some macOS releases require it for mobile-account
# policy mutations even when running as root.
unlock_user_account() {
    local user="$1"

    log_info "Unlocking ${user} via SecureToken admin ${ST_ADMIN_USER}"

    if [[ -x "${PWPOLICY}" ]] \
        && "${PWPOLICY}" \
            -a "${ST_ADMIN_USER}" \
            -p "${ST_ADMIN_PASS}" \
            -u "${user}" \
            -clearaccountpolicies >/dev/null 2>&1
    then
        log_info "Cleared account policies for ${user} via pwpolicy (admin-auth)"
        return 0
    fi

    if [[ -x "${PWPOLICY}" ]] \
        && "${PWPOLICY}" \
            -u "${user}" \
            -clearaccountpolicies >/dev/null 2>&1
    then
        log_info "Cleared account policies for ${user} via pwpolicy (root)"
        return 0
    fi

    if "${DSCL}" . -delete "/Users/${user}" accountPolicyData >/dev/null 2>&1
    then
        log_info "Cleared accountPolicyData for ${user} via dscl"
        return 0
    fi

    log_error "Failed to clear lockout for ${user} — all unlock paths returned non-zero"
    return 1
}

# Record an unlock event in state.plist using per-user rolling-window
# counters. Keys written:
#   * unlock_count_<user>   — string-encoded integer, count in window
#   * first_unlock_<user>   — ISO timestamp, start of current window
#   * last_unlock_<user>    — ISO timestamp, most recent unlock
# When the count crosses the threshold within the window, additional
# alert keys are written so an IT tech can see the loop without
# combing the logs.
record_unlock_event() {
    local user="$1"
    local now_iso now_epoch
    local count_key first_key last_key
    local current_count first_unlock first_epoch elapsed_hours
    local threshold window_hours

    now_iso=$("${DATE}" -u '+%Y-%m-%dT%H:%M:%SZ')
    now_epoch=$("${DATE}" +%s)

    count_key="unlock_count_${user}"
    first_key="first_unlock_${user}"
    last_key="last_unlock_${user}"

    threshold=$(read_config_value "lockout_loop_threshold" 2>/dev/null || echo 3)
    window_hours=$(read_config_value "lockout_loop_window_hours" 2>/dev/null || echo 24)
    if [[ ! "${threshold}" =~ ^[0-9]+$ ]]
    then
        threshold=3
    fi
    if [[ ! "${window_hours}" =~ ^[0-9]+$ ]]
    then
        window_hours=24
    fi

    current_count=$(read_state_value "${count_key}" 2>/dev/null || echo 0)
    if [[ ! "${current_count}" =~ ^[0-9]+$ ]]
    then
        current_count=0
    fi

    first_unlock=$(read_state_value "${first_key}" 2>/dev/null || echo "")
    if [[ -n "${first_unlock}" ]]
    then
        first_epoch=$("${DATE}" -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${first_unlock}" "+%s" 2>/dev/null || echo 0)
        if [[ "${first_epoch}" -gt 0 ]]
        then
            elapsed_hours=$(( ( now_epoch - first_epoch ) / 3600 ))
            if [[ ${elapsed_hours} -ge ${window_hours} ]]
            then
                current_count=0
                first_unlock=""
            fi
        fi
    fi

    if [[ -z "${first_unlock}" ]]
    then
        set_state_value "${first_key}" "${now_iso}"
    fi

    current_count=$(( current_count + 1 ))
    set_state_value "${count_key}" "${current_count}"
    set_state_value "${last_key}" "${now_iso}"

    if [[ ${current_count} -ge ${threshold} ]]
    then
        log_warn "Lockout loop: ${user} unlocked ${current_count} times in the last ${window_hours}h (threshold ${threshold}) — flagging for IT review"
        set_state_value "lockout_loop_user" "${user}"
        set_state_value "lockout_loop_count" "${current_count}"
        set_state_value "lockout_loop_window_hours" "${window_hours}"
        set_state_value "lockout_loop_detected_at" "${now_iso}"
    fi
}

# Walk every non-ignored mobile user on the Mac and unlock any whose
# account is currently locked. Idempotent — users that aren't locked
# are skipped silently. Runs before wait_for_console_user so an
# auto-unlock fires at the StartInterval tick even when there's no
# console user (locked users can't log in, so without this Phase B
# would loop forever waiting on a console user that never appears).
auto_unlock_locked_mobile_users() {
    local user
    local users_listing

    if [[ -z "${ST_ADMIN_USER:-}" || -z "${ST_ADMIN_PASS:-}" ]]
    then
        log_debug "SecureToken admin credentials not loaded — skipping auto-unlock"
        return 0
    fi

    if ! users_listing=$(get_mobile_users_for_unlock)
    then
        log_debug "No mobile users found — skipping auto-unlock"
        return 0
    fi

    if [[ -z "${users_listing}" ]]
    then
        log_debug "No non-ignored mobile users — skipping auto-unlock"
        return 0
    fi

    while IFS= read -r user
    do
        if [[ -z "${user}" ]]
        then
            continue
        fi
        if ! is_account_locked "${user}"
        then
            log_debug "Mobile user ${user} is not locked"
            continue
        fi

        log_warn "Mobile user ${user} is locked — attempting auto-unlock"
        if unlock_user_account "${user}"
        then
            record_unlock_event "${user}"
        else
            log_error "Auto-unlock of ${user} failed — IT tech must clear manually"
        fi
    done <<< "${users_listing}"
}

# ── AD / Jamf reachability ───────────────────────────────────────────────────
# AD unbind uses dsconfigad -remove -force, which is local-only and does not
# require network or an AD DC. The only network-dependent step in Phase B is
# the Jamf API portion (OAuth + static group removal).
is_ad_bound() {
    local domain
    # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
    domain=$("${DSCONFIGAD}" -show 2>/dev/null \
        | "${AWK}" -F'= ' '/Active Directory Domain/ { print $2 }' \
        | "${SED}" -e 's/[[:space:]]*$//')
    if [[ -z "${domain}" ]]
    then
        return 1
    fi
    return 0
}

is_jamf_reachable() {
    if "${CURL}" --silent --head --max-time 10 "${JAMF_URL}" >/dev/null 2>&1
    then
        return 0
    fi
    return 1
}

# Wait for Jamf URL to become reachable. Tolerates slow wifi handshake or a
# VPN tunnel still coming up at login. Returns 0 on success, 1 on timeout.
# The caller should NOT mark_failed on timeout — Phase B will fire again at
# next login.
wait_for_jamf() {
    local elapsed=0

    if is_jamf_reachable
    then
        return 0
    fi

    log_info "Jamf URL ${JAMF_URL} not yet reachable — waiting up to ${JAMF_TOTAL_TIMEOUT}s"
    mark_in_progress "Waiting for network / Jamf API reachability"

    while [[ ${elapsed} -lt ${JAMF_TOTAL_TIMEOUT} ]]
    do
        "${SLEEP}" "${JAMF_RETRY_INTERVAL}"
        elapsed=$((elapsed + JAMF_RETRY_INTERVAL))
        if is_jamf_reachable
        then
            log_info "Jamf URL reachable after ${elapsed}s"
            return 0
        fi
        log_debug "Jamf URL still not reachable (waited ${elapsed}s)"
    done

    log_warn "Jamf URL did not become reachable within ${JAMF_TOTAL_TIMEOUT}s — will retry at next login"
    return 1
}

# ── SecureToken ──────────────────────────────────────────────────────────────
has_secure_token() {
    local user="$1"
    local enabled
    enabled=$("${SYSADMINCTL}" -secureTokenStatus "${user}" 2>&1 \
        | "${GREP}" -i -c "ENABLED" || true)
    if [[ "${enabled}" -ge 1 ]]
    then
        return 0
    fi
    return 1
}

verify_password() {
    local user="$1"
    local password="$2"
    if "${DSCL}" . -authonly "${user}" "${password}" >/dev/null 2>&1
    then
        return 0
    fi
    return 1
}

prompt_user_password() {
    local user="$1"
    local message="$2"
    local output_file
    local password

    output_file=$(create_temp_file "phaseb_pw_prompt")

    if ! run_dialog \
        --height "${appSizeMedium}" \
        --icon "${appIcon}" \
        --overlayicon "SF=lock.shield.fill,colour=blue" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "${message}" \
        --textfield "Password,secure,required,prompt=Account password for ${user}" \
        --button1text "Continue" \
        --button2text "Cancel" \
        --position centre \
        --ontop \
        --moveable \
        --json \
        > "${output_file}"
    then
        return 2
    fi

    password=$("${JQ}" -r '."Password" // ""' "${output_file}")

    if [[ -z "${password}" ]]
    then
        return 1
    fi

    printf '%s' "${password}"
}

grant_secure_token() {
    local target_user="$1"
    local target_password="$2"

    if "${SYSADMINCTL}" \
        -secureTokenOn "${target_user}" \
        -password "${target_password}" \
        -adminUser "${ST_ADMIN_USER}" \
        -adminPassword "${ST_ADMIN_PASS}" >/dev/null 2>&1
    then
        "${SLEEP}" 2
        if has_secure_token "${target_user}"
        then
            return 0
        fi
    fi
    return 1
}

# ── Local admin elevation / demotion ─────────────────────────────────────────
# The SecureToken admin account is kept as a standard user during normal
# operation. For the brief window in which sysadminctl needs to grant
# SecureToken, we elevate the account to admin, then demote back to
# standard immediately after — whether the grant succeeded or failed.
is_user_admin() {
    local user="$1"
    if "${DSEDITGROUP}" -o checkmember -m "${user}" admin >/dev/null 2>&1
    then
        return 0
    fi
    return 1
}

elevate_to_admin() {
    local user="$1"
    if "${DSEDITGROUP}" -o edit -a "${user}" -t user admin >/dev/null 2>&1
    then
        log_info "Elevated ${user} to admin (temporary)"
        return 0
    fi
    log_error "Failed to elevate ${user} to admin"
    return 1
}

demote_to_standard() {
    local user="$1"
    if "${DSEDITGROUP}" -o edit -d "${user}" -t user admin >/dev/null 2>&1
    then
        log_info "Demoted ${user} back to standard user"
        return 0
    fi
    log_warn "Failed to demote ${user} from admin — please verify manually"
    return 1
}

ensure_secure_token() {
    local user="$1"
    local attempt=0
    local password
    local prompt_msg
    local result=1

    if has_secure_token "${user}"
    then
        log_info "${user} already holds a SecureToken"
        return 0
    fi

    if [[ -z "${ST_ADMIN_USER}" || -z "${ST_ADMIN_PASS}" ]]
    then
        log_error "SecureToken admin credentials missing in config.plist"
        return 1
    fi

    if ! has_secure_token "${ST_ADMIN_USER}"
    then
        log_error "SecureToken admin ${ST_ADMIN_USER} does not hold a SecureToken — cannot grant"
        return 1
    fi

    # Elevate the SecureToken admin to admin if it's currently standard.
    # Set ELEVATED_ADMIN=1 so the cleanup trap demotes back on every
    # exit path (including SIGTERM, errors, and unexpected exits).
    if is_user_admin "${ST_ADMIN_USER}"
    then
        log_debug "${ST_ADMIN_USER} is already an admin — skipping elevation"
    else
        if ! elevate_to_admin "${ST_ADMIN_USER}"
        then
            return 1
        fi
        ELEVATED_ADMIN=1
    fi

    prompt_msg="Your account needs a SecureToken to enable FileVault access. Please enter your current password to continue."

    while [[ ${attempt} -lt ${MAX_PASSWORD_ATTEMPTS} ]]
    do
        attempt=$((attempt + 1))
        log_info "SecureToken password prompt attempt ${attempt}/${MAX_PASSWORD_ATTEMPTS}"

        if ! password=$(prompt_user_password "${user}" "${prompt_msg}")
        then
            prompt_msg="Password entry was cancelled or empty. Please try again."
            continue
        fi

        if ! verify_password "${user}" "${password}"
        then
            prompt_msg="The password was incorrect. Please try again. (Attempt ${attempt}/${MAX_PASSWORD_ATTEMPTS})"
            password=""
            continue
        fi

        if grant_secure_token "${user}" "${password}"
        then
            log_info "SecureToken granted to ${user}"
            password=""
            result=0
            break
        fi

        prompt_msg="We couldn't grant SecureToken with that password. Please try again. (Attempt ${attempt}/${MAX_PASSWORD_ATTEMPTS})"
        password=""
    done

    # No demote here — the cleanup trap handles it on every exit path,
    # including SIGTERM, set -e errors, and successful completion.
    return ${result}
}

# ── swiftDialog ──────────────────────────────────────────────────────────────
run_dialog() {
    local current_user
    local current_uid
    if ! current_user=$(get_current_user)
    then
        return 1
    fi
    current_uid=$(get_current_user_uid "${current_user}")
    "${LAUNCHCTL}" asuser "${current_uid}" "${SUDO}" -u "${current_user}" \
        "${DIALOG_BIN}" "$@" 2>/dev/null
}

# Show a single-button informational dialog. The third argument is the
# overlay icon spec (e.g., "SF=checkmark.circle.fill,colour=green").
show_user_message() {
    local heading="$1"
    local message="$2"
    local overlay_spec="$3"

    if [[ ! -x "${DIALOG_BIN}" ]]
    then
        return
    fi

    if ! run_dialog \
        --height "${appSizeSmall}" \
        --icon "${appIcon}" \
        --overlayicon "${overlay_spec}" \
        --bannerimage "${brandingBanner}" \
        --bannertext "${appName}" \
        --message "**${heading}**\n\n${message}" \
        --button1text "OK" \
        --position centre \
        --ontop \
        --moveable \
        --infotext "${LOG_LABEL} v${SCRIPT_VERSION}"
    then
        log_debug "Dialog dismissed"
    fi
}

# ── Jamf API ─────────────────────────────────────────────────────────────────
# Sets the ACCESS_TOKEN global on success (no stdout capture — this function
# logs, and log output must never mix with returned data).
get_jamf_access_token() {
    local response http_code body access_token expires_in
    response=$("${CURL}" \
        --silent --show-error --location \
        --request POST \
        --url "${JAMF_URL}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${JAMF_CLIENT_ID}" \
        --data-urlencode "client_secret=${JAMF_CLIENT_SECRET}" \
        --write-out "\n%{http_code}" 2>/dev/null)

    http_code=$("${TAIL}" -n1 <<< "${response}")
    body=$("${SED}" '$ d' <<< "${response}")

    if [[ "${http_code}" -ne 200 ]]
    then
        log_error "OAuth token request to ${JAMF_URL}/api/oauth/token failed (HTTP ${http_code})"
        log_error "Response body: ${body}"
        log_error "Client ID used (first 8 chars): ${JAMF_CLIENT_ID:0:8}..."
        return 1
    fi

    access_token=$("${JQ}" -r '.access_token' <<< "${body}")
    expires_in=$("${JQ}" -r '.expires_in' <<< "${body}")

    if [[ -z "${access_token}" || "${access_token}" == "null" ]]
    then
        log_error "access_token missing from OAuth response"
        log_error "Response body: ${body}"
        return 1
    fi

    # shellcheck disable=SC2034 # recorded for troubleshooting; tokens are short-lived per run
    TOKEN_EXPIRY=$(( $("${DATE}" +%s) + expires_in - 300 ))
    ACCESS_TOKEN="${access_token}"
}

invalidate_jamf_token() {
    local token="$1"
    "${CURL}" --silent --request POST \
        --url "${JAMF_URL}/api/v1/auth/invalidate-token" \
        --header "Authorization: Bearer ${token}" >/dev/null 2>&1 || true
}

jamf_api_get() {
    local endpoint="$1"
    local token="$2"
    local output_file="$3"
    local http_code
    http_code=$("${CURL}" \
        --silent --show-error --location \
        --request GET \
        --url "${JAMF_URL}${endpoint}" \
        --header "Authorization: Bearer ${token}" \
        --header "Accept: application/json" \
        --output "${output_file}" \
        --write-out "%{http_code}" 2>/dev/null)
    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]
    then
        log_error "API GET ${endpoint} failed (HTTP ${http_code})"
        if [[ -s "${output_file}" ]]
        then
            log_error "Response body: $("${CAT}" "${output_file}")"
        fi
        return 1
    fi
}

# Classic API PUT with XML body. Used for static computer group membership
# changes — the modern /api/v1/static-computer-groups endpoint does NOT
# exist on Jamf Pro 11.26.x, so we have to talk to /JSSResource which
# expects XML. Returns non-zero on any non-2xx response and logs the
# Jamf-supplied error body when available.
jamf_classic_api_put_xml() {
    local endpoint="$1"
    local token="$2"
    local data_file="$3"
    local output_file="$4"
    local http_code
    http_code=$("${CURL}" \
        --silent --show-error --location \
        --request PUT \
        --url "${JAMF_URL}${endpoint}" \
        --header "Authorization: Bearer ${token}" \
        --header "Content-Type: application/xml" \
        --header "Accept: application/xml" \
        --data @"${data_file}" \
        --output "${output_file}" \
        --write-out "%{http_code}" 2>/dev/null)
    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]
    then
        log_error "Classic API PUT ${endpoint} failed (HTTP ${http_code})"
        if [[ -s "${output_file}" ]]
        then
            log_error "Response body: $("${CAT}" "${output_file}")"
        fi
        return 1
    fi
}

get_serial_number() {
    # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
    "${IOREG}" -c IOPlatformExpertDevice -d 2 \
        | "${AWK}" '/IOPlatformSerialNumber/ { gsub(/"/, "", $NF); print $NF }'
}

# Sets the COMPUTER_ID global on success (no stdout capture — this
# function and jamf_api_get log on failure).
get_jamf_computer_id() {
    local token="$1"
    local serial response_file computer_id
    serial=$(get_serial_number)
    response_file=$(create_temp_file "jamf_computer_lookup")

    if ! jamf_api_get \
        "/api/v2/computers-inventory?filter=hardware.serialNumber==%22${serial}%22&section=GENERAL" \
        "${token}" "${response_file}"
    then
        return 1
    fi

    computer_id=$("${JQ}" -r '.results[0].id // empty' "${response_file}")
    if [[ -z "${computer_id}" ]]
    then
        log_error "No Jamf computer record found for serial ${serial}"
        return 1
    fi
    COMPUTER_ID="${computer_id}"
}

remove_from_static_group() {
    local token="$1"
    local group_id="$2"
    local computer_id="$3"
    local payload_file response_file

    payload_file=$(create_temp_file "jamf_group_put")
    response_file=$(create_temp_file "jamf_group_response")

    # Classic API expects an XML body listing the computer IDs to delete
    # from the static group. The modern /api/v1/static-computer-groups
    # endpoint does not exist on Jamf Pro 11.26.x, so we cannot use the
    # PATCH-with-removedComputerIds pattern here.
    {
        printf '%s\n' '<computer_group>'
        printf '%s\n' '    <computer_deletions>'
        printf '        <computer><id>%s</id></computer>\n' "${computer_id}"
        printf '%s\n' '    </computer_deletions>'
        printf '%s\n' '</computer_group>'
    } > "${payload_file}"

    if ! jamf_classic_api_put_xml \
        "/JSSResource/computergroups/id/${group_id}" \
        "${token}" "${payload_file}" "${response_file}"
    then
        return 1
    fi
}

# ── Re-enforce Jamf Connect login window ─────────────────────────────────────
# Empirically, the auth chain reverts to the macOS default at some point
# during the demobilize finalization (likely during dsconfigad -remove or
# the SecureToken grant — both of these touch directory services and can
# trigger an authd auth chain reload). Phase A's reset_authchanger sets up
# the chain at install time, but by the time Phase B finishes the chain
# can be back to loginwindow:login. This routine re-runs
# `authchanger -reset -JamfConnect` as the final step of Phase B's success
# path so the JC Login window is guaranteed active when the user logs out
# next. Non-fatal on failure — Phase B has already done all the
# demobilization work; we just log a warning so the audit trail captures
# it. We never want this step to block self-uninstall.
enforce_jamf_connect_login() {
    local authchanger_output

    if [[ ! -x "${AUTHCHANGER}" ]]
    then
        log_warn "authchanger not at ${AUTHCHANGER} — skipping JC Login re-enforce"
        return 0
    fi

    log_info "Re-enforcing Jamf Connect login window: ${AUTHCHANGER} -reset -JamfConnect"
    if ! authchanger_output=$("${AUTHCHANGER}" -reset -JamfConnect 2>&1)
    then
        log_warn "authchanger -reset -JamfConnect failed (non-fatal): ${authchanger_output}"
        return 0
    fi

    log_info "JC Login window re-enforced; user will see the JC Login screen at next logout"
    return 0
}

# ── Self-uninstall ───────────────────────────────────────────────────────────
self_uninstall() {
    log_info "Phase B succeeded — removing artifacts"

    if [[ -f "${PHASEB_SCRIPT_PATH}" ]]
    then
        "${RM}" -f "${PHASEB_SCRIPT_PATH}"
    fi

    # Wipe credentials from disk now that we're done.
    if [[ -f "${CONFIG_PLIST}" ]]
    then
        "${RM}" -f "${CONFIG_PLIST}"
        log_info "Removed ${CONFIG_PLIST}"
    fi

    # Bootout the LaunchDaemon LAST — this kills the running script.
    if [[ -f "${PHASEB_DAEMON_PATH}" ]]
    then
        "${RM}" -f "${PHASEB_DAEMON_PATH}"
    fi

    if "${LAUNCHCTL}" print "system/${PHASEB_DAEMON_LABEL}" >/dev/null 2>&1
    then
        "${LAUNCHCTL}" bootout "system/${PHASEB_DAEMON_LABEL}" 2>/dev/null || true
    fi
}

##############################################################################
# Main
##############################################################################

require_root
ensure_log_file

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting"

# 0. Mutex. WatchPaths can fire multiple times for one sentinel touch
#    (FSEvents emits create + modify + close). If another Phase B is
#    already running, exit silently — the running instance will finish
#    the work.
if ! acquire_phaseb_lock
then
    log_debug "Another Phase B instance is already running — exiting"
    exit 0
fi

# 1. Bail if there's no Phase A / nudge state receipt.
if [[ ! -f "${STATE_PLIST}" ]]
then
    log_debug "No state receipt — Phase B has nothing to do"
    exit 0
fi

PHASE_VALUE=$(read_state_value "phase" || true)
STATUS_VALUE=$(read_state_value "status" || true)

if [[ "${PHASE_VALUE}" == "B_complete" || "${STATUS_VALUE}" == "Complete" ]]
then
    log_info "Workflow already Complete — self-uninstalling artifacts"
    self_uninstall
    exit 0
fi

if [[ "${PHASE_VALUE}" != "A_complete" ]]
then
    log_debug "Receipt phase is '${PHASE_VALUE}' — not ready for Phase B"
    exit 0
fi

# 2. Load credentials from config.plist.
if [[ ! -f "${CONFIG_PLIST}" ]]
then
    log_error "Missing ${CONFIG_PLIST}"
    mark_failed "config-load" "Credential config missing. Re-run the Phase A policy to redeploy."
    exit 1
fi

# `|| true` keeps set -e / pipefail from aborting on a missing value, so the
# explicit empty-value checks below can mark_failed with a useful message.
JAMF_URL=$("${DEFAULTS}" read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null \
    | "${SED}" -e 's/\/$//' || true)
JAMF_CLIENT_ID=$(read_config_value "jamf_client_id" || true)
JAMF_CLIENT_SECRET=$(read_config_value "jamf_client_secret" || true)
ST_ADMIN_USER=$(read_config_value "st_admin_user" || true)
ST_ADMIN_PASS=$(read_config_value "st_admin_pass" || true)
STATIC_GROUP_ID=$(read_config_value "static_group_id" || true)

if [[ -z "${JAMF_URL}" ]]
then
    log_error "Unable to read Jamf URL from com.jamfsoftware.jamf.plist"
    mark_failed "preflight" "Mac is not Jamf-enrolled or jss_url missing."
    exit 1
fi

for required_var in JAMF_CLIENT_ID JAMF_CLIENT_SECRET ST_ADMIN_USER ST_ADMIN_PASS STATIC_GROUP_ID
do
    if [[ -z "${!required_var}" ]]
    then
        log_error "Missing ${required_var} in config.plist"
        mark_failed "config-load" "Required key '${required_var}' missing in config.plist. Re-run Phase A with all parameters set."
        exit 1
    fi
done

if [[ ! -x "${JQ}" ]]
then
    log_error "jq missing on device"
    mark_failed "preflight" "jq missing. Install jq and retry."
    exit 1
fi

# 2.5. Auto-unlock any locked mobile users on this Mac. Runs BEFORE the
#      console-user wait because a locked user cannot log in — without
#      this step, Phase B would wait_for_console_user, time out, exit,
#      and the StartInterval would fire the same dead-end loop again
#      indefinitely until a tech manually unlocked the user. Unlock
#      events are tracked per-user in state.plist; persistent
#      lockouts surface a lockout_loop alert for IT review (see
#      record_unlock_event).
auto_unlock_locked_mobile_users

# 3. Wait for the console user to settle in after login.
if ! CURRENT_USER=$(wait_for_console_user)
then
    log_warn "No console user appeared — exiting; will retry next login"
    exit 0
fi
log_info "Console user: ${CURRENT_USER}"

# 3.5. If the console user is in the ignore list (e.g. a tech logged in
#      as the SecureToken admin to manually intervene), bail out without
#      attempting to demobilize them. Phase B's StartInterval will fire
#      again later and pick up the real mobile user once they log in.
if is_ignored_user "${CURRENT_USER}"
then
    log_info "Console user ${CURRENT_USER} is in the ignore list — exiting; will retry at next interval"
    exit 0
fi

# 4. Verify the user is no longer mobile (Jamf Connect Login should have
#    demobilized them at this login). If still mobile: mark_failed but
#    DO NOT self-uninstall — next login will retry.
if is_mobile_account "${CURRENT_USER}"
then
    log_error "Console user ${CURRENT_USER} is STILL a mobile account — JC Login did not demobilize"
    mark_failed "demobilize-verification" "Jamf Connect Login did not demobilize ${CURRENT_USER} during this login. Verify both JC Login profiles are installed and DemobilizeUsers=true, then log out and back in."
    show_user_message \
        "Account Conversion Did Not Complete" \
        "Your account was not converted on this login. Please contact IT — this device remains in the conversion queue." \
        "SF=exclamationmark.triangle.fill,colour=red"
    exit 1
fi
log_info "Confirmed ${CURRENT_USER} is a local account"

# 5. Ensure the console user has a SecureToken (grant via local admin if needed).
#    This step is user-interactive but needs no network.
if ! ensure_secure_token "${CURRENT_USER}"
then
    mark_failed "securetoken-grant" "SecureToken could not be granted to ${CURRENT_USER} after ${MAX_PASSWORD_ATTEMPTS} attempts. Verify ${ST_ADMIN_USER} holds a SecureToken and the user knows their current password."
    show_user_message \
        "SecureToken Not Granted" \
        "We couldn't enable SecureToken on your account. Please contact IT to complete the conversion." \
        "SF=lock.slash.fill,colour=red"
    exit 1
fi

# 6. AD unbind — always runs. `dsconfigad -remove -force` is local-only
#    and does not contact any DC. The -u/-p flags are required by the
#    command's API but the credentials are NOT actually authenticated
#    against AD when -force is used. We fabricate per-device throwaway
#    credentials so each Mac uses a unique username/password pair. The
#    username and hostname are logged for audit; the password is NOT
#    logged (it is never validated, so it has no audit value, and a
#    plaintext `-p` value in jamf.log / the Jamf policy log trips secret
#    scanners and SIEM rules).
#
# NOTE: The username spelling "svc_demobilze_users_..." (no `i` in
# "demobilze") matches the original specification — preserved verbatim
# even though it looks like a typo. The value is throwaway and never
# authenticates against anything, so the spelling doesn't affect
# functionality.
if is_ad_bound
then
    UNBIND_HOSTNAME=$("${SCUTIL}" --get LocalHostName 2>/dev/null || true)
    if [[ -z "${UNBIND_HOSTNAME}" ]]
    then
        UNBIND_HOSTNAME=$("${HOSTNAME_BIN}" -s 2>/dev/null || echo "unknown")
    fi
    UNBIND_USER="svc_demobilze_users_${UNBIND_HOSTNAME}"
    UNBIND_PASS=$("${OPENSSL}" rand -base64 24 2>/dev/null || echo "fallback-$("${DATE}" +%s)")

    log_info "Unbinding from AD with throwaway per-device credentials:"
    log_info "  hostname (LocalHostName) = ${UNBIND_HOSTNAME}"
    log_info "  -u ${UNBIND_USER}"
    log_info "  -p <redacted: random throwaway, not validated by dsconfigad>"
    log_info "  Note: dsconfigad -force does NOT validate these credentials — required by the API only."

    # Capture the exit code with `||` — a bare `OUT=$(cmd)` followed by
    # `RC=$?` would let set -e kill the script on failure before the
    # mark_failed path below could run.
    UNBIND_RC=0
    UNBIND_OUTPUT=$("${DSCONFIGAD}" -remove -force -u "${UNBIND_USER}" -p "${UNBIND_PASS}" 2>&1) || UNBIND_RC=$?

    log_info "dsconfigad -remove -force exited with code ${UNBIND_RC}"
    if [[ -n "${UNBIND_OUTPUT}" ]]
    then
        log_info "dsconfigad output: ${UNBIND_OUTPUT}"
    else
        log_info "dsconfigad output: (empty — typically a clean unbind)"
    fi

    if [[ ${UNBIND_RC} -ne 0 ]]
    then
        log_error "AD unbind failed"
        mark_failed "ad-unbind" "dsconfigad -remove -force exited ${UNBIND_RC}: ${UNBIND_OUTPUT}. Check the workflow log for the full command and output."
        show_user_message \
            "Conversion Paused" \
            "We couldn't remove this Mac from the domain. IT has been notified." \
            "SF=exclamationmark.triangle.fill,colour=orange"
        exit 1
    fi
    "${SLEEP}" 3
    if is_ad_bound
    then
        log_error "Mac still reports AD bind after unbind command"
        mark_failed "ad-unbind-verify" "Mac still reports AD bind after unbind command. Try dsconfigad -remove -force manually as admin."
        exit 1
    fi
    log_info "AD unbind confirmed"
else
    log_info "Mac was not bound to AD — skipping unbind step"
fi

# 7. Jamf API reachability gate. This is the ONE step that needs network.
#    If unreachable, mark in progress and retry at next login (no failure).
if ! wait_for_jamf
then
    log_info "Exiting cleanly — Phase B will fire again at next login when Jamf is reachable"
    exit 0
fi

# 8. Remove from the demobilization static group via Jamf API.
if ! get_jamf_access_token
then
    mark_failed "jamf-auth" "OAuth token request to ${JAMF_URL} failed. Verify the API client credentials in config.plist and that the Jamf URL is correct."
    exit 1
fi

if ! get_jamf_computer_id "${ACCESS_TOKEN}"
then
    mark_failed "jamf-lookup" "Could not find this computer's Jamf record by serial. Trigger a jamf recon and re-run Phase B."
    exit 1
fi
log_info "Jamf computer ID: ${COMPUTER_ID}"

if ! remove_from_static_group "${ACCESS_TOKEN}" "${STATIC_GROUP_ID}" "${COMPUTER_ID}"
then
    mark_failed "static-group-removal" "Removal from static group ${STATIC_GROUP_ID} failed. Verify the API role has 'Update Static Computer Groups' and that the group ID is correct."
    exit 1
fi
log_info "Removed computer ${COMPUTER_ID} from static group ${STATIC_GROUP_ID}"

# 9. Mark complete + recon.
mark_complete

if [[ -x "${JAMF}" ]]
then
    if ! "${JAMF}" recon >/dev/null 2>&1
    then
        log_warn "jamf recon returned non-zero — inventory may be stale until next check-in"
    fi
fi

show_user_message \
    "Account Conversion Complete" \
    "Your account has been converted to a local account on this Mac. No further action is required." \
    "SF=checkmark.circle.fill,colour=green"

# 10. Re-enforce the JC Login window. Empirically, the auth chain reverts
#     to the macOS default at some point during demobilization (likely
#     during dsconfigad -remove or the SecureToken grant). Re-applying
#     `authchanger -reset -JamfConnect` here guarantees the JC Login
#     window is the one the user sees at their next logout. Non-fatal.
enforce_jamf_connect_login

# 11. Self-uninstall (removes script, daemon, AND config.plist creds).
self_uninstall
log_info "${SCRIPT_NAME} completed successfully"
PHASEB_EOF

    "${CHOWN}" root:wheel "${PHASEB_SCRIPT_PATH}"
    "${CHMOD}" 755 "${PHASEB_SCRIPT_PATH}"

    if ! inject_org_identity "${PHASEB_SCRIPT_PATH}"
    then
        return 1
    fi

    if ! validate_generated_script "${PHASEB_SCRIPT_PATH}"
    then
        return 1
    fi

    log_info "Wrote Phase B script to ${PHASEB_SCRIPT_PATH}"
}

# ── Nudge LaunchDaemon ───────────────────────────────────────────────────────
write_nudge_launchd() {
    local interval="$1"

    "${CAT}" > "${NUDGE_LAUNCHD_PATH}" <<NUDGE_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${NUDGE_LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${NUDGE_SCRIPT_PATH}</string>
    </array>
    <key>StartInterval</key>
    <integer>${interval}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${NUDGE_STDOUT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${NUDGE_STDERR_LOG}</string>
</dict>
</plist>
NUDGE_PLIST

    "${CHOWN}" root:wheel "${NUDGE_LAUNCHD_PATH}"
    "${CHMOD}" 644 "${NUDGE_LAUNCHD_PATH}"

    if ! validate_generated_plist "${NUDGE_LAUNCHD_PATH}"
    then
        return 1
    fi
}

reload_nudge_launchd() {
    if "${LAUNCHCTL}" print "system/${NUDGE_LAUNCHD_LABEL}" >/dev/null 2>&1
    then
        if ! "${LAUNCHCTL}" bootout "system/${NUDGE_LAUNCHD_LABEL}" 2>/dev/null
        then
            log_warn "launchctl bootout for ${NUDGE_LAUNCHD_LABEL} returned non-zero"
        fi
    fi

    if ! "${LAUNCHCTL}" bootstrap system "${NUDGE_LAUNCHD_PATH}"
    then
        log_error "launchctl bootstrap failed for ${NUDGE_LAUNCHD_PATH}"
        return 1
    fi

    "${LAUNCHCTL}" enable "system/${NUDGE_LAUNCHD_LABEL}" 2>/dev/null || true
    log_info "Nudge LaunchDaemon loaded"
}

# ── Legacy Phase B LaunchAgent cleanup (v4.0–v4.14 leftovers) ───────────────
# Macs that ran a previous build of Phase A still have the trigger
# LaunchAgent registered with launchd and the agent plist on disk. As long
# as that agent is loaded, /usr/bin/touch fires at every user login and
# macOS BTM surfaces a "touch can run in the background" notification —
# even though v4.15+ no longer writes the agent. This routine boots out
# any active load, removes the plist, and clears the legacy sentinel
# files at both /tmp and /var/run (the original v4.0–v4.9 path was
# /var/run, moved to /tmp in v4.10). Idempotent: if nothing is found,
# it logs a single debug line and returns cleanly.
cleanup_legacy_phaseb_agent() {
    local legacy_agent_label="${ORG_PLIST_DOMAIN}.jc-demobilize-phaseB-trigger"
    local legacy_agent_path="/Library/LaunchAgents/${legacy_agent_label}.plist"
    local legacy_trigger_tmp="/tmp/jc-demobilize-phaseB.trigger"
    local legacy_trigger_var_run="/var/run/jc-demobilize-phaseB.trigger"
    local user
    local user_uid
    local found_anything=0

    # Bootout the legacy agent from every active GUI session. Iterate
    # local users with UID>=500 instead of just the current console user
    # — fast-user-switching can leave background sessions loaded for
    # other users we still need to clean.
    # shellcheck disable=SC2016 # single quotes are intentional: awk program, not shell
    while IFS= read -r user
    do
        if [[ -z "${user}" ]]
        then
            continue
        fi
        case "${user}" in
            _*|daemon|nobody|root)
                continue
                ;;
        esac
        user_uid=$("${ID}" -u "${user}" 2>/dev/null || true)
        if [[ -z "${user_uid}" ]]
        then
            continue
        fi
        if "${LAUNCHCTL}" print "gui/${user_uid}/${legacy_agent_label}" >/dev/null 2>&1
        then
            log_info "Booting out legacy Phase B trigger LaunchAgent from gui/${user_uid} (${user})"
            "${LAUNCHCTL}" bootout "gui/${user_uid}/${legacy_agent_label}" 2>/dev/null || true
            found_anything=1
        fi
    done < <("${DSCL}" . -list /Users UniqueID 2>/dev/null | "${AWK}" '$2 >= 500 { print $1 }')

    if [[ -f "${legacy_agent_path}" ]]
    then
        log_info "Removing legacy Phase B trigger LaunchAgent plist at ${legacy_agent_path}"
        "${RM}" -f "${legacy_agent_path}"
        found_anything=1
    fi

    if [[ -f "${legacy_trigger_tmp}" ]]
    then
        log_info "Removing legacy Phase B trigger sentinel at ${legacy_trigger_tmp}"
        "${RM}" -f "${legacy_trigger_tmp}"
        found_anything=1
    fi

    if [[ -f "${legacy_trigger_var_run}" ]]
    then
        log_info "Removing legacy Phase B trigger sentinel at ${legacy_trigger_var_run}"
        "${RM}" -f "${legacy_trigger_var_run}"
        found_anything=1
    fi

    if [[ ${found_anything} -eq 0 ]]
    then
        log_debug "No legacy Phase B LaunchAgent / trigger files found — nothing to clean"
    else
        log_info "Legacy Phase B trigger machinery cleaned — BTM 'touch can run in the background' notification will not recur"
    fi
}

# ── Phase B LaunchDaemon ─────────────────────────────────────────────────────
# Phase B is fired by RunAtLoad (when this daemon is bootstrapped at the
# end of Phase A) and StartInterval (every PHASEB_RETRY_INTERVAL seconds
# thereafter). There is no LaunchAgent + sentinel-file trigger anymore —
# v4.15 removed it because /usr/bin/touch in the agent triggered a
# "touch can run in the background" BTM notification on every install.
# The interval covers the same wake-up case within at most
# PHASEB_RETRY_INTERVAL seconds (default 600).
write_phaseb_launchdaemon() {
    "${CAT}" > "${PHASEB_DAEMON_PATH}" <<DAEMON_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PHASEB_DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${PHASEB_SCRIPT_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>${PHASEB_RETRY_INTERVAL}</integer>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${PHASEB_STDOUT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${PHASEB_STDERR_LOG}</string>
</dict>
</plist>
DAEMON_PLIST

    "${CHOWN}" root:wheel "${PHASEB_DAEMON_PATH}"
    "${CHMOD}" 644 "${PHASEB_DAEMON_PATH}"

    if ! validate_generated_plist "${PHASEB_DAEMON_PATH}"
    then
        return 1
    fi

    log_info "Wrote Phase B LaunchDaemon to ${PHASEB_DAEMON_PATH}"
}

bootstrap_phaseb_daemon() {
    if "${LAUNCHCTL}" print "system/${PHASEB_DAEMON_LABEL}" >/dev/null 2>&1
    then
        if ! "${LAUNCHCTL}" bootout "system/${PHASEB_DAEMON_LABEL}" 2>/dev/null
        then
            log_warn "launchctl bootout for ${PHASEB_DAEMON_LABEL} returned non-zero"
        fi
    fi

    if ! "${LAUNCHCTL}" bootstrap system "${PHASEB_DAEMON_PATH}"
    then
        log_error "launchctl bootstrap failed for ${PHASEB_DAEMON_PATH}"
        return 1
    fi

    "${LAUNCHCTL}" enable "system/${PHASEB_DAEMON_LABEL}" 2>/dev/null || true
    log_info "Phase B LaunchDaemon loaded (RunAtLoad + StartInterval=${PHASEB_RETRY_INTERVAL}s)"
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

require_root
ensure_log_file

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting (installer)"

require_param "Jamf Pro API client ID (\$5)" "${PARAM_CLIENT_ID}"
require_param "Jamf Pro API client secret (\$6)" "${PARAM_CLIENT_SECRET}"
require_param "SecureToken admin username (\$7)" "${PARAM_ST_ADMIN_USER}"
require_param "SecureToken admin password (\$8)" "${PARAM_ST_ADMIN_PASS}"
require_param "static computer group ID (\$9)" "${PARAM_STATIC_GROUP_ID}"

if ! validate_interval "${PARAM_NUDGE_INTERVAL}"
then
    exit 1
fi

# Runtime dependencies of the nudge / Phase B — warn-only at install time
# (documented fallback in the Requirements section).
require_dialog_warn
require_jq_warn

# Confirm Jamf Connect Login is installed. The JC Login pkg is normally
# installed earlier in the same policy as this script; if it isn't, fall
# back to triggering a dedicated install policy via the custom event in
# parameter $10 (PARAM_JCLOGIN_TRIGGER).
if ! is_jamf_connect_login_installed
then
    if ! install_jamf_connect_login
    then
        exit 1
    fi
fi

# Reset authchanger so the JC Login window is enforced with the
# Demobilize preAuth mech. Required for the demobilize flow to work.
if ! reset_authchanger
then
    log_error "authchanger reset failed — JC Login may not be enforced at next login"
    exit 1
fi

ensure_state_dir

if ! write_config_plist
then
    exit 1
fi

# Clean up the legacy LaunchAgent + sentinel files from any previous
# v4.0–v4.14 install. v4.15 stopped writing the agent but didn't actively
# remove pre-existing ones, so Macs upgraded from a prior build kept
# surfacing the BTM "touch can run in the background" notification at
# every login. Idempotent — safe to run on a fresh Mac too.
cleanup_legacy_phaseb_agent

# Phase B is always deployed regardless of mobile-user state — it's needed
# either to finalize a fresh demobilization or to clean up a Mac that was
# demobilized externally. The daemon's RunAtLoad fires Phase B once
# immediately and StartInterval keeps it firing every PHASEB_RETRY_INTERVAL
# seconds until it self-uninstalls.
if ! write_phaseb_script
then
    exit 1
fi

if ! write_phaseb_launchdaemon
then
    exit 1
fi

if ! bootstrap_phaseb_daemon
then
    exit 1
fi

# Branch on mobile account presence.
if ! has_any_mobile_accounts
then
    log_info "No mobile accounts found on this Mac — skipping nudge install"
    log_info "Mac was demobilized outside this workflow; Phase B will finish via its StartInterval (${PHASEB_RETRY_INTERVAL}s)"
    write_external_demobilize_state
    log_info "${SCRIPT_NAME} installer complete (external demobilization path)"
    exit 0
fi

# Mobile users present — install nudge. Phase B's RunAtLoad fire will abort
# at the still-mobile check and retry on its StartInterval; once JC Login
# demobilizes the user at next login, Phase B's next interval fire (within
# ${PHASEB_RETRY_INTERVAL}s) will complete the workflow.
if ! write_nudge_script
then
    exit 1
fi

if ! write_nudge_launchd "${PARAM_NUDGE_INTERVAL}"
then
    exit 1
fi

if ! reload_nudge_launchd
then
    exit 1
fi

log_info "${SCRIPT_NAME} installer complete — nudge will run every ${PARAM_NUDGE_INTERVAL}s; Phase B retries every ${PHASEB_RETRY_INTERVAL}s"

###########################################################
################## End Script Block #######################
###########################################################

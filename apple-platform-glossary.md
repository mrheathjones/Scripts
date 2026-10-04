# Apple Platform Glossary

Apple platform enterprise IT terminology — covering macOS, iOS, iPadOS,
tvOS, watchOS, and visionOS, plus the tools and products used to manage
them (Jamf Pro, Microsoft Intune, Apple Business Manager, and more). Written for
engineers new to the Apple platform side of IT.

> **ℹ️ Note:** Current coverage is macOS- and Jamf Pro-focused. Entries
> for other Apple OSes (iOS/iPadOS/tvOS/watchOS/visionOS) and management
> tools (Intune, Kandji, Mosyle, Addigy, etc.) are added as they come up
> in practice. Contributions welcome.

This glossary is the companion document for every deployment guide
in this repository; every MDM-specific term in a deployment guide
links here.

**How to use this page:** search for a term (`Cmd+F` in your browser)
or follow the alphabetical index. Entries link to related terms.

---

## Quick index

**A–C:** [ADE](#automated-device-enrollment-ade) · [APNs](#apns) · [API Client](#api-client) · [API Role](#api-role) · [Apple Business Manager (ABM)](#apple-business-manager-abm) · [Apple Silicon](#apple-silicon) · [BeyondTrust EPM](#beyondtrust-endpoint-privilege-management-epm) · [Bootstrap Token](#bootstrap-token) · [Category](#category) · [Configuration Profile](#configuration-profile) · [Console user](#console-user) · [Custom Event](#custom-event) · [Active Directory](#active-directory) · [Background Task Management (BTM)](#background-task-management-btm) · [Cisco Secure Client](#cisco-secure-client)

**D–J:** [Declarative Device Management (DDM)](#declarative-device-management-ddm) · [`defaults`](#defaults) · [`dscl`](#dscl) · [Entra ID](#entra-id) · [`expert-bash`](#expert-bash) · [Extension Attribute (EA)](#extension-attribute-ea) · [FileVault](#filevault) · [Frequency](#frequency) · [Gatekeeper](#gatekeeper) · [Inventory Update (recon)](#inventory-update-recon) · [Jamf binary](#jamf-binary) · [Jamf Composer](#jamf-composer) · [Jamf Connect](#jamf-connect) · [Jamf Pro](#jamf-pro) · [Jamf Pro API](#jamf-pro-api) · [Jamf Protect](#jamf-protect) · [heredoc](#heredoc)

**K–P:** [keychain](#keychain) · [LaunchAgent](#launchagent) · [`launchctl`](#launchctl) · [`launchctl asuser`](#launchctl-asuser) · [`launchd`](#launchd) · [LaunchDaemon](#launchdaemon) · [Managed Apple Account](#managed-apple-account) · [MDM](#mdm) · [`.mobileconfig`](#mobileconfig) · [Notarization](#notarization) · [PAC file](#pac-file) · [Platform SSO (PSSO)](#platform-sso-psso) · [plist](#plist) · [Policy](#policy) · [PPPC](#pppc) · [preference domain](#preference-domain) · [PreStage Enrollment](#prestage-enrollment) · [Package](#package)

**R–Z:** [Recurring Check-in](#recurring-check-in) · [Rosetta 2](#rosetta-2) · [root context](#root-context) · [Scope](#scope) · [Script payload](#script-payload) · [Secure Token](#secure-token) · [`security` binary](#security-binary) · [Self Service](#self-service) · [Setup Assistant](#setup-assistant) · [SIP](#sip) · [Smart Group](#smart-group) · [Static Group](#static-group) · [Supervised](#supervised) · [swiftDialog](#swiftdialog) · [System Extension](#system-extension-and-kernel-extension) · [T2](#t2) · [TCC](#tcc) · [Trigger](#trigger) · [UAMDM](#uamdm) · [unified log](#unified-log) · [user context](#user-context) · [Volume Ownership](#volume-ownership) · [VPP / Apps and Books](#vpp--apps-and-books) · [WatchPath](#watchpath) · [XProtect](#xprotect) · [Zscaler](#zscaler) · [Site](#site)

---

### Active Directory

Microsoft's on-premises directory service. Macs can be "bound" to an
Active Directory domain (`dsconfigad`) so domain accounts can sign in,
often as **mobile accounts** that cache the domain password locally.
Many organizations are retiring AD binding on Macs in favor of cloud
identity ([Entra ID](#entra-id)) with [Jamf Connect](#jamf-connect) or
[Platform SSO](#platform-sso-psso).

**Unbind locally:** `dsconfigad -remove -force -u <any> -p <any>` removes
the binding without contacting a domain controller (the credentials are
required by the command but not validated when `-force` is used).

**Related:** [Entra ID](#entra-id), [Jamf Connect](#jamf-connect), [`dscl`](#dscl).

---

### API Client

An OAuth 2.0 client in [Jamf Pro](#jamf-pro) that scripts use to authenticate
against the [Jamf Pro API](#jamf-pro-api). An API Client has a client ID
(UUID) and a one-time-viewable client secret, and one or more [API Roles](#api-role)
attached that define what it can do. Scripts fetch short-lived bearer tokens
with client-credentials grant, then use those tokens to call API endpoints.

**Where to create:** `Settings → System → API roles and clients → API Clients tab`.

**Critical detail:** the client secret is shown *once* at creation. Capture it
immediately and store it in the System [keychain](#keychain) or deliver via
[Configuration Profile](#configuration-profile) — it can't be retrieved later.

**Related:** [API Role](#api-role), [Jamf Pro API](#jamf-pro-api), [keychain](#keychain).

---

### API Role

A named bundle of Jamf Pro API privileges. API Roles are attached to
[API Clients](#api-client) to define what actions the client can perform
(read computers, update records, trigger inventory updates, etc.). Jamf
recommends least-privilege: one Role per use case, only the specific
privileges that use case needs.

**Where to create:** `Settings → System → API roles and clients → API Roles tab`.

**Related:** [API Client](#api-client), [Jamf Pro API](#jamf-pro-api).

---

### APNs

Apple Push Notification service — Apple's cloud service that [MDM](#mdm)
servers use to wake a device and tell it to check in. MDM does not hold an
open connection to each device; instead the server sends a push through
APNs, and the device then connects back to the MDM server to retrieve
queued commands ([Configuration Profiles](#configuration-profile), lock,
wipe, [DDM](#declarative-device-management-ddm) declarations, etc.).

Operationally: if APNs is unreachable (a firewall blocking Apple's push
endpoints, or an expired APNs/MDM push certificate), devices stop
responding to MDM commands even though everything else looks healthy —
commands sit "Pending" until the next successful check-in.

**Network requirement:** Apple push traffic uses TCP 443 (and historically
5223) to Apple's `*.push.apple.com` range. It must not be proxied or
TLS-inspected.

**Related:** [MDM](#mdm), [Jamf Pro](#jamf-pro), [Declarative Device Management (DDM)](#declarative-device-management-ddm).

---

### Apple Business Manager (ABM)

Apple's web portal (`business.apple.com`) for enterprise device purchase,
enrollment, content, and account management — the tenant an organization
links to its [MDM](#mdm) server (such as [Jamf Pro](#jamf-pro)) so that
Macs, iPhones, and iPads bought through Apple or an authorized reseller
auto-assign to that MDM and receive a [PreStage Enrollment](#prestage-enrollment)
configuration on first boot via [Automated Device Enrollment](#automated-device-enrollment-ade).

ABM is also where admins manage [Managed Apple Accounts](#managed-apple-account),
buy and distribute software in volume ([VPP / Apps and Books](#vpp--apps-and-books)),
and download the MDM push certificate that links the tenant to the MDM
server.

**Education equivalent:** Apple School Manager (ASM) is the parallel
portal for education institutions (`school.apple.com`) — the same core
device-assignment and enrollment model, plus education-specific features
(student Managed Apple Accounts, Classroom/Schoolwork, class rosters).
This glossary standardizes on ABM; substitute ASM if your organization is
an education tenant.

**Related:** [Automated Device Enrollment (ADE)](#automated-device-enrollment-ade), [PreStage Enrollment](#prestage-enrollment), [Managed Apple Account](#managed-apple-account), [VPP / Apps and Books](#vpp--apps-and-books), [MDM](#mdm).

---

### Apple Silicon

Apple's custom ARM64 chips (M1, M2, M3, M4, etc.) that replaced Intel in Macs
starting in 2020. Apple Silicon Macs differ from Intel Macs in several
operationally-relevant ways: they use the [Bootstrap Token](#bootstrap-token)
for remote admin-privileged operations, require [Volume Ownership](#volume-ownership)
for certain MDM commands, have different kernel-extension and system-extension
handling, and ship with Rosetta as a separate install for running Intel binaries.

When writing scripts, check architecture with `uname -m` (`arm64` vs `x86_64`)
or `sysctl -n machdep.cpu.brand_string`.

**Related:** [Bootstrap Token](#bootstrap-token), [Volume Ownership](#volume-ownership), [T2](#t2).

---

### Automated Device Enrollment (ADE)

The modern name for what Apple used to call DEP (Device Enrollment Program).
ADE is the mechanism by which devices purchased through
[Apple Business Manager](#apple-business-manager-abm) (or Apple School
Manager for education) automatically enroll into the organization's MDM
server on first boot, without requiring any user or IT intervention. The
user sees a setup screen that says "<Organization> will automatically
configure your Mac."

ADE-enrolled devices are automatically [Supervised](#supervised), allowing
the MDM server to perform privileged operations the user cannot remove.

**Related:** [Apple Business Manager (ABM)](#apple-business-manager-abm), [PreStage Enrollment](#prestage-enrollment), [Supervised](#supervised), [MDM](#mdm).

---

### Background Task Management (BTM)

The macOS 13+ subsystem that tracks login items, LaunchAgents, and
LaunchDaemons and shows users a "Background Items Added" notification
when new ones appear. Users can disable items in **System Settings >
General > Login Items & Extensions**. Admins prevent both the
notification and user disabling with a **Managed Login Items**
[Configuration Profile](#configuration-profile) payload
(`com.apple.servicemanagement`) that matches items by label, team ID, or
bundle ID.

**Inspect:** `sfltool dumpbtm` (run as root).

**Related:** [LaunchAgent](#launchagent), [LaunchDaemon](#launchdaemon), [Configuration Profile](#configuration-profile).

---

### BeyondTrust Endpoint Privilege Management (EPM)

A third-party product (formerly Avecto Defendpoint) that lets organizations
grant users elevated privileges for specific actions without giving them
full admin rights. On Macs, EPM intercepts authorization requests and
applies policy — for example, allowing a specific installer to run as
admin while blocking others.

Admins define rules that match on app bundle path, code signature,
process arguments, or user group. Where deployed, EPM runs alongside
Jamf Pro and influences what scripts can do when a user triggers
elevation.

**Related:** [SIP](#sip), [root context](#root-context).

---

### Bootstrap Token

A cryptographic token that lets MDM perform certain privileged operations
on an [Apple Silicon](#apple-silicon) Mac without needing a specific user's
password. Required for remote software updates, kernel extension approval,
and several other MDM-issued commands.

The token is generated at first boot, escrowed to MDM when the user first
grants it (typically at login on an ADE-enrolled Mac), and used behind the
scenes from then on. If the token isn't escrowed, many MDM commands fail
with permission errors.

**Check status:** `sudo profiles status -type bootstraptoken`.
**Re-escrow:** `sudo profiles install -type bootstraptoken` (may require user password).

**Related:** [Apple Silicon](#apple-silicon), [Secure Token](#secure-token), [Volume Ownership](#volume-ownership).

---

### Category

A labeling mechanism in [Jamf Pro](#jamf-pro) for organizing Policies,
Scripts, Configuration Profiles, and Self Service tiles. Categories exist
purely for administrative organization — they don't affect execution.

Categories are created once and reused across object types. Common
categories: `Provisioning`, `Security`, `Maintenance`, `Compliance`,
`User Tools`.

**Where to create:** `Settings → Global → Categories`.

---

### Cisco Secure Client

Cisco's endpoint client (formerly AnyConnect) that provides VPN and
other security modules. On macOS its VPN agent runs as the `vpnagentd`
[LaunchDaemon](#launchdaemon). Scripts that need to tell whether a Mac
is on the corporate network often check the VPN connection state first.

**Related:** [LaunchDaemon](#launchdaemon).

---

### Configuration Profile

An XML document (`.mobileconfig`) deployed by [MDM](#mdm) to configure Mac
or iOS settings. Profiles can enforce password policies, deploy Wi-Fi
credentials, install certificates, set preferences that would otherwise
require `defaults write`, and much more. Profiles are the primary
mechanism by which MDM changes endpoint configuration.

In [Jamf Pro](#jamf-pro), profiles are created at
`Computers → Configuration Profiles` and can be scoped to Smart Groups,
Static Groups, or all managed devices. A single profile contains one or
more "payloads" (e.g., a Wi-Fi payload, a Restrictions payload, an
Application & Custom Settings payload for arbitrary preference domains).

**Scripts often read profile-delivered preferences:**
```bash
defaults read "com.example.myapp" SomeKey
```

The profile is installed at computer level (readable by root) or user
level (readable by a specific user). Matters when your script runs as
root but needs to read a user-level preference.

**Related:** [`.mobileconfig`](#mobileconfig), [preference domain](#preference-domain), [MDM](#mdm).

---

### Console user

The user currently logged in and interacting with the Mac's screen — as
opposed to background service accounts, SSH sessions, or root processes.
Many scripts need to identify the console user to deliver
[user-context](#user-context) actions.

**Standard detection:**
```bash
CONSOLE_USER=$(stat -f "%Su" /dev/console)
CONSOLE_UID=$(id -u "${CONSOLE_USER}")
```

If the result is `root` or `loginwindow`, no user is logged in and the
script should skip user-facing work.

**Related:** [user context](#user-context), [`launchctl asuser`](#launchctl-asuser), [root context](#root-context).

---

### Custom Event

A trigger type in a [Jamf Pro](#jamf-pro) [Policy](#policy) that runs only
when invoked explicitly by name, not on a time-based or lifecycle schedule.
An admin (or another script) triggers the policy with:

```bash
sudo jamf policy -event <event-name>
```

Custom Events are how you chain policies together (e.g., a provisioning
workflow that calls `install-jq`, then `install-swiftdialog`, then
`install-security-agent` via distinct events).

Event names should use kebab-case or snake_case — no spaces or special
characters. Documented in the policy's General → Trigger section.

**Related:** [Trigger](#trigger), [Policy](#policy), [Jamf binary](#jamf-binary).

---

### Declarative Device Management (DDM)

The modern evolution of [MDM](#mdm) on Apple platforms (macOS 13+, iOS 15+).
Instead of the server sending each command and polling for the result, DDM
pushes *declarations* — self-contained statements of desired state — that
the device applies autonomously and reports status changes back on its own,
without waiting for the server to ask. This makes management faster, more
scalable, and functional even when the device is briefly offline.

DDM has four declaration types: **configurations** (settings to apply),
**assets** (data referenced by configurations), **activations** (which
configurations are active, gated by predicates), and **status** (what the
device proactively reports). Apple is steadily moving capabilities from
legacy [Configuration Profiles](#configuration-profile) to DDM — software
update enforcement in particular is now DDM-based.

In [Jamf Pro](#jamf-pro), DDM surfaces through features such as declarative
software update management; admins usually configure the intent rather than
authoring raw declarations.

**Related:** [MDM](#mdm), [Configuration Profile](#configuration-profile), [APNs](#apns).

---

### `defaults`

The macOS command-line tool for reading and writing preference files
(`.plist` files). Scripts use `defaults` extensively to read
[preference domains](#preference-domain) delivered by
[Configuration Profiles](#configuration-profile) and to set local
preferences.

```bash
# Read a string
defaults read com.example.myapp SomeKey

# Read with a default fallback
defaults read com.example.myapp SomeKey 2>/dev/null || echo "fallback"

# Read the type (useful for debugging)
defaults read-type com.example.myapp SomeKey

# Write a value (as the owning user context)
defaults write com.example.myapp SomeKey -string "value"
```

Quirks to know: `defaults` is case-sensitive on domain and key names;
reading a missing key exits non-zero (hence the `|| echo` fallback
pattern); and managed (MDM-delivered) preferences live in a different
store than user preferences — `defaults read` correctly reads the
managed layer on top of user-writable values.

**Related:** [preference domain](#preference-domain), [plist](#plist), [Configuration Profile](#configuration-profile).

---

### `dscl`

The "Directory Service command-line utility" — macOS's tool for reading
and modifying the local directory database (users, groups, groups-of-
groups) as well as external directories. Scripts use `dscl` to inspect
or change local user account attributes.

**Common invocations:**
```bash
# List all local users
dscl . list /Users

# Get a specific user's UID
dscl . read /Users/username UniqueID

# Change a local user's password (three-argument form — the two-arg form is deprecated)
dscl . -passwd /Users/username oldpassword newpassword
```

The `.` means "the local node" (the local directory, `/Local/Default`).
Use `/Search` to search across all configured directory nodes.

**Related:** [console user](#console-user).

---

### Entra ID

Microsoft's cloud identity service (renamed from Azure AD in late 2023).
Provides user accounts, single sign-on, MFA, conditional access, and
identity federation. Many Mac deployments use Entra ID as the source of
truth for user identity, with integrations like Jamf Connect or
Platform SSO delivering Entra credentials into the login window.

Older documentation, APIs, and tooling may still reference "Azure AD"
— treat the terms as synonymous.

**Related:** [Jamf Connect](#jamf-connect).

---

### `expert-bash`

The companion skill that produces Bash scripts following enterprise-macOS
conventions. Scripts produced by `expert-bash` use a standard template
(banner blocks, `${WHICH_BINARY}` paths, logging functions, trap-based
cleanup, `require_root` preflight), making them the input for the Script
Deployment Docs workflow.

---

### Extension Attribute (EA)

A Jamf Pro mechanism for collecting custom inventory data from managed
Macs. An EA is a small script (usually Bash) that runs on every
[Inventory Update](#inventory-update-recon) and returns a single value
(string, integer, or date). That value populates a named field on the
computer record, usable in [Smart Group](#smart-group) criteria,
reports, and API queries.

EAs must output exactly `<result>VALUE</result>` as their final stdout. Other
output (logs, debug) is ignored. Keep EAs fast (<30 seconds) and
side-effect-free — they run frequently and shouldn't block inventory.

**Where to create:** `Settings → Computer Management → Extension Attributes`.

**Example output:**
```bash
echo "<result>Installed</result>"
```

**Related:** [Inventory Update](#inventory-update-recon), [Smart Group](#smart-group).

---

### FileVault

Apple's full-disk encryption for macOS. When enabled, all data on the
boot volume is encrypted at rest and unlocked at login with the user's
password. Most enterprise Macs run FileVault by policy, enforced via an
MDM Configuration Profile.

Operational notes for scripting:
- FileVault-encrypted Macs are "locked" at boot until a user logs in. Scripts triggered at `Startup` may run before the disk is unlocked, limiting what they can read or write.
- Escrowing the recovery key to MDM ensures IT can unlock a Mac if the user forgets their password.
- `fdesetup status` reports current state; `fdesetup haspersonalrecoverykey` checks escrow.

**Related:** [Apple Silicon](#apple-silicon), [Secure Token](#secure-token).

---

### Frequency

A setting on a [Jamf Pro](#jamf-pro) [Policy](#policy) that controls
how often the policy can execute on the same Mac. Not to be confused
with [Trigger](#trigger), which controls what starts the policy.

Options:
- `Once per computer` — runs exactly once per Mac, ever. Best for one-shot installs.
- `Ongoing` — runs every time the trigger fires. Used when [Smart Group](#smart-group) membership is the gate instead.
- `Once every day / week / month` — runs once in the specified window.
- `Once per user` — runs once per local user account on the Mac.
- `Once per user per computer` — per-user on each specific Mac.

**Related:** [Policy](#policy), [Trigger](#trigger), [Smart Group](#smart-group).

---

### Gatekeeper

The macOS security feature that verifies downloaded apps are signed by a
registered Apple Developer and, for software distributed outside the App
Store, [notarized](#notarization) by Apple before allowing them to run.
When a user opens a quarantined app that fails these checks, Gatekeeper
blocks it with a warning.

Relevant to deployment because apps and installers pushed by [MDM](#mdm) /
[Jamf Pro](#jamf-pro) generally bypass the interactive Gatekeeper prompt
(managed installs are trusted), while anything a user downloads manually is
subject to it. Enterprise-built tools should be signed with a Developer ID
and notarized to avoid friction.

**Check / manage:** `spctl --status` shows Gatekeeper state;
`xattr -d com.apple.quarantine <path>` removes the quarantine flag from a
file (use judiciously).

**Related:** [Notarization](#notarization), [XProtect](#xprotect), [TCC](#tcc).

---

### heredoc

A shell construct (`cat > file <<EOF ... EOF`) that writes a block of
inline text to a file or command. Self-installing scripts use heredocs to
write their own [LaunchDaemon](#launchdaemon) or
[LaunchAgent](#launchagent) plists and helper scripts, so the whole tool
ships as a single Jamf [Script payload](#script-payload).

- `<<EOF` (unquoted): shell variables inside are expanded when written.
- `<<'EOF'` (quoted): content is written literally, for embedded scripts
  that expand their own variables at runtime.

**Related:** [Script payload](#script-payload), [plist](#plist).

---

### Inventory Update (recon)

The operation by which a managed Mac reports its current state (installed
apps, hardware, [Extension Attribute](#extension-attribute-ea) values,
profile status) back to the [Jamf Pro](#jamf-pro) server.

**The same operation has two names** depending on where you encounter it:

| Where you see it | What it's called |
|---|---|
| Jamf Pro web UI | `Update Inventory` (on a computer record's Management tab); `Inventory Update` (in history/logs) |
| [Jamf binary](#jamf-binary) on the endpoint | `recon` (the subcommand: `sudo jamf recon`) |
| Jamf docs, community posts, casual admin speech | usually just `recon` |

All three refer to one thing. Jamf community conventions lean heavily on
"recon" because it's what you type most often; deployment guides and UI
navigation use "Inventory Update" because that's what the UI labels it.

An inventory update happens automatically once per day and on-demand via
`sudo jamf recon`, the Jamf Pro UI (`Computers → <record> → Management
→ Update Inventory`), or the [Jamf Pro API](#jamf-pro-api).

[Smart Group](#smart-group) membership recalculates after each Mac's
inventory update, which is why you often see a ~1–5 minute delay between
running a recon and seeing updated scope.

**Related:** [Extension Attribute (EA)](#extension-attribute-ea), [Smart Group](#smart-group), [Jamf binary](#jamf-binary), [Jamf Pro API](#jamf-pro-api).

---

### Jamf binary

The agent software installed on every managed Mac at
`/usr/local/jamf/bin/jamf`. This is the process that communicates with
the [Jamf Pro](#jamf-pro) server — checks in on schedule, runs
[Policies](#policy), uploads [Inventory Updates](#inventory-update-recon),
and executes admin commands issued from the server.

Common invocations:
```bash
sudo jamf policy                      # run any pending policies now
sudo jamf policy -event <event>       # run a policy with a custom trigger
sudo jamf recon                        # force an inventory update
sudo jamf manage                       # re-apply management settings
sudo jamf removeFramework              # uninstall the Jamf binary (goodbye MDM)
```

Logs at `/var/log/jamf.log`.

**Related:** [Jamf Pro](#jamf-pro), [Policy](#policy), [Inventory Update](#inventory-update-recon).

---

### Jamf Composer

Jamf's GUI tool for creating `.pkg` installer packages on a Mac. Admins
"snapshot" a clean Mac, install something, snapshot again, and Composer
generates a `.pkg` containing the diff. Useful for packaging installers
that don't ship as a proper `.pkg` from the vendor.

Modern workflows often prefer declarative or script-based deployment
over Composer packages, but Composer is still the right tool for truly
file-based installs.

**Related:** [Jamf Pro](#jamf-pro).

---

### Jamf Connect

A Jamf product that replaces the macOS login window with a custom one
that authenticates against a cloud identity provider (IdP) like
[Entra ID](#entra-id), Okta, or Google. Creates and maintains a local
macOS user account whose password stays in sync with the cloud account.

Operationally relevant because password changes in the IdP propagate to
the Mac via Jamf Connect, affecting [keychain](#keychain) state,
[FileVault](#filevault) unlock, and any scripts that depend on the
console user's credential.

**Related:** [Entra ID](#entra-id), [FileVault](#filevault), [keychain](#keychain).

---

### Jamf Pro

The management platform most enterprise Apple deployments use to manage
Macs, iPhones, iPads, and Apple TVs. Jamf Pro is the
server-side MDM and enterprise management product; the agent on each
Mac is the [Jamf binary](#jamf-binary). Admins configure
[Policies](#policy), [Configuration Profiles](#configuration-profile),
[Smart Groups](#smart-group), [Extension Attributes](#extension-attribute-ea),
and more through the Jamf Pro web UI.

**Instance URL pattern:** `https://<instance>.jamfcloud.com`.

**Related:** [Jamf binary](#jamf-binary), [MDM](#mdm), [Policy](#policy).

---

### Jamf Pro API

The REST API exposed by [Jamf Pro](#jamf-pro) for programmatic access to
computer records, policies, configuration profiles, and every other
Jamf Pro object. Modern API endpoints live under `/api/v1/` and
`/api/v2/` and authenticate via OAuth 2.0 client-credentials grant using
an [API Client](#api-client) and [API Role](#api-role). The legacy
"Classic API" under `/JSSResource/` still exists but is being phased out.

**Token endpoint:** `POST /api/oauth/token` with client ID and secret.
**Token lifetime:** 10 minutes by default; scripts should fetch once and reuse.

**Related:** [API Client](#api-client), [API Role](#api-role).

---

### Jamf Protect

Jamf's endpoint detection and response (EDR) / anti-malware product for
macOS. Monitors system behavior for threats, blocks known-bad activity,
and forwards telemetry to a cloud console. Distinct from [Jamf Pro](#jamf-pro)
(management) and [Jamf Connect](#jamf-connect) (identity).

**On-endpoint evaluation:** `protectctl info` (requires appropriate
authorization — EPM evaluates the bundle path `/Applications/JamfProtect.app`).

**Related:** [Jamf Pro](#jamf-pro), [BeyondTrust EPM](#beyondtrust-endpoint-privilege-management-epm).

---

### keychain

macOS's native password and secret storage. Credentials are stored in
one of several keychains:

- **System keychain** (`/Library/Keychains/System.keychain`) — accessible only by root; used for daemon-level secrets, MDM-issued certificates, Wi-Fi profile keys, etc.
- **User login keychain** (`~/Library/Keychains/login.keychain-db`) — unlocked by the user's login password; holds Safari passwords, Wi-Fi credentials added interactively, etc.
- **iCloud keychain** — cross-device sync via Apple ID.

Scripts interact with keychains via the [`security`](#security-binary)
command. Common tasks: storing/retrieving API client secrets in the
System keychain, looking up the login password for FileVault operations.

**Related:** [`security` binary](#security-binary), [Configuration Profile](#configuration-profile).

---

### LaunchAgent

A [`launchd`](#launchd) job that runs in a **user** context — per-user,
started on login. LaunchAgents live in three locations (priority
descending):

| Path | Who delivers | Runs for |
|---|---|---|
| `/Library/LaunchAgents/` | Admin (via Jamf, Composer, or manual) | Every user who logs in |
| `~/Library/LaunchAgents/` | The user | Just that user |
| `/System/Library/LaunchAgents/` | Apple (don't touch) | Every user |

LaunchAgents are loaded when a user logs in (`gui/<uid>` domain) and
unloaded at logout. Use them when you need code running as the user —
for example, a menu bar item, a per-user cache-management job, or a
dialog that must appear on the user's screen.

**Related:** [LaunchDaemon](#launchdaemon), [`launchctl`](#launchctl), [`launchctl asuser`](#launchctl-asuser).

---

### `launchctl`

The command-line tool for interacting with [`launchd`](#launchd). Used
to load, unload, start, stop, list, and inspect LaunchDaemons and
LaunchAgents.

**Modern domain-target syntax:**
```bash
# Load a LaunchDaemon (system domain)
sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.plist

# Unload a LaunchDaemon
sudo launchctl bootout system /Library/LaunchDaemons/com.example.plist

# Load a LaunchAgent for a specific user
sudo launchctl bootstrap gui/501 /Library/LaunchAgents/com.example.plist

# List everything loaded in the system domain
sudo launchctl list

# Inspect a specific job
sudo launchctl print system/com.example
```

**Deprecated syntax (don't use in new scripts):** `launchctl load`, `launchctl unload` — superseded by `bootstrap` / `bootout`.

**Related:** [`launchd`](#launchd), [LaunchDaemon](#launchdaemon), [LaunchAgent](#launchagent).

---

### `launchctl asuser`

A [`launchctl`](#launchctl) subcommand that executes a given command in
the security context of a specific user, identified by UID. Essential
when a script running as root needs to launch something that must
appear on the user's screen (a [swiftDialog](#swiftdialog) window, a
browser, an AppleScript interacting with UI).

**Pattern:**
```bash
CONSOLE_USER=$(stat -f "%Su" /dev/console)
CONSOLE_UID=$(id -u "${CONSOLE_USER}")
launchctl asuser "${CONSOLE_UID}" sudo -u "${CONSOLE_USER}" /usr/local/bin/dialog --message "Hello"
```

The `sudo -u` inside is belt-and-suspenders — `asuser` sets the
launchd session context, and `sudo -u` sets the process UID/GID. Both
together produce the most reliable user-context execution.

**Related:** [console user](#console-user), [user context](#user-context), [root context](#root-context), [swiftDialog](#swiftdialog).

---

### `launchd`

The master process manager on macOS — PID 1, started at boot, owner of
every other process on the system. Replaced the classic Unix `init`,
`cron`, `inetd`, etc. Admins interact with `launchd` not by talking to
it directly, but by writing plist job definitions ([LaunchDaemons](#launchdaemon)
and [LaunchAgents](#launchagent)) and invoking [`launchctl`](#launchctl).

**Related:** [LaunchDaemon](#launchdaemon), [LaunchAgent](#launchagent), [`launchctl`](#launchctl).

---

### LaunchDaemon

A [`launchd`](#launchd) job that runs in the **system** context — as
root, with no user attached. Started at boot, or on-demand per its
plist's triggers. LaunchDaemons live at:

| Path | Who delivers |
|---|---|
| `/Library/LaunchDaemons/` | Admin (Jamf, Composer, manual) |
| `/System/Library/LaunchDaemons/` | Apple — don't touch |

Use LaunchDaemons for anything needing root context: enforcement
scripts, background services, scheduled maintenance, file-system
watchers via [WatchPath](#watchpath), periodic checks.

**Ownership / permissions required to load:** `root:wheel`, mode `644`.

**Related:** [`launchd`](#launchd), [LaunchAgent](#launchagent), [`launchctl`](#launchctl), [WatchPath](#watchpath), [root context](#root-context).

---

### Managed Apple Account

An Apple Account (formerly "Managed Apple ID") owned and issued by the
organization through [Apple Business Manager](#apple-business-manager-abm)
(or Apple School Manager), rather than a personal Apple Account the
employee creates. Managed Apple Accounts can be federated to an identity
provider like [Entra ID](#entra-id) or Google so users sign in with their
existing corporate credentials.

They enable organization-controlled iCloud services, app and book
assignment via [VPP / Apps and Books](#vpp--apps-and-books), and managed
sign-in on devices — while keeping corporate data separable from personal
data. IT can audit, suspend, and reclaim them, which a personal Apple
Account never allows.

**Related:** [Apple Business Manager (ABM)](#apple-business-manager-abm), [Entra ID](#entra-id), [VPP / Apps and Books](#vpp--apps-and-books), [Platform SSO (PSSO)](#platform-sso-psso).

---

### MDM

Mobile Device Management — a protocol (and ecosystem of products) for
remotely configuring and managing devices. On Apple platforms, MDM is
the mechanism by which an organization pushes Configuration Profiles,
commands (lock, wipe, restart), and declarative updates to enrolled
devices. [Jamf Pro](#jamf-pro) is an MDM server (among other things).
Competitors include Microsoft Intune, Kandji, Mosyle, Addigy.

Despite the "mobile" in the name, MDM covers Macs, iPhones, iPads,
Apple TVs, and Apple Watches.

**Related:** [Jamf Pro](#jamf-pro), [Configuration Profile](#configuration-profile), [ADE](#automated-device-enrollment-ade).

---

### `.mobileconfig`

The file extension for a [Configuration Profile](#configuration-profile).
A `.mobileconfig` file is an XML document (technically a [plist](#plist)
dictionary) containing one or more payloads. The file may be signed by
the MDM server for tamper-evidence.

Installed via double-click (for interactive testing) or pushed by MDM.
When delivered by Jamf Pro, the XML is generated on the fly from the
profile definition in the Jamf Pro UI; admins usually don't see the
raw `.mobileconfig` unless they export it.

**Related:** [Configuration Profile](#configuration-profile), [plist](#plist), [MDM](#mdm).

---

### Notarization

Apple's automated malware-scanning service for software distributed outside
the App Store. A developer uploads a signed app or installer to Apple, which
scans it and issues a notarization "ticket" that can be stapled to the
software. [Gatekeeper](#gatekeeper) checks for this ticket; notarized
software runs without the "unidentified developer" block.

Relevant when packaging in-house tools or repackaging vendor software for
[Jamf Pro](#jamf-pro) deployment: a `.pkg` or `.app` signed with a Developer
ID and notarized installs cleanly, while an unsigned one can trip Gatekeeper
or [XProtect](#xprotect) heuristics.

**Verify:** `spctl -a -vvv -t install <pkg>` (installers) or
`stapler validate <path>`.

**Related:** [Gatekeeper](#gatekeeper), [XProtect](#xprotect), [Jamf Composer](#jamf-composer).

---

### PAC file

Proxy Auto-Config file — a JavaScript file hosted at a known URL that
tells browsers and network clients which proxy (if any) to use for a
given destination. Organizations running a network proxy (like
[Zscaler](#zscaler)) publish a PAC file and configure devices to
consult it.

On Macs, the PAC URL is configured via a [Configuration Profile](#configuration-profile)
or manually in System Settings → Network → <interface> → Details →
Proxies. Scripts hitting external URLs may need to inspect the PAC
resolution or set proxy env vars (`HTTP_PROXY`, `HTTPS_PROXY`) accordingly.

**Related:** [Zscaler](#zscaler).

---

### Package

A macOS installer package (`.pkg`), installed with `installer -pkg`
or deployed by a Jamf [Policy](#policy) Packages payload. Packages are
uploaded to Jamf Pro (and its distribution points) and can carry files,
apps, and pre/post-install scripts. Often built with
[Jamf Composer](#jamf-composer) or `pkgbuild`.

**Related:** [Policy](#policy), [Jamf Composer](#jamf-composer).

---

### Platform SSO (PSSO)

A macOS feature (Ventura+, matured in Sonoma/Sequoia) that extends single
sign-on to the macOS login window and the whole session, backed by an
identity provider such as [Entra ID](#entra-id) or Okta. It is configured
via an [MDM](#mdm)-delivered [Configuration Profile](#configuration-profile)
with an app extension supplied by the IdP.

Platform SSO can keep the local account password in sync with the cloud
identity (or use a Secure Enclave-backed key / smart card), so users
authenticate once with their corporate credentials. It overlaps
conceptually with [Jamf Connect](#jamf-connect) but is Apple's native
framework rather than a third-party login window.

**Related:** [Entra ID](#entra-id), [Jamf Connect](#jamf-connect), [MDM](#mdm), [Managed Apple Account](#managed-apple-account).

---

### plist

Short for "property list" — Apple's preferred format for structured
configuration files. A plist is a typed dictionary (strings, integers,
booleans, dates, arrays, nested dictionaries). Plists exist in two
serializations:

- **XML plist** — human-readable, what you see when you open a
  `.plist` or [`.mobileconfig`](#mobileconfig) in a text editor.
- **Binary plist** — compact, machine-readable, what macOS writes by
  default when updating preference files.

Tools:
```bash
plutil -lint <file>            # validate syntax
plutil -p <file>                # pretty-print (any format)
plutil -convert xml1 <file>     # convert binary → XML
plutil -convert binary1 <file>  # convert XML → binary
```

**Related:** [`defaults`](#defaults), [`.mobileconfig`](#mobileconfig), [preference domain](#preference-domain), [LaunchDaemon](#launchdaemon).

---

### Policy

The unit of orchestration in [Jamf Pro](#jamf-pro). A Policy bundles
actions (run a script, install a package, add a printer, configure disk
encryption, etc.) with a [Scope](#scope), one or more [Triggers](#trigger)
that determine when it runs, and a [Frequency](#frequency) that
determines how often. The [Jamf binary](#jamf-binary) on each Mac pulls
applicable policies on check-in and executes them locally.

**Where to create:** `Computers → Policies`.

**Related:** [Jamf Pro](#jamf-pro), [Scope](#scope), [Trigger](#trigger), [Frequency](#frequency), [Script payload](#script-payload).

---

### PPPC

Privacy Preferences Policy Control — the Apple [Configuration Profile](#configuration-profile)
payload that pre-approves [TCC](#tcc) permissions for an app or binary
on managed Macs. Without PPPC, users see privacy prompts the first time
an app tries to access the camera, contacts, Full Disk Access, etc. —
and may deny them, breaking admin workflows.

PPPC pre-authorizes these services for a specified bundle identifier or
binary path with a specific code requirement (cryptographic signature
expression). Common uses: granting the Jamf binary Full Disk Access,
granting security agents Accessibility, pre-approving automation
permissions for installers.

**Caveats:**
- Only certain TCC services are pre-approvable via PPPC (Screen Recording, for example, cannot be; the user must click through).
- Code requirements must match exactly or PPPC is ignored.

**Related:** [TCC](#tcc), [Configuration Profile](#configuration-profile), [MDM](#mdm).

---

### preference domain

The namespace a [plist](#plist) uses for its keys, typically matching
the reverse-DNS name of the owning app or policy bundle (e.g.,
`com.apple.dock`, `com.example.tempadmin`). Scripts read preference
domains with [`defaults`](#defaults), and
[Configuration Profiles](#configuration-profile) deliver preference
domains to enforce values.

The same key name in different domains is independent — `com.apple.dock
Key` and `com.example.app Key` have nothing to do with each other.

**Related:** [`defaults`](#defaults), [Configuration Profile](#configuration-profile), [plist](#plist).

---

### PreStage Enrollment

A [Jamf Pro](#jamf-pro) configuration that defines what happens when a
new Mac (purchased through [Apple Business Manager](#apple-business-manager-abm)
and assigned to the MDM server) boots for the first time. The Mac
downloads the PreStage config during the Setup Assistant steps, uses it
to decide which accounts to create, which skip-screens to show the user,
which initial [Configuration Profiles](#configuration-profile) to apply,
and which [Policies](#policy) to run via the `Enrollment Complete`
trigger.

**Where to configure:** `Computers → PreStage Enrollments`.

**Related:** [Apple Business Manager (ABM)](#apple-business-manager-abm), [ADE](#automated-device-enrollment-ade), [MDM](#mdm).

---

### Recurring Check-in

The default [Trigger](#trigger) for most Jamf [Policies](#policy). The
[Jamf binary](#jamf-binary) on each Mac checks in with Jamf Pro on a
fixed schedule (15 minutes by default; configurable in `Settings →
Computer Management → Check-In`) and pulls any policies scoped to it
with this trigger enabled.

Most passive deployments use Recurring Check-in: the script will run
within 15 minutes of the Mac becoming in-scope. More urgent work
typically uses a [Custom Event](#custom-event) or different trigger
(e.g., `Enrollment Complete` for first-time provisioning).

**Related:** [Trigger](#trigger), [Policy](#policy), [Jamf binary](#jamf-binary).

---

### Rosetta 2

Apple's binary translation layer that lets Intel (`x86_64`) software run on
[Apple Silicon](#apple-silicon) Macs. It is not installed by default; some
enterprise apps, installers, or command-line tools that ship only as Intel
binaries require it.

Install it non-interactively as part of provisioning:
```bash
softwareupdate --install-rosetta --agree-to-license
```

Scripts that call an Intel-only binary should check for Rosetta and install
it first, or the call fails on Apple Silicon.

**Related:** [Apple Silicon](#apple-silicon).

---

### root context

A process running as user `root` (UID 0). On macOS, root is the
superuser — can read and write any file (outside of [SIP](#sip)-
protected paths), execute any binary, and sign as any user. Jamf
policies and [LaunchDaemons](#launchdaemon) run in root context.

Root context canNOT display GUI on a user's screen — that's
[user context](#user-context)'s job. Root also can't read a user's
login [keychain](#keychain) without the user's password.

**Related:** [user context](#user-context), [console user](#console-user), [`launchctl asuser`](#launchctl-asuser).

---

### Scope

The set of Macs (and optionally users) that a [Jamf Pro](#jamf-pro)
[Policy](#policy) or [Configuration Profile](#configuration-profile)
applies to. Scope is defined by:

- **Targets** — the positive set: [Smart Groups](#smart-group), [Static Groups](#static-group), individual computers, buildings, departments, or `All Managed Computers`
- **Limitations** — narrow by user, user group, network segment, or time-of-day
- **Exclusions** — subtract specific computers or groups from the Targets

The evaluation is `(Targets ∩ Limitations) − Exclusions`. Always add
test-fleet exclusions when first rolling something out.

**Related:** [Smart Group](#smart-group), [Static Group](#static-group), [Policy](#policy).

---

### Script payload

A reusable Bash (or other shell) script stored in [Jamf Pro](#jamf-pro)
at `Settings → Computer Management → Scripts`. Script payloads are
created once and then referenced by any number of [Policies](#policy).
When a Policy runs, the Jamf binary pulls the script's contents and
executes it on the endpoint, passing any parameters defined in the
Policy.

Scripts support positional parameters `$1`–`$11`. `$1`–`$3` are
reserved by Jamf for mount point, computer name, and username; `$4`–`$11`
are free for admin use and have labels defined on the Script payload
itself.

**Related:** [Policy](#policy), [Jamf Pro](#jamf-pro), [`expert-bash`](#expert-bash).

---

### Secure Token

A cryptographic token on APFS volumes that grants a user account the
ability to unlock [FileVault](#filevault). Only accounts with a Secure
Token can unlock the encrypted disk; accounts without one exist but
cannot authenticate at boot.

The first local user created on a Mac typically gets a Secure Token.
Subsequent users, or accounts created programmatically via `dscl`,
may need the token granted explicitly:

```bash
sudo sysadminctl -secureTokenOn <user> -password <pass> -adminUser <admin> -adminPassword <adminpass>
```

Relevant to provisioning scripts that create admin accounts — without
Secure Token, the account can't be used for FileVault unlock or for
many MDM-adjacent operations.

**Check status:** `sudo sysadminctl -secureTokenStatus <user>`.

**Related:** [FileVault](#filevault), [Bootstrap Token](#bootstrap-token), [Volume Ownership](#volume-ownership).

---

### `security` binary

The macOS command-line tool for interacting with [keychains](#keychain)
and certificates. Scripts use it to add, read, update, and delete
keychain items.

**Common operations:**
```bash
# Add a generic password to the System keychain
sudo security add-generic-password -a <account> -s <service> -w <password> /Library/Keychains/System.keychain

# Find and print a password (returns base64-encoded on some fields)
sudo security find-generic-password -a <account> -s <service> -w /Library/Keychains/System.keychain

# Delete an item
sudo security delete-generic-password -a <account> -s <service> /Library/Keychains/System.keychain

# Import a certificate
sudo security import /path/to/cert.p12 -k /Library/Keychains/System.keychain -P <p12-password>
```

**Related:** [keychain](#keychain).

---

### Self Service

[Jamf Pro](#jamf-pro)'s user-facing app (installed at `/Applications/Self
Service.app`) that lets end users browse and run admin-published
[Policies](#policy) on demand. Admins mark a Policy as "Available in
Self Service" to surface it as a clickable tile, complete with icon,
description, and category.

Self Service is also a [Trigger](#trigger) type — a Policy with Self
Service enabled is invokable both on its normal check-in trigger and
via the user clicking the tile.

Common uses: optional software installs, admin-elevation workflows
(like TempAdmin), compliance checks that users can re-run on demand.

**Related:** [Policy](#policy), [Jamf Pro](#jamf-pro), [Trigger](#trigger).

---

### Setup Assistant

The macOS first-boot experience that walks a new or freshly-erased Mac
through language, region, Apple Account sign-in, and — on an
[ADE](#automated-device-enrollment-ade)/[ABM](#apple-business-manager-abm)-enrolled
Mac — MDM enrollment. A [PreStage Enrollment](#prestage-enrollment) controls
which of these panes are shown or skipped and what is configured before the
user reaches the desktop.

Relevant to provisioning because policies bound to the `Enrollment Complete`
[Trigger](#trigger) and any "zero-touch" setup run during or immediately
after Setup Assistant — often before a user account exists.

**Related:** [PreStage Enrollment](#prestage-enrollment), [ADE](#automated-device-enrollment-ade), [Trigger](#trigger).

---

### SIP

System Integrity Protection — Apple's kernel-level protection for
system files. Even as root, you cannot modify `/System`, `/usr` (except
`/usr/local`), or `/bin` while SIP is enabled. Most system binaries,
Apple frameworks, and protected kernel extensions are shielded by SIP.

Disabling SIP requires booting into Recovery and running `csrutil
disable` — which is never acceptable for production fleet Macs. If a
script needs to write to a SIP-protected path, it's almost always the
wrong design; relocate to `/Library/Application Support/` or
`/usr/local/`.

**Check status:** `csrutil status`.

**Related:** [root context](#root-context), [Apple Silicon](#apple-silicon).

---

### Site

A [Jamf Pro](#jamf-pro) feature that partitions objects (computers,
policies, profiles, groups) so admins assigned to one site only see and
manage that site's objects. A [PreStage Enrollment](#prestage-enrollment)
can assign a site to computers as they enroll.

**Related:** [Jamf Pro](#jamf-pro), [PreStage Enrollment](#prestage-enrollment), [Scope](#scope).

---

### Smart Group

A [Jamf Pro](#jamf-pro) group whose membership is defined by criteria
and auto-recalculates as inventory changes. Example: "All Macs running
macOS < 14.5" — any Mac whose [Inventory Update](#inventory-update-recon)
reports a version below 14.5 automatically joins; any Mac that updates
auto-leaves. Used extensively for [Policy](#policy) and
[Configuration Profile](#configuration-profile) [Scope](#scope).

Criteria can reference hardware (model, RAM, disk), software (installed
apps, OS version), [Extension Attribute](#extension-attribute-ea) values,
user assignments, enrollment state, Jamf-native fields, and more.
Criteria can be combined with `and` / `or` logic, including parentheses
for complex groupings.

**Where to create:** `Computers → Smart Computer Groups`.

**Related:** [Static Group](#static-group), [Extension Attribute (EA)](#extension-attribute-ea), [Scope](#scope).

---

### Static Group

A [Jamf Pro](#jamf-pro) group whose membership is set explicitly by the
admin — a hand-picked list of computers. Contrast with
[Smart Groups](#smart-group), which are criteria-driven. Static Groups
are appropriate for truly manual selections: pilot cohorts, VIP
exclusion lists, computers assigned to a specific project.

**Related:** [Smart Group](#smart-group), [Scope](#scope).

---

### Supervised

A state on Apple devices (Macs, iPhones, iPads) that grants additional
MDM privileges not available on unsupervised devices — e.g., lock-screen
message enforcement, restricted pairing, certain app installation
controls. All devices enrolled via [ADE](#automated-device-enrollment-ade)
are automatically Supervised. User-enrolled (manual) Macs are not.

**Check status:** `profiles status -type enrollment`.

**Related:** [ADE](#automated-device-enrollment-ade), [MDM](#mdm), [UAMDM](#uamdm).

---

### swiftDialog

A free, open-source Swift-based tool for displaying user-facing dialog
windows from shell scripts on macOS. Drastically cleaner than AppleScript
`display dialog` or `osascript`. Installed to `/usr/local/bin/dialog`.

Supports titles, messages, banners, icons, progress bars, text input,
dropdowns, checkboxes, file pickers, JSON output (for capturing user
input), and command files (for updating a running dialog's content).

The UI dependency for most scripts that show anything to the user.

**Repo:** `github.com/swiftDialog/swiftDialog`.

**Related:** [`launchctl asuser`](#launchctl-asuser), [user context](#user-context).

---

### System Extension and Kernel Extension

Two mechanisms for extending macOS with low-level functionality (network
filters, endpoint security agents, VPN clients, drivers).

- **Kernel Extension (KEXT)** — legacy code loaded into the kernel. Powerful
  but risky; Apple has deprecated most KEXT use. Loading one on modern macOS
  requires user approval plus, on [Apple Silicon](#apple-silicon), a
  reduced-security boot policy — a significant deployment hurdle.
- **System Extension (SEXT)** — the modern user-space replacement (Network
  Extensions, Endpoint Security, DriverKit). Runs outside the kernel, so a
  crash can't panic the Mac. Products like [Jamf Protect](#jamf-protect) and
  VPN clients ship as System Extensions.

[MDM](#mdm) can pre-approve both via [Configuration Profiles](#configuration-profile)
(a System Extension payload and/or a KEXT allow-list) so users aren't
prompted and don't have to visit System Settings.

**Related:** [Configuration Profile](#configuration-profile), [PPPC](#pppc), [Apple Silicon](#apple-silicon), [Jamf Protect](#jamf-protect).

---

### T2

Apple's "T2 Security Chip" — a co-processor in 2018–2020 Intel Macs that
handled Touch ID, secure boot, [FileVault](#filevault) hardware
acceleration, and SSD encryption. Similar functionality is integrated
into the main SoC on [Apple Silicon](#apple-silicon) Macs, so T2 is now
a historical concern for Intel-era hardware still in the fleet.

**Related:** [Apple Silicon](#apple-silicon), [FileVault](#filevault), [Secure Token](#secure-token).

---

### TCC

Transparency, Consent, and Control — the macOS privacy framework that
manages per-app permissions for sensitive resources: camera, microphone,
contacts, calendars, photos, screen recording, Full Disk Access,
Accessibility, automation, and more.

TCC enforces these permissions via the private database at
`/Library/Application Support/com.apple.TCC/TCC.db` (system-level) and
`~/Library/Application Support/com.apple.TCC/TCC.db` (user-level). When
an app tries to access a protected resource for the first time, macOS
surfaces a prompt; the user's choice is persisted in TCC.db.

In enterprise deployments, [PPPC](#pppc) profiles pre-authorize TCC
permissions so users don't see prompts and admins don't get blocked by
denied access.

**Related:** [PPPC](#pppc), [Configuration Profile](#configuration-profile), [SIP](#sip).

---

### Trigger

The event that causes a [Jamf Pro](#jamf-pro) [Policy](#policy) to
execute. Options:

- `Startup` — when the Mac boots (runs before any user logs in)
- `Login` — when a user logs in
- `Enrollment Complete` — first check-in after MDM enrollment
- `Recurring Check-in` — on the regular check-in schedule (default ~15 min)
- `Network State Change` — when the Mac's network changes
- `Custom` — invoked by name via `jamf policy -event <name>`

A Policy can have multiple triggers checked. Trigger is distinct from
[Frequency](#frequency), which controls how often the policy can fire.

**Related:** [Policy](#policy), [Frequency](#frequency), [Recurring Check-in](#recurring-check-in), [Custom Event](#custom-event).

---

### UAMDM

User-Approved MDM — a state on Mac enrollments indicating the user (or
ADE pre-approval) has granted the MDM server permission to perform
certain privileged operations. Pre-2018, MDM could do almost anything
unilaterally; Apple tightened this and introduced UAMDM as a gating
mechanism.

Automated Device Enrollment Macs are UAMDM by default.
User-enrolled Macs require an explicit click in System Settings.
Without UAMDM, many MDM commands fail.

**Check status:** `profiles status -type enrollment` (look for `User Approved`).

**Related:** [ADE](#automated-device-enrollment-ade), [Supervised](#supervised), [MDM](#mdm).

---

### unified log

macOS's centralized logging system (since macOS 10.12). Replaces syslog,
ASL, and various ad-hoc log files. Every subsystem on the Mac — Apple
frameworks, third-party apps, scripts using `logger` — writes into the
unified log, which can be queried with `log show` (historical) and
`log stream` (live).

The unified log uses a structured query language with predicates:

```bash
log show --predicate 'eventMessage CONTAINS "com.example"' --info --last 1h
log stream --predicate 'process == "jamf"' --info --debug
log show --predicate 'subsystem == "com.apple.TCC"' --last 30m
```

Logs persist for a rolling window (days to weeks depending on disk
usage); they're not permanent. For durable logging, scripts should also
write to a file or ship logs off-device.

**Related:** [`expert-bash`](#expert-bash).

---

### user context

A process running as the currently-logged-in (console) user, inheriting
that user's environment: home directory, login [keychain](#keychain),
Wi-Fi credentials, GUI session, display connection. Only user-context
processes can display windows on the user's screen.

Scripts triggered by a Jamf policy run in [root context](#root-context)
by default. To launch something in user context, use
[`launchctl asuser`](#launchctl-asuser).

**Related:** [console user](#console-user), [`launchctl asuser`](#launchctl-asuser), [root context](#root-context), [LaunchAgent](#launchagent).

---

### Volume Ownership

An [Apple Silicon](#apple-silicon)-only requirement for certain
privileged operations on APFS volumes — specifically, operations that
modify the signed system volume (software update, kernel extension
approval). A user must be a "volume owner" to authorize these
operations on behalf of the Mac, and Volume Ownership is implicitly
granted alongside [Secure Token](#secure-token) on most standard user
creation paths.

If a scripted user creation doesn't produce Volume Ownership, MDM
commands may fail even with [Bootstrap Token](#bootstrap-token) escrowed.

**Check status:** `diskutil apfs listUsers /`

**Related:** [Apple Silicon](#apple-silicon), [Secure Token](#secure-token), [Bootstrap Token](#bootstrap-token).

---

### VPP / Apps and Books

Apple's mechanism for organizations to buy app and book licenses in volume
through [Apple Business Manager](#apple-business-manager-abm) (the feature is
now labeled "Apps and Books"; "VPP" — Volume Purchase Program — is the older
name still used in APIs and MDM settings). Purchased licenses are assigned to
devices or to [Managed Apple Accounts](#managed-apple-account) and deployed
by [MDM](#mdm), including paid apps, without an App Store password on the
device.

In [Jamf Pro](#jamf-pro) this appears as a "Volume Purchasing" location
token (`.vpptoken`) uploaded from ABM; apps are then scoped like any other
managed content.

**Related:** [Apple Business Manager (ABM)](#apple-business-manager-abm), [Managed Apple Account](#managed-apple-account), [MDM](#mdm).

---

### WatchPath

A key in a [LaunchDaemon](#launchdaemon) or [LaunchAgent](#launchagent)
plist that tells [`launchd`](#launchd) to start the job whenever a
file-system event occurs on the specified path(s). Events fire on
create, delete, and rename — **not** on content modification. A common
pattern is for a "trigger file" at a well-known path to be created by
one script, causing a watching LaunchDaemon to fire and run another
script.

**Example plist fragment:**
```xml
<key>WatchPaths</key>
<array>
    <string>/Library/Application Support/Example/trigger-reboot-check</string>
</array>
```

**Gotcha:** launchd will only start watching a path once it exists. If
the path is created after the daemon loads and the parent directory
didn't exist either, you may need to `bootout` and `bootstrap` the
daemon after directory creation.

**Related:** [LaunchDaemon](#launchdaemon), [`launchd`](#launchd), [`launchctl`](#launchctl).

---

### XProtect

Apple's built-in anti-malware for macOS. It has three parts: signature-based
blocking of known-malicious files (`XProtect`), a background remediation
engine (`XProtect Remediator`) that scans for and removes known threats, and
Gatekeeper/notarization enforcement. Apple updates the signatures silently
and frequently, independent of full OS updates.

XProtect is transparent to admins most of the time, but it can quarantine or
block an unsigned in-house tool — another reason to sign and
[notarize](#notarization) internally-distributed software. It complements,
rather than replaces, a managed EDR like [Jamf Protect](#jamf-protect).

**Check version:** `system_profiler SPInstallHistoryDataType | grep -A2 XProtect`,
or inspect `/Library/Apple/System/Library/CoreServices/XProtect.bundle`.

**Related:** [Gatekeeper](#gatekeeper), [Notarization](#notarization), [Jamf Protect](#jamf-protect).

---

### Zscaler

A cloud-based secure web gateway / proxy product. Organizations route
managed device web traffic through Zscaler, which inspects, filters, and
logs traffic before forwarding it to the internet. On Macs, Zscaler's
presence manifests as a [PAC file](#pac-file) delivered via a
[Configuration Profile](#configuration-profile), plus the Zscaler Client
Connector app running on the endpoint.

Scripts that hit external URLs need to account for Zscaler's presence:
connection behavior varies by Mac location (on-prem vs. VPN vs. external),
and some destinations may need explicit PAC bypass entries. The
`expert-bash` patterns include a network-detection helper that classifies
the current state (On Prem / VPN / External) and routes accordingly.

**Related:** [PAC file](#pac-file), [Configuration Profile](#configuration-profile).

---

## Adding new terms

When a deployment guide uses a term that isn't in this glossary yet,
add a new entry following the format above. Keep entries concise —
they are references, not tutorials. Every entry should:

1. Use an H3 heading with an anchor-friendly name
2. Define the term in 1–2 sentences for a reader who has never heard it
3. Explain why the term matters in an enterprise Apple context
4. Link related glossary entries where useful
5. Include a code example or command invocation when relevant

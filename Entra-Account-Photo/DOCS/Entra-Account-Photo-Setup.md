# EntraAccountPhoto — Setup & Deployment Notes

Sets a Mac's **local account picture** from the user's **Microsoft Entra ID**
profile photo. Ships as a **single Jamf Pro Script payload** — no package, no
config profile, no sidecar files required.

- **Default behaviour:** apply the Entra photo **once**, then never overwrite it
  again — the user's own picture choice always wins afterward.
- **Toggle:** flip one Jamf parameter (`$4 SYNC_MODE`) from `once` to `sync` to
  keep the local picture in lockstep with Entra (re-applies only when the Entra
  photo actually changes).

---

## 1. Entra (Azure AD) app registration

Create a dedicated app registration so a leaked secret can only read directory
users' basic profile + photo.

1. **Entra admin center → App registrations → New registration.**
   - Name: e.g. `Jamf – Local Account Photo (read-only)`.
   - Supported account types: *Accounts in this organizational directory only.*
   - No redirect URI needed (this is a daemon / client-credentials app).
2. **API permissions → Add a permission → Microsoft Graph → Application
   permissions → `User.Read.All`.** Remove the default delegated
   `User.Read` if present.
3. **Grant admin consent** for `User.Read.All` (the green check must appear).
   Application permissions do **not** work without admin consent.
4. **Choose an auth method** under **Certificates & secrets**:
   - **Certificate (preferred)** — *Certificates → Upload certificate.* Upload
     the **public** cert (`.cer`/`.crt`). Generate it and the combined PEM with:
     ```bash
     openssl req -x509 -newkey rsa:2048 -nodes \
       -keyout key.pem -out cert.pem -days 730 -subj "/CN=EntraAccountPhoto"
     cat cert.pem key.pem > entra-graph.pem   # goes in the config profile
     ```
     Upload `cert.pem` to Entra; the combined `entra-graph.pem` (cert **+**
     private key) goes into the config profile's `CertificatePEM` key. The script
     signs a **PS256 client assertion** with it — the private key never leaves
     the managed Mac and never touches disk (signed via openssl process
     substitution).
   - **Secret (fallback)** — *New client secret*, copy the **Value** immediately
     (shown once). Note the expiry / set a rotation reminder.
5. Record for deployment:
   - **Client ID** → Overview → *Application (client) ID*
   - **Tenant ID** → Overview → *Directory (tenant) ID*
   - **Auth material** → the combined PEM (certificate) **or** the client secret

> Minimum privilege: `User.Read.All` (application) is enough for
> `GET /users/{upn}` and `GET /users/{id}/photo/$value`. Do not add write
> scopes.
>
> Certificate vs. secret: certificate auth (PS256 client assertion) is preferred
> — no shared secret in transit, and certs generally outlive secrets. The script
> auto-selects certificate when `CertificatePEM` is present, else the secret.

---

## 2. Jamf Pro — Script object & parameters

Upload `Scripts/Entra-Account-Photo.sh` as a **Settings → Computer Management →
Scripts** object. Set the parameter **labels** on the *Options* tab:

| Param | Label | Value / notes |
|------|-------|---------------|
| `$4` | **Sync Mode** | `once` (default) or `sync`. Leave blank = `once`. **This is the mode toggle.** |
| `$5` | **Graph Client ID** | Entra *Application (client) ID* |
| `$6` | **Graph Tenant ID** | Entra *Directory (tenant) ID* |
| `$7` | **Graph Client Secret** | Client secret **Value** |
| `$8` | **UPN Domain Suffix** | Fallback only, e.g. `example.com` (used by source *c*) |
| `$9` | **Jamf Connect Token Path** | Default `/private/tmp/token` if blank |
| `$10`| **UPN Source** | `auto` (default), `psso`, `jamfconnect`, or `domain` |
| `$11`| **Credential Source** | `params` (default), `profile`, or `auto`. **The credential toggle** (see §2a). |

### 2a. Credential source toggle (`$11`) — params vs. config profile

`$11 CRED_SOURCE` controls where the script reads the Graph credentials
(`client_id` / `tenant_id` and the auth material — certificate **or** secret):

| Value | Behaviour |
|---|---|
| `params` *(default)* | Read from Jamf script parameters `$5`–`$7` (secret auth only). |
| `profile` | Read from a Custom Settings **Configuration Profile** (managed prefs); ignore `$5`–`$7`. |
| `auto` | Use the config profile if present & complete, else fall back to `$5`–`$7`. |

**Why use `profile`:** a secret in `$7` is readable by anyone with **Read
Scripts** / policy-read in Jamf and appears in the policy log. A config profile
delivers the credentials into `/Library/Managed Preferences/<domain>.plist`,
which is **root-readable only** on the endpoint and is not exposed through the
script object — a smaller read surface. It is also the **only** place the
`CertificatePEM` is read from (a PEM is too large/sensitive for a Jamf param).

**Keys the profile must contain** (all String): **`ClientID`**, **`TenantID`**,
plus **exactly one** auth key:

| Key | Auth method | Notes |
|---|---|---|
| `CertificatePEM` | Certificate (preferred) | Full combined PEM: the certificate block, then the private-key block (BEGIN/END lines kept). Script signs a PS256 client assertion. |
| `ClientSecret` | Secret (fallback) | Used only when `CertificatePEM` is absent. |

**Set up the profile:**

1. **Pick your preference domain.** The script exposes a standalone, editable
   variable near the top of *User Defined Variables*:

   ```bash
   readonly CONFIG_PROFILE_DOMAIN="${ORG_PLIST_DOMAIN}.entraphoto"
   ```

   Set it to whatever domain you want (e.g. `com.example.graphcreds`). It defaults
   to `<ORG_PLIST_DOMAIN>.entraphoto` but you can replace the whole value with
   any literal. Whatever you choose must match the profile's Preference Domain in
   Jamf (and, if you upload a plist, the plist filename in `ConfigurationProfiles/`).

2. **Create the profile** in **Jamf Pro → Computers → Configuration Profiles →
   New → Application & Custom Settings**, using either delivery method:

   - **Method A — JSON Schema (recommended; renders a fillable form).** Choose
     **External Applications**, set **Source: Custom Schema**, **Preference
     Domain** = your `CONFIG_PROFILE_DOMAIN`, and paste the contents of
     `ConfigurationProfiles/com.company.entraphoto.schema.json`. Jamf renders four
     fields — Client ID, Tenant ID, Certificate PEM, Client Secret — with help
     text; fill in Client ID + Tenant ID and paste the combined PEM into
     **Certificate PEM** (leave Client Secret blank), or vice-versa.
     *Note:* the schema deliberately contains no `anyOf`/`oneOf` — Jamf's form
     builder renders those as a stray dropdown. The "exactly one auth key" rule
     lives in the field descriptions and is enforced by the script.
   - **Method B — upload a plist.** Choose **Custom Settings** (Upload),
     **Preference Domain** = your `CONFIG_PROFILE_DOMAIN`, and upload an edited
     copy of `ConfigurationProfiles/com.company.entraphoto.plist` (rename it to
     `<your-domain>.plist`; replace the `REPLACE-WITH-*` values; delete whichever
     auth key you are not using).

3. **Level: Computer** (device-wide) so it lands at
   `/Library/Managed Preferences/<your-domain>.plist`. Scope to the same Macs as
   the policy.
4. Set the policy's `$11` to `profile` (or `auto`). Leave `$5`–`$7` blank.

> If the **Certificate PEM** field renders as a single line (older Jamf ignoring
> the schema's `"format": "textarea"`), it is cosmetic — the multi-line PEM still
> pastes and stores correctly (newlines are preserved and remain openssl-usable).

> Note: a config profile reduces the *Jamf-script* read surface but is not a
> vault — anyone who can read the Configuration Profile object in Jamf can still
> see the secret. Restrict who can view profiles, use the dedicated read-only app
> registration, and rotate the secret regularly regardless of source.

### Secret-in-Jamf tradeoff (params mode)

Passing the client secret as `$7` means anyone with **Read Scripts** (or who can
read the policy) in Jamf Pro can see it, and it is visible in the policy log
payload. Mitigations: use the dedicated read-only app registration, audit who
holds **Read Scripts** / policy-read, rotate on a schedule — or switch `$11` to
`profile` (§2a) to move the secret out of the script entirely.

Regardless of source, the script **refuses to run** (exit 3) if it cannot
assemble all three credential values — an unconfigured deployment fails loudly
rather than silently failing OAuth.

---

## 3. Where it fits in an enrollment checklist

Run it as a **post-login enrollment/checklist step** (a console user is guaranteed to
exist). On devices that are PSSO-registered (or use Jamf Connect with Entra),
the UPN is resolvable by the time this step runs.

- **`once` mode (default):** safe to leave in the checklist permanently. After
  the first successful apply (or a recorded "no photo"), every later run
  short-circuits via the per-user marker before any network call.
- **`sync` mode:** it will re-check Entra on every checklist run but only
  re-downloads / re-applies when the photo's `@odata.mediaEtag` changes. For a
  true "keep in sync forever" posture you'd later move it behind a
  LaunchAgent/Daemon or a recurring policy — the script logic is unchanged; only
  the invocation cadence differs.

---

## 4. How UPN resolution works (source order)

Controlled by `$10 UPN_SOURCE` (default `auto`, tries in order):

1. **PSSO** *(preferred on PSSO-registered devices)* — queries the
   Platform SSO extension as the console user (`app-sso platform -s`) and reads
   its `"upn"` field. PSSO stores this as a **Kerberos principal**, e.g.
   `first.last\@example.com@KERBEROS.MICROSOFTONLINE.COM` — the real UPN's `@`
   is backslash-escaped and the Kerberos realm is appended. The script strips
   the trailing `@REALM` and unescapes to recover the plain
   `first.last@example.com` before calling Graph. (Confirmed against a live
   PSSO Mac; verified in unit tests for both JSON and text-fallback forms.)
2. **Jamf Connect** — reads `UserPrincipal` (then `UserEmail`) from
   `~/Library/Preferences/com.jamf.connect.state.plist`; if absent, decodes the
   ID-token JWT at `$9` (`upn` / `preferred_username` / `unique_name` claim).
3. **Username + domain** — `<console_user>@<$8 domain suffix>` as a last resort
   (only if `$8` is set).

---

## 5. Behaviour summary

| Situation | `once` | `sync` |
|---|---|---|
| First run, no marker | Download & apply, write marker | Download & apply, write marker |
| Later run, marker present, Entra photo **unchanged** | Skip (no network after marker read) | Skip (etag matches) |
| Later run, Entra photo **changed** | Skip — user's choice wins | Re-download & re-apply |
| Entra returns **404 / no photo** | Write `no-photo` marker, **leave local pic untouched**, stop retrying | Same — 404 stops future attempts in both modes |
| No console user | Clean no-op (exit 0) | Clean no-op (exit 0) |

**Apply mechanics (macOS):** the JPEG is stored under
`/Library/User Pictures/<Org>/<user>.jpg`; the script `dscl . delete`s the
`JPEGPhoto` + `Picture` keys, sets `Picture` to the stored path, then imports the
binary `JPEGPhoto` via `dsimport` (dscl cannot write binary values). Deleting
before re-creating makes the apply reliable.

---

## 6. FileVault preboot icon caching caveat

The account picture shown at the **FileVault preboot (EFI) login screen** is
cached separately from the live macOS account picture. A freshly applied photo
may **not** appear at the preboot screen until macOS rebuilds those preboot
resources — typically after a reboot (macOS refreshes the preboot volume) or on
its own schedule. This is cosmetic and expected: the picture is correct inside
the macOS session and at the standard (post-boot) login window immediately; only
the pre-unlock EFI screen lags. No action is required.

---

## 7. Logs & exit codes

- **Dedicated log:** `/Library/Logs/<Org>/EntraAccountPhoto.log`
- Also dual-logged to the unified log (`LOG_LABEL = <domain>.EntraAccountPhoto`)
  and `/var/log/jamf.log`.
- **Marker/receipt:** `/Library/Application Support/<Org>/entra-photo-set/<user>`
  (JSON: `status`, `mediaEtag`, `appliedDate`, `syncMode`). Delete this file to
  force a re-apply during testing.

| Code | Meaning |
|---|---|
| 0 | Success, skipped, or clean no-op |
| 1 | Not run as root |
| 3 | Credentials unavailable (params blank/placeholder, or config profile missing/incomplete), invalid `CRED_SOURCE`, or `jq` absent |
| 4 | Could not resolve a valid Entra UPN |
| 5 | OAuth token request failed |
| 6 | Graph user lookup failed / user not found |
| 7 | Photo download or apply failed |
| 8 | Invalid `SYNC_MODE` |

### Local test (before Jamf)

```bash
sudo /path/to/Entra-Account-Photo.sh "" "" "" \
  once <CLIENT_ID> <TENANT_ID> <CLIENT_SECRET>
# ("" "" "" stand in for Jamf's reserved $1-$3)
# Re-run to confirm 'once' short-circuits; delete the marker to re-apply.
```

# VS Code security extensions distribution via GPO

Companion to the deployment entry points. In a source checkout they are
`scripts/windows/deploy.ps1` and `scripts/unix/deploy.sh`; the operational ZIP
places them at its root. This integration covers **VS Code extensions only** —
the rest of the package (CLAUDE.md, MCP, permissions, git hooks) continues to be
applied by the deployment scripts.

Maintained by: Security/IT

---

## Table of contents

1. [Why GPO for this](#1-why-gpo-for-this)
2. [What GPO does NOT do](#2-what-gpo-does-not-do)
3. [Option 1: Logon script (recommended)](#3-option-1-logon-script-recommended)
4. [Option 2: Pre-downloaded .vsix (offline / restricted proxy)](#4-option-2-pre-downloaded-vsix)
5. [Option 3: Restriction ADMX (complementary)](#5-option-3-restriction-admx)
6. [Corporate security baseline](#6-corporate-security-baseline)
7. [Verification](#7-verification)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Why GPO for this

VS Code extensions are **per user profile**, and the `code` binary must run
in that user's context. On Linux/macOS `deploy.sh` handles this with
`sudo -u <user>`. On Windows there is no direct equivalent: `deploy.ps1`
registers a scheduled task with `-LogonType Interactive`, which **only executes
if that user is logged in at deployment time**.

Practical consequence: in an off-hours deployment, or via **Falcon RTR**
(which runs as SYSTEM), most developers do not receive the extensions. The rest
of the package is applied normally, because those files are written directly into the profile directory.

A GPO logon script solves this: it runs when the user logs in, within their context.

**If you use GPO for extensions**, run deployment with `-SkipVSCode`
to avoid duplicating work:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\deploy.ps1 -Force -SkipVSCode
```

---

## 2. What GPO does NOT do

Align expectations before configuring GPO.

Starting with version 1.69, each VS Code release includes a `policies` directory
with ADMX templates. The available policies manage **restriction and
configuration**: `AllowedExtensions`, `ExtensionsAutoUpdate`,
`ExtensionsAutoUpdateDelay`, `ExtensionGalleryServiceUrl`, `UpdateMode`, among
others.

**No VS Code policy installs extensions.** `ExtensionsAutoUpdate` controls
updates for already installed extensions, not initial installation. There is no
native "Deploy Extensions" equivalent.

The ADMX templates serve to **lock down** what can be installed (section 5), while
installation itself must come from a script (section 3) or pre-staged files
(section 4).

---

## 3. Option 1: Logon script (recommended)

### 3.1 Place the script in SYSVOL

Copy `install-extensions.ps1` (in this folder) to the GPO scripts share:
the path appears when clicking **Show Files...** in the GPO editor, typically:

```text
\\<domain>\SYSVOL\<domain>\Policies\{GPO-GUID}\User\Scripts\Logon\
```

### 3.2 Create the GPO

1. **Group Policy Management** → New GPO, e.g. `VSCode - Security Extensions`
2. Link to developer OU (not entire domain)
3. Edit: **User Configuration → Policies → Windows Settings → Scripts (Logon/Logoff) → Logon**
4. Tab **PowerShell Scripts** → **Add** → `install-extensions.ps1`
5. Under **For this GPO, run scripts in the following order**, select
   *Run Windows PowerShell scripts first*

### 3.3 Set execution policy

GPO logon scripts adhere to machine Execution Policy. If set to
`Restricted`, the script will not run. Configure under:

**Computer Configuration → Policies → Administrative Templates → Windows Components
→ Windows PowerShell → Turn on Script Execution** → `Allow local scripts and remote signed scripts`

### 3.4 Script behavior

`install-extensions.ps1` is tailored for logon execution:

- **Idempotent**: queries `code --list-extensions` and only installs missing extensions.
  On subsequent logons it exits in less than 1 second.
- **Exits silently if VS Code is not installed**: generates no noise for non-developers.
- **Does not block logon**: enforces per-extension timeout and always terminates with exit 0.
- **Logs to** `%LOCALAPPDATA%\Temp\vscode-sec-ext.log` for troubleshooting.
- **Accepts `-Vsix <directory>`** for offline mode in section 4.

---

## 4. Option 2: Pre-downloaded .vsix

**Fallback, not the default.** Use only when machines cannot reach
`marketplace.visualstudio.com` (restrictive proxy, segmented network, air-gap).

### Why online mode is preferred

The extensions total **~234 MB** + Trivy:

| Extension | Size |
|---|---|
| sonarsource.sonarlint-vscode | ~170 MB (bundles embedded analyzers) |
| semgrep.semgrep | ~64 MB |
| AquaSecurityOfficial.trivy-vulnerability-scanner | ~20 MB |
| usernamehw.errorlens | 0.1 MB |

In offline mode this is transferred from the file server on each user's initial logon.
If the share is across a WAN/VPN, initial logon will be slowed; consider DFS
replication before choosing this approach.

In online mode each workstation downloads directly from marketplace once. In both
cases the script is idempotent, exiting in under a second once installed.

### 4.1 Download .vsix files

Run once from an internet-connected workstation:

```powershell
.\download-vsix.ps1 -OutDir \\fileserver\sw$\vscode-ext
```

Or manually using the URL template:

```text
https://marketplace.visualstudio.com/_apis/public/gallery/publishers/<PUBLISHER>/vsextensions/<EXTENSION>/<VERSION>/vspackage
```

> **Caution with `curl`**: this endpoint returns **gzip-compressed** bodies even
> without `Accept-Encoding`. `curl -o file.vsix` without `--compressed` writes raw gzip
> resulting in an invalid archive (`code` rejects it with "not a valid zip").
> Use `curl --compressed` or PowerShell `Invoke-WebRequest`, which decompresses automatically.

### 4.2 Point the logon script to the share

In the GPO **PowerShell Scripts** tab, under **Script Parameters**:

```text
-Vsix \\fileserver\sw$\vscode-ext
```

The script installs from local files without contacting the marketplace.
Ensure the share grants **Read** to `Domain Users` / `Authenticated Users`.

### 4.3 Maintenance

The `.vsix` approach freezes versions. Refresh files periodically; otherwise
security scanners become outdated. If `ExtensionsAutoUpdate` is enabled and
machines have marketplace access, VS Code updates them automatically after initial install.

---

## 5. Option 3: Restriction ADMX

Complementary; does not replace the options above. Prevents developers from
installing unapproved extensions.

### 5.1 Obtain templates

ADMX templates ship with VS Code: download the release **.zip** (not installer)
and extract the `policies` folder, containing `.admx` and `.adml` files under `locales`.

### 5.2 Install in Central Store

```text
\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\VSCode.admx
\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\en-US\VSCode.adml
```

### 5.3 Configure

**Administrative Templates → Visual Studio Code**

| Policy | Usage |
|---|---|
| `AllowedExtensions` | Allowlist of permitted extension IDs |
| `ExtensionsAutoUpdate` | Keep security extensions updated |
| `ExtensionGalleryServiceUrl` | Point to internal marketplace, if configured |
| `UpdateMode` | Control VS Code application updates |

> **Caution with `AllowedExtensions`**: this is an exclusive allowlist. If you list only the 4
> security extensions, **all other extensions are disabled** for developers.
> Include all required team extensions or pilot in a test OU first.

---

## 6. Corporate security baseline

`vscode-policy.json` is the versioned baseline for enterprise VS Code settings.
It is not applied by `deploy.ps1`: GPO/Intune/MDM must deploy equivalent values
after testing. The baseline disables telemetry and feedback and prevents global
auto-approval of tools and terminal commands in chat workflows.

| Policy | Value | Purpose |
|---|---:|---|
| `TelemetryLevel` | `off` | Disables VS Code telemetry. |
| `EnableFeedback` | `false` | Disables feedback mechanisms. |
| `ChatToolsAutoApprove` | `false` | Blocks global tool auto-approval. |
| `ChatToolsTerminalEnableAutoApprove` | `false` | Blocks terminal command auto-approval. |

On Linux, copy the file to `/etc/vscode/policy.json` (VS Code 1.106+) via MDM
or configuration management. On Windows, configure the same policies via ADMX; on
macOS, via MDM profile. Do not add `AllowedExtensions` until a comprehensive
corporate catalog exists.

---

## 7. Verification

**On workstation after logon:**

```powershell
code --list-extensions | Select-String -Pattern 'semgrep|sonarlint|errorlens|trivy'
```

Expected output:

```text
AquaSecurityOfficial.trivy-vulnerability-scanner
semgrep.semgrep
sonarsource.sonarlint-vscode
usernamehw.errorlens
```

**An installed extension is not necessarily active.** None run in Restricted Mode.
Confirm that developer has trusted the parent repository directory
(`Ctrl+Shift+P` -> `Workspace Trust`); otherwise scanner extensions remain inactive.
There is no GPO policy to automate Workspace Trust.

**Script log:**

```powershell
Get-Content "$env:LOCALAPPDATA\Temp\vscode-sec-ext.log" -Tail 20
```

**Check GPO application:**

```powershell
gpresult /h "$env:TEMP\gp.html"; Start-Process "$env:TEMP\gp.html"
```

Look for the GPO under *User Configuration → Scripts*. If missing, check OU linking
and Security Filtering (*Read* + *Apply* permissions required).

**Applied corporate policies:** run `Developer: Policy Diagnostics` in the Command Palette.
Treat output as internal data as it may contain account identifiers.

---

## 8. Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| Script does not run at logon | Execution Policy set to `Restricted` | Section 3.3 |
| GPO does not appear in `gpresult` | Incorrect OU link or Security Filtering | Verify link and Security Filtering (*Read* + *Apply*) |
| Runs but installs nothing | `code` not in PATH during logon | Script tests absolute paths; verify resolved path in log |
| `.vsix` rejected ("not a valid zip") | Downloaded via `curl` without `--compressed` | Section 4.1 |
| Extensions vanish after reinstalling VS Code | Profile recreated | Logon script is idempotent; reinstalls on next logon |
| Installed into wrong profile | Script ran as SYSTEM instead of user | Must be **User Configuration → Logon**, not Computer/Startup |
| Slow logon | Large extensions + slow network | Use `.vsix` mode (section 4) |
| `AllowedExtensions` broke developer workflows | Allowlist excludes unlisted extensions | Section 5.3; include all team extensions or disable |

---

## Summary

```text
deploy.ps1 / deploy.sh   -> CLAUDE.md, MCP, permissions, git hooks
   (run with -SkipVSCode if using GPO for extensions)

GPO logon script         -> VS Code extensions in user context
ADMX AllowedExtensions   -> (optional) locks down installable extensions
vscode-policy.json       -> Security baseline for GPO/Intune/MDM
```

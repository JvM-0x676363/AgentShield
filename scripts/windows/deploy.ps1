# Security AI Config - Multi-User Fleet Deployment (Windows, PowerShell 5.1+)
# Discovers user profiles and installs security configurations into each one.
# Usage: powershell -ExecutionPolicy Bypass -File .\deploy.ps1 [-DryRun] [-Force]
# Requires: run as Administrator

param(
    [switch]$DryRun,
    [switch]$Force,       # do not prompt for interactive confirmation (SCCM/Intune/Falcon RTR)
    [switch]$SkipTools,   # skip tool downloads (configuration only -- fast run)
    [switch]$SkipVSCode,  # skip VS Code extensions (slowest item)
    # AI config selectors: all | claude | codex | antigravity
    # | vscode | managed | <target id>. Default: all.
    [string[]]$Only = @("all"),
    [switch]$ListTargets,
    [string]$LogPath = (Join-Path $env:SystemRoot "Temp\agent-shield-deploy.log"),
    [ValidateSet("Console", "Json", "Quiet")]
    [string]$OutputMode = "Console"
)

$ScriptLocation = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Source checkout: scripts\windows\. Distribution ZIP: package root.
$ScriptDir = if (Test-Path (Join-Path $ScriptLocation "policy")) {
    $ScriptLocation
} else {
    Split-Path -Parent (Split-Path -Parent $ScriptLocation)
}
$script:RunId = [guid]::NewGuid().ToString()
$script:StartedAtUtc = [DateTime]::UtcNow

if ($OutputMode -ne "Console") {
    $InformationPreference = "SilentlyContinue"
    $WarningPreference = "SilentlyContinue"
}
$script:OutputMode = $OutputMode

function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [object]$Object,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline,
        [object]$Separator
    )
    if ($script:OutputMode -eq "Console") {
        Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
    }
}

function Write-AgentShieldEvent {
    param([string]$Event, [string]$Phase = "")
    if ($script:OutputMode -eq "Json") {
        [ordered]@{
            schema_version = 1
            event = $Event
            phase = $Phase
            run_id = $script:RunId
            timestamp_utc = [DateTime]::UtcNow.ToString("o")
            runner = "deploy"
            scope = "fleet"
            dry_run = [bool]$DryRun.IsPresent
            selected = @($Only)
        } | ConvertTo-Json -Compress -Depth 3
    }
}

if ($ListTargets) {
    & (Join-Path $ScriptDir "lib\ApplyTargets.ps1") -Root $ScriptDir -ListTargets
    exit $LASTEXITCODE
}

function Info($msg)    { Write-Host "[INFO] $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Err($msg)     { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Section($msg) { Write-Host "`n========== $msg ==========" -ForegroundColor Cyan }
function Sep()         { Write-Host "  -------------------------------------------" -ForegroundColor DarkGray }

function Write-TextFileUtf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}
function Write-ShellScript {
    param([string]$Path, [string]$Content)
    # Git hooks run under sh.exe: BOM or CRLF breaks the shebang.
    $lf = $Content -replace "`r`n", "`n"
    Write-TextFileUtf8NoBom -Path $Path -Content $lf
}

# Files created by Admin inside another user's profile get incorrect ownership
# and the developer cannot edit them. Grant full control back to the target user.
function Grant-UserOwnership {
    param([string]$Path, [string]$Username)
    if (-not (Test-Path $Path)) { return }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & icacls.exe $Path /grant "${Username}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
        $timer.Stop()
        Info "    ownership repair: $Path ($([math]::Round($timer.Elapsed.TotalSeconds, 1))s)"
    } catch {
        Warn "    icacls failed for $Path -- $Username might not be able to edit the file"
    }
}

function Invoke-AgentShieldEngine {
    param([hashtable]$Arguments)
    if ($script:OutputMode -eq "Console") {
        & $applyScript @Arguments
    } else {
        & $applyScript @Arguments 6>$null
    }
}

# Remote execution tools (Falcon RTR, SCCM) truncate stdout. Record a transcript
# to disk so it can be retrieved later (RTR: `get <LogPath>`).
$script:TranscriptOn = $false
try {
    Start-Transcript -Path $LogPath -Append -Force -ErrorAction Stop | Out-Null
    $script:TranscriptOn = $true
} catch {
    # Restricted runspaces do not support transcripts -- not a reason to abort.
}

if ($DryRun) { Info "Dry-run mode -- no changes will be made`n" }
Write-Host "`n=== AgentShield | fleet deployment ===" -ForegroundColor Cyan
Info "Execution mode: $(if ($DryRun) { 'dry-run' } else { 'apply' }); runner=deploy; selected=$($Only -join ',')"
Info "Run ID: $script:RunId"
Write-AgentShieldEvent -Event "start"

# --- Execution context ---
$whoami = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
# $Host.UI does not support prompt in non-interactive runspaces (RTR runs as SYSTEM).
$isInteractive = -not $isSystem -and [Environment]::UserInteractive
Info "Running as: $whoami (SYSTEM=$isSystem, interactive=$isInteractive)"
Info "Log: $LogPath"

if ($isSystem) {
    Warn "SYSTEM context detected (Falcon RTR / SCCM / scheduled task)."
    Warn "  DO NOT use install.ps1 here: it writes to `$env:USERPROFILE, which under"
    Warn "  SYSTEM points to C:\Windows\system32\config\systemprofile."
    Warn "  deploy.ps1 is the correct script -- it explicitly iterates user profiles."
}

# --- Verify administrator privileges ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
# Dry-run writes nothing, so requiring Admin there protected nothing and prevented
# previewing the deployment plan. Same reason as deploy.sh: the gate hid script
# paths from tests.
if (-not $isAdmin) {
    if ($DryRun) {
        Warn "Not running as Administrator -- dry-run continues (nothing will be written)."
        Warn "  In a real run: open PowerShell as Admin."
    } else {
        Err "This script must be run as Administrator."
        Err "Open PowerShell as Admin and try again."
        exit 1
    }
}

# --- Validation of source files (before touching any profile) ---
# Per-tool configuration lives in targets\*.json + policy\*. Only check roots:
# the engine validates each manifest and each referenced payload_file/compose.
$required = @("lib\ApplyTargets.ps1", "lib\SecurityTools.ps1", "lib\CodexSandboxProfile.ps1", "policy\core-guidelines.md", "policy\policy.json", "policy\tools.json", "hooks\pre-commit")
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $ScriptDir $f))) {
        Err "File not found: $(Join-Path $ScriptDir $f)"
        Err "Run the script from the root of the AgentShield repository."
        exit 1
    }
}
if (-not (Test-Path (Join-Path $ScriptDir "targets"))) {
    Err "Directory not found: $(Join-Path $ScriptDir 'targets')"
    exit 1
}

# Read sources once. CLAUDE.md was removed from here: the engine composes
# guidelines (core + vendor appendix) from policy\.
$SrcHook       = [System.IO.File]::ReadAllText((Join-Path $ScriptDir "hooks\pre-commit"))

# Detection functions

function Find-UserInstall {
    param([string]$ProfilePath, [string]$Username, [string]$Principal)

    $result = @{
        Username = $Username
        Principal = $Principal
        Profile  = $ProfilePath
        Score    = 0
        Evidence = @()
    }

    if (Test-Path "$ProfilePath\.gitconfig") {
        $result.Score++
        $result.Evidence += "git (.gitconfig found)"
    }

    $vscodePaths = @(
        "$ProfilePath\AppData\Roaming\Code\User\settings.json",
        "$ProfilePath\AppData\Local\Programs\Microsoft VS Code\Code.exe",
        "$ProfilePath\.vscode\extensions"
    )
    foreach ($p in $vscodePaths) {
        if (Test-Path $p) { $result.Score++; $result.Evidence += "vscode ($p)"; break }
    }

    $claudePaths = @(
        "$ProfilePath\.claude",
        "$ProfilePath\.claude.json",
        "$ProfilePath\AppData\Roaming\npm\claude.cmd",
        "$ProfilePath\AppData\Local\Programs\claude"
    )
    foreach ($p in $claudePaths) {
        if (Test-Path $p) { $result.Score++; $result.Evidence += "claude-code ($p)"; break }
    }

    if (Test-Path "$ProfilePath\AppData\Roaming\Claude") {
        $result.Score++
        $result.Evidence += "claude-desktop (AppData\Roaming\Claude)"
    }

    if (Test-Path "$ProfilePath\AppData\Roaming\npm") {
        $result.Score++
        $result.Evidence += "node/npm"
    }

    return $result
}

function Get-AllUserProfiles {
    $profiles = @()
    $systemAccounts = @("systemprofile","LocalService","NetworkService","defaultuser0","Default","Public","All Users","Default User")

    # Get-CimInstance replaces Get-WmiObject (removed in PowerShell 7+).
    try {
        $cimProfiles = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path $_.LocalPath) }

        foreach ($p in $cimProfiles) {
            try {
                $sid      = New-Object System.Security.Principal.SecurityIdentifier($p.SID)
                $ntUser   = $sid.Translate([System.Security.Principal.NTAccount])
                $username = $ntUser.Value.Split("\")[-1]
                $principal = $ntUser.Value
            } catch {
                $username = Split-Path $p.LocalPath -Leaf
                $principal = $null
            }

            if ($systemAccounts -contains $username) { continue }
            # ServiceProfiles: service accounts (OpenVPNService, etc.). Not always
            # marked with Special=$true, so also filter by profile path.
            if ($p.LocalPath -match "systemprofile|ServiceProfiles|LocalService|NetworkService|defaultuser") { continue }
            # Profiles outside the Windows Users root are not developers.
            if ($p.LocalPath -notlike "$(Join-Path $env:SystemDrive 'Users')\*") { continue }

            $profiles += @{ Username = $username; Principal = $principal; Profile = $p.LocalPath }
        }
    } catch {
        Warn "Win32_UserProfile failed, using folder fallback..."
    }

    # Fallback: list the profiles root (does not assume C:).
    if ($profiles.Count -eq 0) {
        $usersRoot = Join-Path $env:SystemDrive "Users"
        if (Test-Path $usersRoot) {
            Get-ChildItem $usersRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $systemAccounts -notcontains $_.Name } |
                ForEach-Object { $profiles += @{ Username = $_.Name; Principal = $null; Profile = $_.FullName } }
        }
    }

    return $profiles
}

# SECURITY TOOLS INSTALLATION (machine-level - once, not per user)
Write-AgentShieldEvent -Event "phase" -Phase "security_tools"
Section "Security Tools - Installation (machine-level)"
if ($SkipTools) {
    Info "  Skipped (-SkipTools) -- run a second pass without the flag to install tools."
} else {

    . (Join-Path $ScriptDir "lib\SecurityTools.ps1")
    Install-SecurityToolsWindows -Root $ScriptDir -DryRun ([bool]$DryRun) -IsAdmin ([bool]$isAdmin)

}
Sep

# ADMIN LAYER - ENFORCEMENT (machine-level - once, not per user)
# This is where controls that developers cannot revert reside:
# Claude Code managed-settings.json and Codex requirements.toml. Antigravity has no
# admin layer: all of its configuration lives in the user profile.
#
# In corporate Windows, developers are not local admins, so this layer is what
# truly enforces policy -- unlike Linux/Mac, where users typically have root and
# deploy.sh treats this as friction.
Write-AgentShieldEvent -Event "phase" -Phase "managed_enforcement"
Section "Admin Layer - Enforcement"

$machineOk = 0
$applyScript = Join-Path $ScriptDir "lib\ApplyTargets.ps1"

# Splatting a HASHTABLE, not an array: array splatting in a .ps1 script passes
# positionally and -Scope ValidateSet fails.
# --- Validate selector BEFORE touching anything ---------------------
# Invalid selectors must abort as usage error (exit 2) and not in the middle of
# the run: without this, a typo in -Only caused the script to iterate tools and hooks
# only to exit with 1 at the end, giving the false impression that something was applied.
# The engine already validates and returns 2; here we just don't swallow that code.
& $applyScript -Root $ScriptDir -Scope machine -Only $Only -DryRun *>$null
if ($LASTEXITCODE -eq 2) {
    # Re-run without silencing so operator can see valid vocabulary.
    & $applyScript -Root $ScriptDir -Scope machine -Only $Only -DryRun | Out-Null
    exit 2
}

$machineArgs = @{ Root = $ScriptDir; Scope = "machine"; Only = $Only }
if ($DryRun) { $machineArgs["DryRun"] = $true }

# $machineOk has THREE states, not two: 1 applied, 0 failed, -1 not requested.
# Without the third, '-Only codex-user' would exit with 1 for not applying
# enforcement that the operator never asked for -- and mass rollout would see
# that as a broken host.
# rc 3 = step not requested. Detect by exit code, not output parsing:
# Write-Host cannot be captured by 2>&1 in PowerShell, so capture was empty
# and tests never matched.
Invoke-AgentShieldEngine -Arguments $machineArgs
$machineRc = $LASTEXITCODE

if ($machineRc -eq 3) {
    $machineOk = -1
    Info "no enforcement target in -Only '$($Only -join ',')' -- step not applicable"
} elseif ($machineRc -eq 0) {
    $machineOk = 1
    Info "Enforcement active: --dangerously-skip-permissions blocked,"
    Info "  permission rules, hooks, and MCP only from managed source."
} else {
    $machineOk = 0
    Err "admin layer failed (rc=$machineRc) -- only user layer"
    Err "  will remain active, and it is editable by the developer."
}

# User Discovery
Write-AgentShieldEvent -Event "phase" -Phase "user_discovery"
Section "User Discovery"

$allProfiles = Get-AllUserProfiles
$targetUsers = @()

foreach ($p in $allProfiles) {
    $detection = Find-UserInstall -ProfilePath $p.Profile -Username $p.Username -Principal $p.Principal

    # All real (non-system) profiles are targeted, even without AI currently installed:
    # if installed in the future, the security gate will already be in place.
    $targetUsers += $detection
    $status = if ($detection.Score -gt 0) { "TARGET" } else { "TARGET (no AI yet)" }
    $color  = if ($detection.Score -gt 0) { "Green" } else { "Yellow" }

    Write-Host "  [$status] $($p.Username)" -ForegroundColor $color
    foreach ($e in $detection.Evidence) { Write-Host "         + $e" -ForegroundColor DarkGray }
    if ($detection.Evidence.Count -eq 0) {
        Write-Host "         (no AI/tools detected -- config prepared for future install)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Info "Target users: $($targetUsers.Count)"

if ($targetUsers.Count -eq 0) {
    Warn "No user profiles found."
    exit 0
}

# Confirmation
if (-not $DryRun -and -not $Force) {
    if (-not $isInteractive) {
        # Without this guard, Read-Host in non-interactive context returns empty,
        # falls into 'Cancelled' and deploy becomes a silent no-op with exit 0 --
        # the worst possible outcome in an RTR rollout.
        Err "Non-interactive execution detected and -Force was not specified."
        Err "Nothing was modified. Re-run with -Force:"
        Err "  powershell -ExecutionPolicy Bypass -File deploy.ps1 -Force"
        if ($script:TranscriptOn) { Stop-Transcript | Out-Null }
        exit 2
    }
    Write-Host ""
    Write-Host "Install for the following users?" -ForegroundColor Yellow
    foreach ($u in $targetUsers) { Write-Host "  - $($u.Username) ($($u.Profile))" }
    Write-Host ""
    $confirm = Read-Host "Confirm? (y/N)"
    if ($confirm -notmatch "^[yYsS]$") {
        Info "Cancelled by user."
        if ($script:TranscriptOn) { Stop-Transcript | Out-Null }
        exit 0
    }
}

# Per-User Deploy
Write-AgentShieldEvent -Event "phase" -Phase "user_deployment"
Section "Deploy"

$results = @{ Success = @(); Failed = @() }
$codexSelectors = @("all", "codex", "codex-user", "codex-managed", "managed")
$codexRequested = @($Only | Where-Object { $codexSelectors -contains $_ }).Count -gt 0
if ($machineOk -eq 1 -and $codexRequested) {
    . (Join-Path $ScriptDir "lib\CodexSandboxProfile.ps1")
}

foreach ($user in $targetUsers) {
    Write-Host "`n  -> Processing: $($user.Username)" -ForegroundColor Cyan

    $userClaudeDir   = Join-Path $user.Profile ".claude"
    $userClaudeMCP   = Join-Path $user.Profile ".claude.json"
    $userSettings    = Join-Path $userClaudeDir "settings.json"
    $userDesktopDir  = Join-Path $user.Profile "AppData\Roaming\Claude"
    $userHooksDir    = Join-Path $user.Profile ".git-hooks"
    $userTemplateDir = Join-Path $user.Profile ".git-template"
    $userGitConfig   = Join-Path $user.Profile ".gitconfig"

    try {
        # --- AI tool configuration (driven by targets\*.json) ---
        # Previously: CLAUDE.md, settings.json, claude.json, and Claude Desktop written
        # by hand here, each with its own merge logic. Now the engine reads targets\
        # and applies user-scoped targets -- Claude Code, Claude Desktop,
        # Codex CLI, Antigravity, and VS Code.
        #
        # -TargetHome is intentionally explicit: under SYSTEM the process $env:USERPROFILE
        # points to systemprofile, and configs would go to a profile no dev uses.
        $userApplyArgs = @{ Root = $ScriptDir; Scope = "user"
                            TargetHome = $user.Profile; Only = $Only }
        if ($DryRun) { $userApplyArgs["DryRun"] = $true }

        Invoke-AgentShieldEngine -Arguments $userApplyArgs
        # rc 3 = valid selection with no target in this scope. With -Only managed
        # there is no user target, and throw aborted deployment for every user.
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) {
            throw "configuration application failed for $($user.Username) (rc=$LASTEXITCODE)"
        }

        if ($machineOk -eq 1 -and $codexRequested) {
            # Identity comes from profile SID. Under SCCM/Falcon, the process is
            # SYSTEM, but sandbox requires the developer owning the profile.
            Initialize-CodexElevatedSandbox -TargetUser $user.Principal -TargetHome $user.Profile -DryRun ([bool]$DryRun) | Out-Null
        }

        # --- VS Code extensions ---
        # Extensions are per-user and 'code' must run in the user's context.
        # Scheduled tasks only work when the user is logged in -- hence best effort.
        $vsCandidates = @(
            (Join-Path $user.Profile "AppData\Local\Programs\Microsoft VS Code\bin\code.cmd"),
            "C:\Program Files\Microsoft VS Code\bin\code.cmd",
            "C:\Program Files (x86)\Microsoft VS Code\bin\code.cmd"
        )
        $vsCodeBin = $null
        foreach ($c in $vsCandidates) { if (Test-Path $c) { $vsCodeBin = $c; break } }
        if (-not $vsCodeBin) {
            # PS 5.1 lacks '?.' operator -- resolve in two steps.
            $codeCmd = Get-Command "code" -ErrorAction SilentlyContinue
            if ($codeCmd) { $vsCodeBin = $codeCmd.Source }
        }

        if ($SkipVSCode) {
            Info "    vscode: skipped (-SkipVSCode) -- use GPO logon script (see vscode-gpo/README.md)"
        } elseif ($vsCodeBin) {
            # Snyk removed: requires account. Trivy runs locally, no login required.
            $extensions = @("semgrep.semgrep","sonarsource.sonarlint-vscode","usernamehw.errorlens","AquaSecurityOfficial.trivy-vulnerability-scanner")
            if ($DryRun) {
                foreach ($ext in $extensions) { Info "      [dry-run] code --install-extension $ext --force" }
            } else {
                Info "    vscode: installing extensions..."
                try {
                    # Single task with all 4 extensions instead of 4 tasks with
                    # 6s wait each: 24s -> 12s per user. Important under Falcon RTR
                    # where runscript has a 600s ceiling.
                    $inner = ($extensions | ForEach-Object { "& '$vsCodeBin' --install-extension $_ --force" }) -join "; "
                    $enc   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
                    $a  = New-ScheduledTaskAction -Execute "powershell.exe" `
                            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc"
                    $t  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
                    $pr = New-ScheduledTaskPrincipal -UserId $user.Username -LogonType Interactive
                    $tn = "VSCodeSecExt_$($user.Username)"
                    Register-ScheduledTask -TaskName $tn -Action $a -Trigger $t -Principal $pr -Force -ErrorAction Stop | Out-Null
                    Start-Sleep -Seconds 12
                    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
                    Info "      OK extensions triggered ($($extensions.Count))"
                    Warn "      (only applies if $($user.Username) is currently logged in -- otherwise use GPO)"
                } catch {
                    Warn "      vscode: failed -- $($_.Exception.Message)"
                    Warn "      Use GPO logon script (see vscode-gpo/README.md)"
                }
            }
        } else {
            Warn "    vscode: binary 'code' not found -- skipping extensions"
        }

        # VS Code settings are applied by the engine
        # (targets\vscode.json), alongside the rest of the configuration above.

        # --- Git hooks (audit mode) ---
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $userHooksDir | Out-Null }
        $userPreCommit = Join-Path $userHooksDir "pre-commit"

        # Source can be CRLF (checkout on Windows); installed hook must always
        # be LF, otherwise sh.exe breaks on shebang.
        $srcHookLf    = $SrcHook -replace "`r`n", "`n"
        $srcHookBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($srcHookLf)
        # Byte-by-byte comparison against what WOULD be written (LF, no BOM):
        # an existing hook in CRLF or with BOM breaks under sh.exe, so it must
        # count as divergent and be rewritten, not reported as up to date.
        $hookIsCurrent = $false
        if (Test-Path $userPreCommit) {
            $hookIsCurrent = ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($userPreCommit)) -eq `
                              [Convert]::ToBase64String($srcHookBytes))
        }

        if ($hookIsCurrent) {
            Info "    pre-commit hook: already up to date -- nothing to do"
        } elseif ($DryRun) {
            Info "    [dry-run] pre-commit hook: would install/update $userPreCommit"
        } elseif (Test-Path $userPreCommit) {
            # Previous version skipped ANY existing hook, leaving old hooks
            # (with 'exit 1', which BLOCKS commits) in place.
            $bak = "$userPreCommit.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $userPreCommit $bak -Force
            Write-ShellScript -Path $userPreCommit -Content $srcHookLf
            Warn "    pre-commit hook: outdated -- replaced (backup in $bak)"
        } else {
            Write-ShellScript -Path $userPreCommit -Content $srcHookLf
            Info "    pre-commit hook: created (audit mode)"
        }

        if (-not $DryRun) {
            New-Item -ItemType Directory -Force -Path (Join-Path $userTemplateDir "hooks") | Out-Null
            if (Test-Path $userPreCommit) {
                Copy-Item $userPreCommit (Join-Path $userTemplateDir "hooks\pre-commit") -Force
            }
            # git config --file writes directly to target user's .gitconfig.
            # Replaces previous scheduled task approach that only worked
            # if user was logged in during deploy.
            git config --file "$userGitConfig" core.hooksPath "$userHooksDir"
            git config --file "$userGitConfig" init.templateDir "$userTemplateDir"
            Info "    git config: written to $userGitConfig"

            Write-AgentShieldEvent -Event "phase" -Phase "ownership_repair"
            # Grant file ownership back to profile owner.
            Grant-UserOwnership -Path $userClaudeDir   -Username $user.Username
            Grant-UserOwnership -Path $userClaudeMCP   -Username $user.Username
            Grant-UserOwnership -Path $userHooksDir    -Username $user.Username
            Grant-UserOwnership -Path $userTemplateDir -Username $user.Username
            Grant-UserOwnership -Path $userGitConfig   -Username $user.Username
            Grant-UserOwnership -Path $userDesktopDir  -Username $user.Username
            # New AI folders: written as Admin, must be transferred back to
            # profile owner, otherwise dev cannot edit or (in some cases) read own config.
            Grant-UserOwnership -Path (Join-Path $user.Profile ".codex")  -Username $user.Username
            # ~/.gemini remains here: Antigravity stores settings, MCP, and GEMINI.md here
            # -- the directory tree belongs to it.
            Grant-UserOwnership -Path (Join-Path $user.Profile ".gemini") -Username $user.Username
            Grant-UserOwnership -Path (Join-Path $user.Profile "AppData\Roaming\Code\User") -Username $user.Username
        } else {
            Info "    [dry-run] git config --file $userGitConfig core.hooksPath $userHooksDir"
            Info "    [dry-run] icacls on created files -> $($user.Username)"
        }

        $results.Success += $user.Username

    } catch {
        Err "    Failed to process $($user.Username): $($_.Exception.Message)"
        $results.Failed += $user.Username
    }
}
# In dry-run nothing was written: claiming "applied" would be false.
$verboOk = "Installed successfully"
$verboAdmin = "applied"
if ($DryRun) {
    $verboOk = "WOULD BE installed (dry-run)"
    $verboAdmin = "WOULD BE applied (dry-run)"
}

# Final Report
Section "Report"

Write-Host ""
if ($results.Success.Count -gt 0) {
    Write-Host "  OK  ${verboOk}:" -ForegroundColor Green
    foreach ($u in $results.Success) { Write-Host "       - $u" }
}
if ($results.Failed.Count -gt 0) {
    Write-Host "  ERR Failed:" -ForegroundColor Red
    foreach ($u in $results.Failed) { Write-Host "       - $u" }
}
Write-Host ""
if ($DryRun) { Warn "Dry-run completed -- no changes were made." }
Write-Host ""

Write-Host ""
Write-Host "  VS Code -- MANUAL ACTION REQUIRED (once per machine)" -ForegroundColor Yellow
Write-Host "    Security extensions DO NOT declare support for Restricted Mode:"
Write-Host "    until the project folder is trusted, they remain disabled."
Write-Host "    There is no GPO policy for this -- trust ONCE the parent folder"
Write-Host "    of your repositories and all subfolders inherit, including future ones:"
Write-Host ""
Write-Host "      Ctrl+Shift+P -> 'Workspace Trust' -> Trusted Folders & Workspaces"
Write-Host "      -> Add Folder -> select parent folder (e.g. G:\repos)"
Write-Host ""

if ($machineOk -eq 1) {
    Write-Host "  OK  Admin layer (enforcement) $verboAdmin" -ForegroundColor Green
    Write-Host "      Claude managed-settings + Codex requirements"
} elseif ($machineOk -eq -1) {
    Write-Host "  --  Admin layer not selected (-Only $($Only -join ','))" -ForegroundColor DarkGray
} else {
    Write-Host "  ERR Admin layer NOT applied -- only user layer is active," -ForegroundColor Red
    Write-Host "      and it is editable by the developer."
}
if (-not ($Only -contains "all")) {
    Write-Host ""
    Warn "PARTIAL INSTALLATION -- selection: $($Only -join ',')"
    Warn "  Unselected items were NEITHER applied NOR removed."
}
Write-Host ""

# machine= indicates whether the enforcement layer succeeded: an "ok=N fail=0" alone
# would misrepresent this in a mass rollout.
Write-Host "AGENTSHIELD: DONE ok=$($results.Success.Count) fail=$($results.Failed.Count) machine=$machineOk only=$($Only -join ',') dry=$([int]$DryRun.IsPresent)" -ForegroundColor Cyan
Write-Host "Full log: $LogPath" -ForegroundColor DarkGray
if ($script:TranscriptOn) { Stop-Transcript | Out-Null }

# A managed layer that was requested but not applied is a deployment failure.
if ($results.Failed.Count -gt 0 -or $machineOk -eq 0) {
    $resultStatus = "failed"
} else {
    $resultStatus = "success"
}
Write-Host "AGENTSHIELD: RESULT status=$resultStatus runner=deploy scope=fleet managed=$machineOk dry_run=$([int]$DryRun.IsPresent) selected=$($Only -join ',')" -ForegroundColor Cyan
if ($OutputMode -ne "Console") {
    [ordered]@{
        schema_version = 1
        event = "result"
        run_id = $script:RunId
        started_at_utc = $script:StartedAtUtc.ToString("o")
        duration_ms = [int][math]::Round(([DateTime]::UtcNow - $script:StartedAtUtc).TotalMilliseconds)
        status = $resultStatus
        exit_code = $(if ($resultStatus -eq "failed") { 1 } else { 0 })
        runner = "deploy"
        scope = "fleet"
        selected = @($Only)
        managed = [bool]($machineOk -eq 1)
        dry_run = [bool]$DryRun.IsPresent
        targets = [ordered]@{ ok = $results.Success.Count; failed = $results.Failed.Count }
        log_path = $LogPath
    } | ConvertTo-Json -Compress -Depth 4
}
if ($resultStatus -eq "failed") { exit 1 }
exit 0

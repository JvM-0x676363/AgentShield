# Security AI Config Installer - Windows (PowerShell 5.1+)
# Covers: Claude Code CLI + Claude Desktop + Global Git hooks (audit mode)
# Usage: powershell -ExecutionPolicy Bypass -File .\install.ps1 [-DryRun]
#        ... -Only codex            (Codex only)
#        ... -Only claude,antigravity    (multiple)
#        ... -Only managed          (enforcement layers only)
#        ... -ListTargets           (list available targets and selectors)
#
# -Only filters ONLY AI CONFIGURATION. Scanner tools, VS Code extensions,
# and Git hooks have dedicated flags (-SkipTools, -SkipVSCode) as orthogonal layers.

param(
    [switch]   $DryRun,
    [string[]] $Only = @("all"),
    [switch]   $ListTargets,
    [switch]   $SkipTools,
    [switch]   $SkipVSCode,
    [ValidateSet("Console", "Json", "Quiet")]
    [string]   $OutputMode = "Console"
)

$ScriptLocation = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Source checkout: scripts\windows\. Distribution ZIP: package root. Both layouts
# resolve to the directory containing policy/, targets/, and lib/.
$ScriptDir = if (Test-Path (Join-Path $ScriptLocation "policy")) {
    $ScriptLocation
} else {
    Split-Path -Parent (Split-Path -Parent $ScriptLocation)
}
$script:RunId    = [guid]::NewGuid().ToString()
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
            runner = "install"
            scope = "user"
            dry_run = [bool]$DryRun.IsPresent
            selected = @($Only)
        } | ConvertTo-Json -Compress -Depth 3
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

if ($ListTargets) {
    & (Join-Path $ScriptDir "lib\ApplyTargets.ps1") -Root $ScriptDir -ListTargets
    exit $LASTEXITCODE
}

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

$AdminApplied = $false

$ClaudeDesktopDir = Join-Path $env:APPDATA "Claude"
$HooksDir         = Join-Path $env:USERPROFILE ".git-hooks"
$TemplateDir      = Join-Path $env:USERPROFILE ".git-template"
$Marker           = "<!-- security-team-block -->"

function Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Sep()      { Write-Host "  -----------------------------------------------" -ForegroundColor DarkGray }

function Write-TextFileUtf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}
function Write-ShellScript {
    param([string]$Path, [string]$Content)
    $lf = $Content -replace "`r`n", "`n"
    Write-TextFileUtf8NoBom -Path $Path -Content $lf
}

if ($DryRun) { Info "Dry-run mode -- no modifications will be made`n" }
Write-Host "`n=== AgentShield | workstation install ===" -ForegroundColor Cyan
Info "Execution mode: $(if ($DryRun) { 'dry-run' } else { 'apply' }); runner=install; scope=user; selected=$($Only -join ',')"
Info "Run ID: $script:RunId"
Write-AgentShieldEvent -Event "start"

# --- Source file validation ---
$required = @("lib\ApplyTargets.ps1", "lib\SecurityTools.ps1", "lib\CodexSandboxProfile.ps1", "policy\core-guidelines.md", "policy\policy.json", "policy\tools.json", "hooks\pre-commit")
foreach ($f in $required) {
    $fullPath = Join-Path $ScriptDir $f
    if (-not (Test-Path $fullPath)) {
        Err "File not found: $fullPath"
        Err "Run the script from the root of the AgentShield repository."
        exit 1
    }
}
if (-not (Test-Path (Join-Path $ScriptDir "targets"))) {
    Err "Directory not found: $(Join-Path $ScriptDir 'targets')"
    exit 1
}

$applyScript = Join-Path $ScriptDir "lib\ApplyTargets.ps1"
$failedTargets = 0

# Validate selectors prior to making any changes
& $applyScript -Root $ScriptDir -Scope machine -Only $Only -DryRun *>$null
if ($LASTEXITCODE -eq 2) {
    & $applyScript -Root $ScriptDir -Scope machine -Only $Only -DryRun | Out-Null
    exit 2
}

# Administrative layer (enforcement; requires Administrator)
# Admin layer (enforcement; requires Administrator privileges)
Write-Host "`n[Administrative Layer - Enforcement]" -ForegroundColor Cyan

$machineSelected = $true
& $applyScript -Root $ScriptDir -Scope machine -Only $Only -DryRun *>$null
if ($LASTEXITCODE -eq 3) { $machineSelected = $false }

$userSelected = $true
& $applyScript -Root $ScriptDir -Scope user -Only $Only -TargetHome $env:USERPROFILE -DryRun *>$null
if ($LASTEXITCODE -eq 3) { $userSelected = $false }

if (-not $machineSelected) {
    Info "no enforcement target matches -Only '$($Only -join ',')' -- phase not applicable"
} elseif (-not $IsAdmin -and -not $DryRun) {
    Warn "running without Administrator privileges -- enforcement layer SKIPPED"
    Warn "  Without it, configuration resides entirely in user profile and is editable by the developer."
    Warn "  Rerun as Administrator to apply managed enforcement."
    if (-not $userSelected) {
        Err "  selection contained only machine scope: NOTHING applied in this run"
        $failedTargets = 1
    }
} else {
    if (-not $IsAdmin) {
        Warn "DRY-RUN without Administrator: the plan below represents what WOULD BE written."
        Warn "  In an actual run, this phase would be SKIPPED until run as Administrator."
    }
    $machineArgs = @{ Root = $ScriptDir; Scope = "machine"; Only = $Only }
    if ($DryRun) { $machineArgs["DryRun"] = $true }
    Invoke-AgentShieldEngine -Arguments $machineArgs
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) {
        Err "administrative layer failed (rc=$LASTEXITCODE)"
        $failedTargets = 1
    } elseif ($DryRun -or -not $IsAdmin) {
        Info "  (dry-run: nothing written -- rules above are NOT active)"
    } else {
        $AdminApplied = $true
        Info "  Enforcement active: --dangerously-skip-permissions blocked,"
        Info "  permission rules and hooks enforced from managed source only."
    }
}

Sep

# AI configuration (driven by targets\*.json)
Write-AgentShieldEvent -Event "phase" -Phase "user_configuration"
Write-Host "`n[AI Configuration - User Scope]" -ForegroundColor Cyan

$applyArgs = @{ Root = $ScriptDir; Scope = "user"; TargetHome = $env:USERPROFILE; Only = $Only }
if ($DryRun) { $applyArgs["DryRun"] = $true }

Invoke-AgentShieldEngine -Arguments $applyArgs
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) {
    Err "configuration application failed (rc=$LASTEXITCODE)"
    $failedTargets = 1
}

# requirements.toml permits only elevated Windows sandbox.
$codexSelectors = @("all", "codex", "codex-user", "codex-managed", "managed")
$codexRequested = @($Only | Where-Object { $codexSelectors -contains $_ }).Count -gt 0
if ($AdminApplied -and $codexRequested) {
    . (Join-Path $ScriptDir "lib\CodexSandboxProfile.ps1")
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Initialize-CodexElevatedSandbox -TargetUser $currentIdentity -TargetHome $env:USERPROFILE -DryRun ([bool]$DryRun) | Out-Null
}

Sep

# Security Tools Installation (machine-wide, requires Administrator)
Write-AgentShieldEvent -Event "phase" -Phase "security_tools"
Write-Host "`n[Security Tools - Installation]" -ForegroundColor Cyan

if ($SkipTools) {
    Info "-SkipTools -- tool download skipped"
} else {
    . (Join-Path $ScriptDir "lib\SecurityTools.ps1")
    Install-SecurityToolsWindows -Root $ScriptDir -DryRun ([bool]$DryRun) -IsAdmin ([bool]$IsAdmin)

Sep

}   # end of -SkipTools gate

# VS Code security extensions
Write-Host "`n[VS Code Extensions]" -ForegroundColor Cyan

$vsExts = @(
    "semgrep.semgrep",
    "sonarsource.sonarlint-vscode",
    "usernamehw.errorlens",
    "AquaSecurityOfficial.trivy-vulnerability-scanner"
)
$vsCodeBin = $null
$vsCandidates = @(
    "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
    "C:\Program Files\Microsoft VS Code\bin\code.cmd",
    "C:\Program Files (x86)\Microsoft VS Code\bin\code.cmd"
)
foreach ($c in $vsCandidates) { if (Test-Path $c) { $vsCodeBin = $c; break } }
if (-not $vsCodeBin) {
    $codeCmd = Get-Command "code" -ErrorAction SilentlyContinue
    if ($codeCmd) { $vsCodeBin = $codeCmd.Source }
}

if ($vsCodeBin) {
    foreach ($ext in $vsExts) {
        if ($DryRun) { Info "  [dry-run] code --install-extension $ext --force" }
        else {
            & $vsCodeBin --install-extension $ext --force 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Info "  OK $ext" } else { Warn "  ${ext}: failed" }
        }
    }
} else {
    Warn "  VS Code not found -- skipping extensions"
    Warn "  Install manually: code --install-extension <extension>"
}

Sep

# Git global hooks (AUDIT ONLY - non-blocking)
Write-AgentShieldEvent -Event "phase" -Phase "git_hooks"
Write-Host "`n[Git Global Hooks - Audit Mode]" -ForegroundColor Cyan

$PreCommit = Join-Path $HooksDir "pre-commit"
$srcHook   = Join-Path $ScriptDir "hooks\pre-commit"

Info "Configuring core.hooksPath -> $HooksDir"
if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $HooksDir | Out-Null
    git config --global core.hooksPath $HooksDir
} else {
    Info "  [dry-run] mkdir $HooksDir"
    Info "  [dry-run] git config --global core.hooksPath $HooksDir"
}

$srcHookLf    = [System.IO.File]::ReadAllText($srcHook) -replace "`r`n", "`n"
$srcHookBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($srcHookLf)
$hookIsCurrent = $false
if (Test-Path $PreCommit) {
    $hookIsCurrent = ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($PreCommit)) -eq `
                      [Convert]::ToBase64String($srcHookBytes))
}

if ($hookIsCurrent) {
    Info "pre-commit hook is already up to date -- nothing to do"
} elseif ($DryRun) {
    Info "  [dry-run] Would install/update $PreCommit"
} elseif (Test-Path $PreCommit) {
    $bak = "$PreCommit.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $PreCommit $bak -Force
    Write-ShellScript -Path $PreCommit -Content $srcHookLf
    Warn "pre-commit hook outdated -- replaced (backup in $bak)"
} else {
    Info "Installing pre-commit hook from hooks\pre-commit (audit only)..."
    Write-ShellScript -Path $PreCommit -Content $srcHookLf
    Info "  OK created at $PreCommit (audit mode: gitleaks + semgrep + trivy)"
}

$TemplateHooksDir = Join-Path $TemplateDir "hooks"
Info "Configuring init.templateDir -> $TemplateDir"
if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $TemplateHooksDir | Out-Null
    Get-ChildItem -Path $TemplateHooksDir -Filter "pre-commit.bak*" -File `
        -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path $PreCommit) {
        Copy-Item $PreCommit (Join-Path $TemplateHooksDir "pre-commit") -Force
    }
    git config --global init.templateDir $TemplateDir
} else {
    Info "  [dry-run] mkdir $TemplateHooksDir"
    Info "  [dry-run] git config --global init.templateDir $TemplateDir"
}

Sep

# Summary
Write-Host ""
Write-Host "Installation completed!" -ForegroundColor Green
Write-Host ""
Write-Host "  AI Configuration" -ForegroundColor Cyan
if ($Only -contains "all") {
    Write-Host "    Claude Code / Claude Desktop / Codex CLI / Antigravity"
} else {
    Write-Host "    PARTIAL INSTALLATION -- selection: $($Only -join ',')" -ForegroundColor Yellow
    Write-Host "    Unselected targets were NOT applied or modified."
}
Write-Host "    Applied destinations: review [INFO] OK lines above."
Write-Host "    Source: targets\*.json + policy\  (inventory in targets\README.md)"
Write-Host ""
if ($AdminApplied) {
    Write-Host "  Administrative Layer (enforcement)" -ForegroundColor Cyan
    Write-Host "    Applied. Developer cannot override these rules."
} elseif (-not $machineSelected) {
    Write-Host "  Administrative Layer (enforcement)" -ForegroundColor Yellow
    Write-Host "    Not part of selection '$($Only -join ',')' -- nothing to apply."
} elseif (-not $IsAdmin) {
    Write-Host "  Administrative Layer (enforcement)" -ForegroundColor Yellow
    Write-Host "    NOT applied -- ran without Administrator privileges."
    Write-Host "    All configuration resides in user profile and is editable by developer."
} else {
    Write-Host "  Administrative Layer (enforcement)" -ForegroundColor Yellow
    Write-Host "    NOT applied -- review [ERROR]/[WARN] lines above."
}
Write-Host ""
Write-Host "  Git (audit mode -- non-blocking)" -ForegroundColor Cyan
Write-Host "    $PreCommit"
Write-Host ""
Write-Host ""
Write-Host "  VS Code -- MANUAL ACTION REQUIRED (once per machine)" -ForegroundColor Yellow
Write-Host "    Security extensions do NOT declare Restricted Mode support:"
Write-Host "    extensions remain inactive until the project folder is trusted."
Write-Host "    Trust the parent folder of your repositories once to inherit across subfolders:"
Write-Host ""
Write-Host "      Ctrl+Shift+P -> 'Workspace Trust' -> Trusted Folders & Workspaces"
Write-Host "      -> Add Folder -> select parent directory (e.g., G:\repos)"
Write-Host ""
Write-Host "  Restart Claude Code, Claude Desktop, and Antigravity to apply changes." -ForegroundColor Yellow
Write-Host ""

if ($failedTargets -eq 1) {
    Write-Host ""
    Err "WARNING: one or more targets failed -- configuration is NOT complete."
    Err "  Review [ERROR] lines above before considering the machine ready."
}

Write-Host "AGENTSHIELD: INSTALL DONE failed=$failedTargets admin=$([int]$AdminApplied) only=$($Only -join ',') dry=$([int]$DryRun.IsPresent)"
if ($failedTargets -eq 1) { $resultStatus = "failed" } else { $resultStatus = "success" }
Write-Host "AGENTSHIELD: RESULT status=$resultStatus runner=install scope=user managed=$([int]$AdminApplied) dry_run=$([int]$DryRun.IsPresent) selected=$($Only -join ',')" -ForegroundColor Cyan
if ($OutputMode -ne "Console") {
    [ordered]@{
        schema_version = 1
        event = "result"
        run_id = $script:RunId
        started_at_utc = $script:StartedAtUtc.ToString("o")
        duration_ms = [int][math]::Round(([DateTime]::UtcNow - $script:StartedAtUtc).TotalMilliseconds)
        status = $resultStatus
        exit_code = $(if ($resultStatus -eq "failed") { 1 } else { 0 })
        runner = "install"
        scope = "user"
        selected = @($Only)
        managed = [bool]$AdminApplied
        dry_run = [bool]$DryRun.IsPresent
        targets = [ordered]@{ failed = $failedTargets }
    } | ConvertTo-Json -Compress -Depth 4
}
if ($failedTargets -eq 1) { exit 1 }
exit 0

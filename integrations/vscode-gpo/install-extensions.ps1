# =============================================================================
# VS Code - security extensions (GPO logon script)
# User Configuration -> Policies -> Windows Settings -> Scripts -> Logon
#
# Runs in USER context. Idempotent, silent, and does not block logon.
# Optional parameter: -Vsix <directory>  (offline installation, see vscode-gpo/README.md)
# =============================================================================

param(
    [string]$Vsix = "",                 # directory containing .vsix files (offline mode)
    [int]$TimeoutSec = 90,              # timeout ceiling per extension
    [switch]$Verbose_                   # forces console logging (manual usage)
)

$Extensions = @(
    "semgrep.semgrep",
    "sonarsource.sonarlint-vscode",
    "usernamehw.errorlens",
    "AquaSecurityOfficial.trivy-vulnerability-scanner"
)

$LogFile = Join-Path $env:TEMP "vscode-sec-ext.log"

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
    if ($Verbose_) { Write-Host $line }
}

# Logon scripts should never hang or throw unhandled exceptions to the user.
$ErrorActionPreference = "Continue"

Log "--- start (user=$env:USERNAME) ---"

# --- Locate the code binary ---
# Get-Command alone fails when PATH has not propagated in the logon session.
$candidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
    "C:\Program Files\Microsoft VS Code\bin\code.cmd",
    "C:\Program Files (x86)\Microsoft VS Code\bin\code.cmd"
)
$code = $null
foreach ($c in $candidates) { if (Test-Path $c) { $code = $c; break } }
if (-not $code) {
    $cmd = Get-Command "code" -ErrorAction SilentlyContinue
    if ($cmd) { $code = $cmd.Source }
}

if (-not $code) {
    # Not a developer / VS Code not installed: exit cleanly without noise.
    Log "VS Code not found -- nothing to do."
    exit 0
}
Log "code: $code"

# --- Check already installed extensions ---
$installed = @()
try {
    $installed = & $code --list-extensions 2>$null
    if (-not $installed) { $installed = @() }
} catch {
    Log "WARN: --list-extensions failed ($($_.Exception.Message)); proceeding without cache."
}
Log "installed: $($installed.Count)"

# --- Resolve matching .vsix in offline mode ---
function Resolve-VsixPath {
    param([string]$Dir, [string]$ExtId)
    if (-not (Test-Path $Dir)) { return $null }
    # download-vsix.ps1 names files as <publisher>.<extension>-<version>.vsix
    $match = Get-ChildItem -Path $Dir -Filter "$ExtId-*.vsix" -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -First 1
    if ($match) { return $match.FullName }
    return $null
}

$done = 0; $skipped = 0; $failed = 0

foreach ($ext in $Extensions) {
    # Case-insensitive comparison: marketplace uses publisher casing (Semgrep.semgrep),
    # while --list-extensions output casing can vary.
    if ($installed -contains $ext -or ($installed | Where-Object { $_ -ieq $ext })) {
        Log "already installed: $ext"
        $skipped++
        continue
    }

    $target = $ext
    if ($Vsix) {
        $path = Resolve-VsixPath -Dir $Vsix -ExtId $ext
        if (-not $path) {
            Log "ERROR: .vsix not found for $ext in $Vsix"
            $failed++
            continue
        }
        $target = $path
    }

    try {
        Log "installing: $ext"
        # Start-Process + timeout: a frozen extension install cannot hold up logon.
        $p = Start-Process -FilePath $code `
                -ArgumentList @("--install-extension", $target, "--force") `
                -NoNewWindow -PassThru -ErrorAction Stop
        if ($p.WaitForExit($TimeoutSec * 1000)) {
            if ($p.ExitCode -eq 0) { Log "  OK $ext"; $done++ }
            else { Log "  FAILED $ext (exit $($p.ExitCode))"; $failed++ }
        } else {
            try { $p.Kill() } catch { }
            Log "  TIMEOUT $ext (${TimeoutSec}s) -- aborted"
            $failed++
        }
    } catch {
        Log "  ERROR $ext -- $($_.Exception.Message)"
        $failed++
    }
}

Log "--- end: installed=$done already_present=$skipped failed=$failed ---"

# Always exit 0: an extension failure must not mark the logon script as failed.
exit 0

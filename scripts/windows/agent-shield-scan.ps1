[CmdletBinding()]
param(
    [string]$Path = ".",
    [string]$RulesDir,
    [string]$GitleaksConfig,
    [switch]$Staged,
    [string]$StatePath,
    [ValidateSet("Console", "Json", "Quiet")]
    [string]$OutputMode = "Console"
)

$ErrorActionPreference = "Stop"
$RunId = [guid]::NewGuid().ToString()

function Exit-Blocked {
    param([string]$Detail)
    if ($OutputMode -eq "Console") {
        [Console]::Error.WriteLine("[AGENTSHIELD SCAN] result: environment_blocked ($Detail)")
    } else {
        [ordered]@{
            schema_version = 1
            event = "result"
            run_id = $RunId
            timestamp_utc = [DateTime]::UtcNow.ToString("o")
            status = "environment_blocked"
            exit_code = 2
            runner = "agent-shield-scan"
            detail = $Detail
            scanners = @()
        } | ConvertTo-Json -Compress
    }
    exit 2
}
$ScriptLocation = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = if (Test-Path (Join-Path $ScriptLocation "policy")) {
    $ScriptLocation
} else {
    Split-Path -Parent (Split-Path -Parent $ScriptLocation)
}
$Runner = Join-Path $Root "scripts\scan\agent_shield_scan.py"
if (-not (Test-Path $Runner)) {
    Exit-Blocked "runner_not_found"
}
if (-not $RulesDir) { $RulesDir = Join-Path $Root "rules\semgrep" }

$Python = Get-Command py -ErrorAction SilentlyContinue
$Prefix = @()
if ($Python) {
    $Prefix = @($Python.Source, "-3")
} else {
    $Python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $Python) { $Python = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $Python) {
        Exit-Blocked "python3_not_found"
    }
    $Prefix = @($Python.Source)
}

$Arguments = @($Runner, "--path", $Path, "--rules-dir", $RulesDir, "--output-mode", $OutputMode)
if ($GitleaksConfig) { $Arguments += @("--gitleaks-config", $GitleaksConfig) }
if ($Staged) { $Arguments += "--staged" }
if ($StatePath) { $Arguments += @("--state-path", $StatePath) }
try {
    if ($Prefix.Count -eq 2) {
        & $Prefix[0] $Prefix[1] @Arguments
    } else {
        & $Prefix[0] @Arguments
    }
} catch {
    Exit-Blocked "python3_not_started"
}
if ($null -eq $LASTEXITCODE) { exit 2 }
exit $LASTEXITCODE

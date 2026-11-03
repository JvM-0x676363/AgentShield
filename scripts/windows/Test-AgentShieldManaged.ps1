[CmdletBinding()]
param(
    [ValidateSet("Console", "Json", "Quiet")]
    [string]$OutputMode = "Quiet"
)

$ErrorActionPreference = "Stop"
$ScriptLocation = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = if (Test-Path (Join-Path $ScriptLocation "policy")) {
    $ScriptLocation
} else {
    Split-Path -Parent (Split-Path -Parent $ScriptLocation)
}
$runId = [guid]::NewGuid().ToString()
$started = [DateTime]::UtcNow
$checks = @()

function Get-Sha256 {
    param([string]$Path)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return -join ($hash.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
    } finally { $hash.Dispose() }
}

function Add-Check {
    param([string]$Name, [bool]$Passed)
    $script:checks += [ordered]@{ name = $Name; passed = $Passed }
}

function Test-Identical {
    param([string]$Name, [string]$Expected, [string]$Actual)
    Add-Check -Name $Name -Passed ((Test-Path -LiteralPath $Actual) -and
        ((Get-Sha256 $Expected) -eq (Get-Sha256 $Actual)))
}

$programData = [Environment]::GetFolderPath("CommonApplicationData")
$programFiles = [Environment]::GetFolderPath("ProgramFiles")
Test-Identical "codex_requirements" (Join-Path $Root "policy\codex-requirements.toml") (Join-Path $programData "OpenAI\Codex\requirements.toml")
Test-Identical "claude_statusline" (Join-Path $Root "statusline\security-status.py") (Join-Path $programFiles "ClaudeCode\statusline-security.py")

$managedSettings = Join-Path $programFiles "ClaudeCode\managed-settings.json"
$settingsOk = $false
if (Test-Path -LiteralPath $managedSettings) {
    try {
        $settings = Get-Content -LiteralPath $managedSettings -Raw | ConvertFrom-Json
        $settingsOk = $settings.permissions.disableBypassPermissionsMode -eq "disable" -and
            $settings.permissions.allowManagedPermissionRulesOnly -eq $true -and
            $settings.allowManagedHooksOnly -eq $true
    } catch { $settingsOk = $false }
}
Add-Check "claude_managed_controls" $settingsOk

$managedClaude = Join-Path $programFiles "ClaudeCode\CLAUDE.md"
$markerOk = $false
if (Test-Path -LiteralPath $managedClaude) {
    $marker = "<!-- security-team-block -->"
    $markerOk = ([regex]::Matches((Get-Content -LiteralPath $managedClaude -Raw),
        [regex]::Escape($marker))).Count -eq 2
}
Add-Check "claude_managed_guidance" $markerOk
Add-Check "claude_managed_mcp_absent" (-not (Test-Path -LiteralPath (Join-Path $programFiles "ClaudeCode\managed-mcp.json")))

$failed = @($checks | Where-Object { -not $_.passed })
$exitCode = if ($failed.Count) { 1 } else { 0 }
$result = [ordered]@{
    schema_version = 1; event = "result"; run_id = $runId
    started_at_utc = $started.ToString("o")
    duration_ms = [int][math]::Round(([DateTime]::UtcNow - $started).TotalMilliseconds)
    status = if ($exitCode) { "failed" } else { "success" }
    exit_code = $exitCode; runner = "detect-managed"; scope = "machine"
    compliant = ($exitCode -eq 0); checks = $checks
}
if ($OutputMode -eq "Console") { $checks | Format-Table -AutoSize }
$result | ConvertTo-Json -Compress -Depth 4
exit $exitCode

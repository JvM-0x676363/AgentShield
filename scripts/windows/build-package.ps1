# =============================================================================
# Packages AgentShield deployment payloads and optional integration assets.
# Primary target: Falcon RTR, where `put` sends one file at a time.
#
# Usage: .\scripts\windows\build-package.ps1 [-OutDir <dir>] [-IncludeShell] [-IncludeGpo] [-IncludeFalconTemplates]
#
# Validates everything BEFORE packaging: packages will not contain unparsable
# scripts, invalid JSON, or hooks with CRLF/BOM.
# =============================================================================

param(
    [string]$OutDir      = ".",
    [string]$Name        = "agent-shield",
    [switch]$IncludeGpo,      # adds VS Code GPO assets to the separate integrations archive
    [switch]$IncludeShell,    # includes Unix runners, verifier, and managed detector
    [switch]$IncludeFalconTemplates, # adds Falcon workflow templates to the separate integrations archive
    [switch]$Force            # overwrites existing zip
)

$ErrorActionPreference = "Stop"
$ScriptLocation = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$RepoRoot = if (Test-Path (Join-Path $ScriptLocation "policy")) {
    $ScriptLocation
} else {
    Split-Path -Parent (Split-Path -Parent $ScriptLocation)
}

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "[ERROR] $m" -ForegroundColor Red }
function Sec($m)  { Write-Host "`n== $m ==" -ForegroundColor Cyan }

# Files required by deploy.ps1. The package stages entry points at the ZIP root.
$Files = @(
    "lib/ApplyTargets.ps1",
    "lib/SecurityTools.ps1",
    "lib/CodexSandboxProfile.ps1",
    "policy/core-guidelines.md",
    "policy/policy.json",
    "policy/tools.json",
    "hooks/pre-commit",
    "scripts/windows/install.ps1",
    "scripts/windows/deploy.ps1",
    "scripts/windows/Test-AgentShieldManaged.ps1"
)
if ($IncludeShell) {
    $Files += "scripts/unix/install.sh"
    $Files += "scripts/unix/deploy.sh"
    $Files += "scripts/unix/Test-AgentShieldManaged.sh"
    $Files += "lib/apply_targets.py"
    $Files += "lib/security-tools.sh"
    $Files += "tests/verify-install.py"
}

$IntegrationFiles = @()
if ($IncludeFalconTemplates) {
    $IntegrationFiles += "integrations/falcon-rtr/README.md"
    $IntegrationFiles += "integrations/falcon-rtr/agentshield-deploy.workflow.template.yaml"
    $IntegrationFiles += "integrations/falcon-rtr/agentshield-deploy-linux.workflow.template.yaml"
    $IntegrationFiles += "integrations/falcon-rtr/agentshield-deploy-macos.workflow.template.yaml"
    $IntegrationFiles += "integrations/falcon-rtr/agentshield-deploy-windows.mocks.template.json"
    $IntegrationFiles += "integrations/falcon-rtr/agentshield-deploy-linux.mocks.template.json"
    $IntegrationFiles += "integrations/falcon-rtr/agentshield-deploy-macos.mocks.template.json"
    $IntegrationFiles += "integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Windows.ps1"
    $IntegrationFiles += "integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Unix.sh"
    $IntegrationFiles += "integrations/falcon-rtr/rtr-scripts/AgentShield-Cleanup-Windows.ps1"
    $IntegrationFiles += "integrations/falcon-rtr/rtr-scripts/AgentShield-Cleanup-Unix.sh"
    $IntegrationFiles += "integrations/falcon-rtr/rtr-scripts/AgentShield-Apply.input-schema.json"
    $IntegrationFiles += "integrations/falcon-rtr/rtr-scripts/AgentShield-Apply.output-schema.json"
    $IntegrationFiles += "integrations/falcon-rtr/rtr-scripts/AgentShield-Cleanup.output-schema.json"
}

# Entire targets/ and policy/ directories are discovered dynamically.
$discovered = @()
foreach ($dir in @("targets", "policy")) {
    $full = Join-Path $RepoRoot $dir
    if (-not (Test-Path $full)) { continue }
    foreach ($f in (Get-ChildItem -Path $full -File -Recurse | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart("\", "/").Replace("\", "/")
        $discovered += $rel
    }
}
foreach ($rel in $discovered) {
    if ($Files -notcontains $rel) { $Files += $rel }
}

$manifestFiles = @()
$targetsDir = Join-Path $RepoRoot "targets"
if (Test-Path $targetsDir) {
    foreach ($mf in (Get-ChildItem -Path $targetsDir -Filter *.json -File)) {
        $doManifesto = Get-Content $mf.FullName -Raw | ConvertFrom-Json  # doManifesto: read manifest, not fixed list
        foreach ($arq in $doManifesto.files) {
            if ($arq.PSObject.Properties.Name -contains "payload_file") {
                $manifestFiles += $arq.payload_file
            }
            if ($arq.PSObject.Properties.Name -contains "payload_file_by_os") {
                foreach ($payloadByOs in $arq.payload_file_by_os.PSObject.Properties) {
                    $manifestFiles += $payloadByOs.Value
                }
            }
        }
        foreach ($comp in $doManifesto.files) {
            if ($comp.PSObject.Properties.Name -contains "compose") {
                foreach ($c in $comp.compose) { $manifestFiles += $c }
            }
        }
    }
}
foreach ($rel in ($manifestFiles | Sort-Object -Unique)) {
    if (-not (Test-Path (Join-Path $RepoRoot $rel))) {
        throw "manifest references non-existent payload_file: $rel"
    }
    if ($Files -notcontains $rel) { $Files += $rel }
}
if ($IncludeGpo) {
    $IntegrationFiles += "integrations/vscode-gpo/install-extensions.ps1"
    $IntegrationFiles += "integrations/vscode-gpo/download-vsix.ps1"
    $IntegrationFiles += "integrations/vscode-gpo/vscode-policy.json"
    $IntegrationFiles += "integrations/vscode-gpo/README.md"
}

function Get-PackageRelativePath {
    param([string]$RelativePath)
    switch ($RelativePath) {
        "scripts/windows/install.ps1" { return "install.ps1" }
        "scripts/windows/deploy.ps1" { return "deploy.ps1" }
        "scripts/windows/Test-AgentShieldManaged.ps1" { return "Test-AgentShieldManaged.ps1" }
        "scripts/unix/install.sh" { return "install.sh" }
        "scripts/unix/deploy.sh" { return "deploy.sh" }
        "scripts/unix/Test-AgentShieldManaged.sh" { return "Test-AgentShieldManaged.sh" }
        default {
            if ($RelativePath.StartsWith("integrations/falcon-rtr/")) {
                return $RelativePath.Substring("integrations/".Length)
            }
            if ($RelativePath.StartsWith("integrations/vscode-gpo/")) {
                return $RelativePath.Substring("integrations/".Length)
            }
            return $RelativePath
        }
    }
}

function Get-Sha256Hex {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
    } finally {
        $sha.Dispose()
    }
}

$errors = @()

# =============================================================================
# VALIDATION
# =============================================================================
Sec "Validation"

foreach ($rel in ($Files + $IntegrationFiles)) {
    $full = Join-Path $RepoRoot ($rel -replace '/', '\')
    if (-not (Test-Path $full)) {
        $errors += "missing: $rel"
        Err "  MISSING   $rel"
        continue
    }

    $bytes = [System.IO.File]::ReadAllBytes($full)
    $note  = ""

    # --- BOM check ---
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($hasBom -and ($rel -match '\.(json|sh|toml)$' -or $rel -match 'pre-commit$')) {
        $errors += "BOM in $rel"
        Err "  BOM       $rel"
        continue
    }

    # --- CRLF check for shell scripts ---
    if ($rel -match '\.(sh|toml)$' -or $rel -match 'pre-commit$') {
        $cr = ($bytes | Where-Object { $_ -eq 13 }).Count
        if ($cr -gt 0) {
            $errors += "CRLF in $rel ($cr CR)"
            Err "  CRLF      $rel ($cr CR found)"
            continue
        }
        $note = "LF ok"
    }

    # --- JSON parsing check ---
    if ($rel -match '\.json$') {
        try {
            [void]([System.IO.File]::ReadAllText($full) | ConvertFrom-Json)
            $note = "JSON ok"
        } catch {
            $errors += "invalid JSON in ${rel}: $($_.Exception.Message)"
            Err "  BAD JSON  $rel"
            continue
        }
    }

    # --- PowerShell compilation check ---
    if ($rel -match '\.ps1$') {
        $perr = $null; $ptok = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$ptok, [ref]$perr)
        if ($perr -and $perr.Count -gt 0) {
            $errors += "$rel does not compile: L$($perr[0].Extent.StartLineNumber) $($perr[0].Message)"
            Err "  DOES NOT COMPILE $rel -- L$($perr[0].Extent.StartLineNumber)"
            continue
        }
        $note = "parse ok"
    }

    $kb = [math]::Round($bytes.Length / 1KB, 1)
    Info ("  OK        {0,-38} {1,8} KB  {2}" -f $rel, $kb, $note)
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Err "Package NOT generated -- $($errors.Count) issue(s):"
    foreach ($e in $errors) { Err "  - $e" }
    exit 1
}

# =============================================================================
# STAGING
# =============================================================================
Sec "Packaging"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

function New-AgentShieldArchive {
    param([string[]]$PackageFiles, [string]$ArchiveName)

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "$ArchiveName-$stamp"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        foreach ($rel in $PackageFiles) {
            $src = Join-Path $RepoRoot ($rel -replace '/', '\')
            $packageRel = Get-PackageRelativePath $rel
            $dst = Join-Path $staging ($packageRel -replace '/', '\')
            $dstDir = Split-Path $dst -Parent
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
            Copy-Item $src $dst -Force
        }

        $manifest = @("# AgentShield -- package $stamp", "")
        foreach ($rel in $PackageFiles) {
            $packageRel = Get-PackageRelativePath $rel
            $h = Get-Sha256Hex (Join-Path $staging ($packageRel -replace '/', '\'))
            $manifest += ("{0}  {1}" -f $h, $packageRel)
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $staging "MANIFEST.txt"), ($manifest -join "`n"), $enc)

        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        $zip = Join-Path (Resolve-Path $OutDir).Path "$ArchiveName.zip"
        if ((Test-Path $zip) -and -not $Force) {
            throw "Already exists: $zip  (use -Force to overwrite)"
        }
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip -CompressionLevel Optimal

        return [pscustomobject]@{
            Path = $zip
            Hash = Get-Sha256Hex $zip
            SizeKb = [math]::Round((Get-Item $zip).Length / 1KB, 1)
        }
    } finally {
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$deploymentArchive = New-AgentShieldArchive -PackageFiles $Files -ArchiveName $Name
Info "  deployment: $($deploymentArchive.Path)"
Info "  $($deploymentArchive.SizeKb) KB | SHA256 $($deploymentArchive.Hash)"

if ($IntegrationFiles.Count -gt 0) {
    $integrationArchive = New-AgentShieldArchive -PackageFiles $IntegrationFiles -ArchiveName "$Name-integrations"
    Info "  integrations: $($integrationArchive.Path)"
    Info "  $($integrationArchive.SizeKb) KB | SHA256 $($integrationArchive.Hash)"
    Info "  Keep integration assets out of endpoint staging; import or distribute them separately."
}

# =============================================================================
# INSTRUCTIONS
# =============================================================================
Sec "Falcon RTR v3 workflow"

$howto = @'
  1) Upload __NAME__.zip to the Falcon file library.

  2) Extract __NAME__-integrations.zip on an operator workstation.
     Upload the custom scripts, apply schemas, configure the package SHA-256,
     replace workflow placeholders, then import the selected workflow.

  3) Configure mocks in Falcon Test view. Workflow imports do not include them.

  4) Run one approved pilot endpoint before widening the rollout.

  The workflow, custom scripts, and mock guidance are in falcon-rtr\README.md.

  VS Code extensions require user context. Deploy through GPO or equivalent MDM.
'@
Write-Host $howto.Replace("__NAME__", $Name) -ForegroundColor Gray

Write-Host ""

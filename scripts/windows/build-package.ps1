# =============================================================================
# Packages AgentShield into a single .zip for remote execution.
# Primary target: Falcon RTR, where `put` sends one file at a time.
#
# Usage: .\scripts\windows\build-package.ps1 [-OutDir <dir>] [-IncludeGpo] [-IncludeShell]
#
# Validates everything BEFORE packaging: packages will not contain unparsable
# scripts, invalid JSON, or hooks with CRLF/BOM.
# =============================================================================

param(
    [string]$OutDir      = ".",
    [string]$Name        = "agent-shield",
    [switch]$IncludeGpo,      # includes integrations/vscode-gpo/ (typically distributed via SYSVOL, not RTR)
    [switch]$IncludeShell,    # includes deploy.sh for Linux/macOS hosts
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
    $Files += "lib/apply_targets.py"
    $Files += "lib/security-tools.sh"
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
    $Files += "integrations/vscode-gpo/install-extensions.ps1"
    $Files += "integrations/vscode-gpo/download-vsix.ps1"
    $Files += "integrations/vscode-gpo/vscode-policy.json"
    $Files += "integrations/vscode-gpo/README.md"
}

function Get-PackageRelativePath {
    param([string]$RelativePath)
    switch ($RelativePath) {
        "scripts/windows/install.ps1" { return "install.ps1" }
        "scripts/windows/deploy.ps1" { return "deploy.ps1" }
        "scripts/windows/Test-AgentShieldManaged.ps1" { return "Test-AgentShieldManaged.ps1" }
        "scripts/unix/install.sh" { return "install.sh" }
        "scripts/unix/deploy.sh" { return "deploy.sh" }
        default {
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

foreach ($rel in $Files) {
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

$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$staging = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-$stamp"
New-Item -ItemType Directory -Force -Path $staging | Out-Null

try {
    foreach ($rel in $Files) {
        $src = Join-Path $RepoRoot ($rel -replace '/', '\')
        $packageRel = Get-PackageRelativePath $rel
        $dst = Join-Path $staging ($packageRel -replace '/', '\')
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item $src $dst -Force
    }

    $manifest = @("# AgentShield -- package $stamp", "")
    foreach ($rel in $Files) {
        $packageRel = Get-PackageRelativePath $rel
        $h = Get-Sha256Hex (Join-Path $staging ($packageRel -replace '/', '\'))
        $manifest += ("{0}  {1}" -f $h, $packageRel)
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $staging "MANIFEST.txt"), ($manifest -join "`n"), $enc)

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $zip = Join-Path (Resolve-Path $OutDir).Path "$Name.zip"
    if ((Test-Path $zip) -and -not $Force) {
        Err "Already exists: $zip  (use -Force to overwrite)"
        exit 1
    }
    if (Test-Path $zip) { Remove-Item $zip -Force }

    Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip -CompressionLevel Optimal

    $zipHash = Get-Sha256Hex $zip
    $zipKb   = [math]::Round((Get-Item $zip).Length / 1KB, 1)

    Info "  $zip"
    Info "  $zipKb KB | SHA256 $zipHash"

} finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# INSTRUCTIONS
# =============================================================================
Sec "How to use with Falcon RTR"

$howto = @'
  1) Upload zip to file library (Response > Response scripts and files)

  2) In host RTR session:

     cd C:\Windows\Temp
     put __NAME__.zip
     runscript -Raw=```Expand-Archive -Path 'C:\Windows\Temp\__NAME__.zip' -DestinationPath 'C:\Windows\Temp\__NAME__' -Force```

  3) Fast pass -- configuration only, seconds:

     runscript -Timeout=300 -Raw=```& 'C:\Windows\Temp\__NAME__\deploy.ps1' -Force -SkipTools -SkipVSCode -OutputMode Json```

  4) Tools pass -- minutes, network dependent:

     runscript -Timeout=600 -Raw=```& 'C:\Windows\Temp\__NAME__\deploy.ps1' -Force -SkipVSCode -OutputMode Json```

  5) Verify managed enforcement:

     runscript -Timeout=60 -Raw=```& 'C:\Windows\Temp\__NAME__\Test-AgentShieldManaged.ps1'```

  6) Retrieve log:

     get C:\Windows\Temp\agent-shield-deploy.log

  VS Code extensions are NOT deployed via RTR (require logged-in user).
  Deploy via GPO -- see vscode-gpo\README.md

  Exit codes: 0 ok | 1 failed | 2 non-interactive without -Force (nothing modified)
'@
Write-Host $howto.Replace("__NAME__", $Name) -ForegroundColor Gray

Write-Host ""

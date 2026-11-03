# =============================================================================
# Download VS Code security extension .vsix files for offline distribution.
# Run ONCE from a machine with internet access.
# Usage: .\download-vsix.ps1 -OutDir \\fileserver\sw$\vscode-ext
# =============================================================================

param(
    [Parameter(Mandatory = $true)][string]$OutDir
)

$Extensions = @(
    "semgrep.semgrep",
    "sonarsource.sonarlint-vscode",
    "usernamehw.errorlens",
    "AquaSecurityOfficial.trivy-vulnerability-scanner"
)

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "[ERROR] $m" -ForegroundColor Red }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Resolves current version from marketplace (flags=914 retrieves versions).
function Get-LatestVersion {
    param([string]$Publisher, [string]$Name)
    $body = @{
        filters = @(@{ criteria = @(@{ filterType = 7; value = "$Publisher.$Name" }) })
        flags   = 914
    } | ConvertTo-Json -Depth 10

    $resp = Invoke-RestMethod -Method Post `
        -Uri "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" `
        -ContentType "application/json" `
        -Headers @{ "Accept" = "application/json;api-version=7.2-preview.1" } `
        -Body $body
    $ext = $resp.results[0].extensions
    if (-not $ext) { return $null }
    return $ext[0].versions[0].version
}

$ok = 0; $fail = 0

foreach ($id in $Extensions) {
    $publisher, $name = $id.Split(".", 2)
    try {
        $version = Get-LatestVersion -Publisher $publisher -Name $name
        if (-not $version) { Err "  $id -- not found in marketplace"; $fail++; continue }

        $out = Join-Path $OutDir "$id-$version.vsix"
        if (Test-Path $out) { Info "  $id $version -- already downloaded"; $ok++; continue }

        $url = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/$publisher/vsextensions/$name/$version/vspackage"
        Info "  downloading $id $version ..."

        # Invoke-WebRequest decompresses gzip that this endpoint always returns.
        # With curl --compressed would be required, otherwise the .vsix is corrupted.
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing

        # Validate before publishing to share: .vsix is a zip file.
        try {
            $z = [System.IO.Compression.ZipFile]::OpenRead($out)
            $hasManifest = $z.Entries.Name -contains "extension.vsixmanifest"
            $z.Dispose()
            if (-not $hasManifest) { throw "manifest missing" }
            Info "    OK $([math]::Round((Get-Item $out).Length / 1KB)) KB"
            $ok++
        } catch {
            Remove-Item $out -Force -ErrorAction SilentlyContinue
            Err "    invalid file, removed -- $($_.Exception.Message)"
            $fail++
        }
    } catch {
        Err "  $id -- $($_.Exception.Message)"
        $fail++
    }
}

Write-Host ""
Info "Completed: $ok ok, $fail failed -> $OutDir"
if ($fail -gt 0) { exit 1 }

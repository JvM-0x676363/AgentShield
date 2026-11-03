# Shared, pinned scanner installation for install.ps1 and deploy.ps1.
# The caller supplies Info/Warn functions and invokes Install-SecurityToolsWindows.

function Get-ToolCatalog {
    param([string]$Root)
    $path = Join-Path $Root "policy\tools.json"
    if (-not (Test-Path $path)) { throw "Tool catalog not found: $path" }
    return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
}

function Install-PinnedBinaryToolWindows {
    param(
        [object]$Catalog,
        [string]$ToolName,
        [string]$Destination,
        [switch]$DryRun
    )
    $tool = $Catalog.tools.$ToolName
    if (-not $tool) { throw "Tool missing from catalog: $ToolName" }
    if (Get-Command $tool.binary -ErrorAction SilentlyContinue) {
        Info "  OK $($tool.binary) already installed"
        return
    }
    $asset = $tool.assets.'windows-x64'
    if (-not $asset) { throw "Windows x64 asset missing for $ToolName" }
    Info "  Installing $ToolName pinned at $($tool.version)..."
    if ($DryRun) {
        Info "  [dry-run] Would download $($asset.file), verify SHA-256 and install to $Destination"
        return
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $tmp = Join-Path $env:TEMP ("{0}-{1}.zip" -f $ToolName, [guid]::NewGuid().ToString("N"))
    $url = if ($ToolName -eq "gitleaks") {
        "https://github.com/gitleaks/gitleaks/releases/download/v$($tool.version)/$($asset.file)"
    } elseif ($ToolName -eq "trivy") {
        "https://github.com/aquasecurity/trivy/releases/download/v$($tool.version)/$($asset.file)"
    } else { throw "Repository not approved for $ToolName" }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
        $actual = ([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($tmp)) |
            ForEach-Object { $_.ToString("x2") }) -join ""
        if ($actual -ne $asset.sha256) {
            throw "Invalid SHA-256 for $ToolName; file discarded"
        }
        Expand-Archive -Path $tmp -DestinationPath $Destination -Force
        Info "  OK $ToolName installed to $Destination (SHA-256 verified)"
    } catch {
        Warn "  Failed to install ${ToolName}: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Install-SecurityToolsWindows {
    param(
        [string]$Root,
        [bool]$DryRun,
        [bool]$IsAdmin
    )
    if (-not $IsAdmin) {
        Warn "  Machine-wide tool installation requires Administrator -- skipping this step."
        Warn "  Install the pinned versions from policy/tools.json manually."
        return
    }
    $catalog = Get-ToolCatalog -Root $Root
    $toolsDir = Join-Path $env:ProgramData "SecurityTools"
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if (($machinePath -split ';') -notcontains $toolsDir) {
        if (-not $DryRun) {
            [Environment]::SetEnvironmentVariable("Path", "$machinePath;$toolsDir", "Machine")
            $env:Path = "$env:Path;$toolsDir"
        }
        Info "  Machine PATH updated with $toolsDir"
    }
    Install-PinnedBinaryToolWindows -Catalog $catalog -ToolName "gitleaks" -Destination $toolsDir -DryRun:$DryRun
    Install-PinnedBinaryToolWindows -Catalog $catalog -ToolName "trivy" -Destination $toolsDir -DryRun:$DryRun

    $semgrepVersion = $catalog.tools.semgrep.version
    if (Get-Command semgrep -ErrorAction SilentlyContinue) {
        Info "  OK semgrep already installed"
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        if ($DryRun) { Info "  [dry-run] python -m pip install semgrep==$semgrepVersion" }
        else {
            python -m pip install --disable-pip-version-check "semgrep==$semgrepVersion" | Out-Null
            if ($LASTEXITCODE -eq 0) { Info "  OK semgrep installed" } else { Warn "  Failed to install semgrep" }
        }
    } else {
        Warn "  Python not found -- semgrep was not installed"
    }
    Warn "  trivy-mcp is not installed automatically: requires a versioned and verified package"
}

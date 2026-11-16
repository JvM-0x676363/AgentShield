$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $repo ('tmp\rollback-install-windows-' + [Guid]::NewGuid().ToString('N'))
$testHome = Join-Path $testRoot 'profile'
$receiptDir = Join-Path $testRoot 'receipts'
$install = Join-Path $repo 'scripts\windows\install.ps1'
$rollback = Join-Path $repo 'scripts\windows\rollback.ps1'

function New-PrivateReceiptDirectory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($current)
    $acl.SetAccessRuleProtection($true, $false)
    $flags = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
             [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sidValue in @($current.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl, $flags,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$environmentNames = @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'HOME',
    'HOMEDRIVE', 'HOMEPATH', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM')
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this test without Administrator privileges.'
    }

    New-Item -ItemType Directory -Path $testHome -Force | Out-Null
    New-PrivateReceiptDirectory -Path $receiptDir
    $env:USERPROFILE = $testHome
    $env:APPDATA = Join-Path $testHome 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $testHome 'AppData\Local'
    $env:HOME = $testHome
    $env:HOMEDRIVE = [IO.Path]::GetPathRoot($testHome).TrimEnd('\')
    $env:HOMEPATH = $testHome.Substring($env:HOMEDRIVE.Length)
    $env:GIT_CONFIG_GLOBAL = Join-Path $testHome '.gitconfig'
    $env:GIT_CONFIG_NOSYSTEM = '1'

    $ErrorActionPreference = 'Continue'
    try {
        $installOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $install `
            -Only claude-code -SkipTools -SkipVSCode -ExperimentalReceiptDir $receiptDir 2>&1)
        $installExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($installExit -ne 0 -or -not @($installOutput | Select-String 'INSTALL DONE failed=0').Count -or
        -not @($installOutput | Select-String 'VS Code extensions skipped').Count) {
        $installOutput | Select-Object -Last 8 | ForEach-Object { Write-Warning $_ }
        throw 'isolated_install_failed'
    }
    foreach ($relative in @('.claude\vendor-claude-code.md', '.git-hooks\pre-commit',
            '.git-hooks\agent-shield-scan.py', '.git-template\hooks\pre-commit')) {
        if (-not (Test-Path -LiteralPath (Join-Path $testHome $relative) -PathType Leaf)) {
            throw 'expected_install_file_missing'
        }
    }
    $preview = & powershell -NoProfile -File $rollback -ReceiptDir $receiptDir | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $preview.status -ne 'ready' -or
        $preview.receipts -lt 1 -or $preview.blocked -ne 0) {
        throw 'isolated_rollback_preview_not_ready'
    }
    $result = & powershell -NoProfile -File $rollback -ReceiptDir $receiptDir -Apply | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.status -ne 'restored' -or
        $result.applied -ne $preview.receipts) {
        throw 'isolated_rollback_apply_failed'
    }
    foreach ($relative in @('.claude\vendor-claude-code.md', '.git-hooks\pre-commit',
            '.git-hooks\agent-shield-scan.py', '.git-template\hooks\pre-commit')) {
        if (Test-Path -LiteralPath (Join-Path $testHome $relative)) {
            throw 'created_file_survived_rollback'
        }
    }
    foreach ($key in @('core.hooksPath', 'init.templateDir')) {
        $value = @(& git config --file (Join-Path $testHome '.gitconfig') --get-all $key 2>$null)
        if ($LASTEXITCODE -eq 0 -or $value.Count -ne 0) {
            throw 'git_config_survived_rollback'
        }
    }
    $existingFile = Join-Path $testHome '.claude\vendor-claude-code.md'
    [IO.File]::WriteAllText($existingFile, 'pre-existing user file')
    $manualReceiptDir = Join-Path $testRoot 'manual-receipts'
    New-PrivateReceiptDirectory -Path $manualReceiptDir
    $ErrorActionPreference = 'Continue'
    try {
        $manualInstallOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $install `
            -Only claude-code -SkipTools -SkipVSCode -ExperimentalReceiptDir $manualReceiptDir 2>&1)
        $manualInstallExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($manualInstallExit -ne 0 -or
        -not @($manualInstallOutput | Select-String 'INSTALL DONE failed=0').Count) {
        throw 'existing_file_install_failed'
    }
    $installedContent = [IO.File]::ReadAllText($existingFile)
    $manualPreview = & powershell -NoProfile -File $rollback -ReceiptDir $manualReceiptDir | ConvertFrom-Json
    if ($LASTEXITCODE -ne 2 -or $manualPreview.status -ne 'blocked' -or
        @($manualPreview.items | Where-Object { $_.status -eq 'preview_only' }).Count -lt 1) {
        throw 'existing_file_review_not_required'
    }
    $manualResult = & powershell -NoProfile -File $rollback -ReceiptDir $manualReceiptDir -Apply | ConvertFrom-Json
    if ($LASTEXITCODE -ne 2 -or $manualResult.status -ne 'blocked' -or
        $manualResult.applied -ne 0 -or [IO.File]::ReadAllText($existingFile) -cne $installedContent -or
        -not (Test-Path -LiteralPath (Join-Path $testHome '.git-hooks\pre-commit'))) {
        throw 'existing_file_batch_was_applied'
    }
    Write-Host "RESULT: Windows isolated install and rollback passed (receipts=$($preview.receipts))"
    Write-Host 'RESULT: Windows existing-file review blocked batch rollback'
    Write-Host "Evidence directory: $testRoot"
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
}

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
    foreach ($relative in @('.claude\security-review-playbook.md', '.claude\brand-identity.md',
            '.claude\settings.json', '.git-hooks\pre-commit',
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
    foreach ($relative in @('.claude\security-review-playbook.md', '.claude\brand-identity.md',
            '.claude\settings.json', '.git-hooks\pre-commit',
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
    $settings = Join-Path $env:APPDATA 'Code\User\settings.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $settings) -Force | Out-Null
    $settingsPrior = [Text.Encoding]::UTF8.GetBytes("{`n  `"user.setting`": true`n}`n")
    [IO.File]::WriteAllBytes($settings, $settingsPrior)
    $settingsPriorTicks = (Get-Item -LiteralPath $settings).LastWriteTimeUtc.Ticks
    $jsonReceiptDir = Join-Path $testRoot 'json-receipts'
    New-PrivateReceiptDirectory -Path $jsonReceiptDir
    $ErrorActionPreference = 'Continue'
    try {
        $jsonInstallOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $install `
            -Only vscode -SkipTools -SkipVSCode -ExperimentalReceiptDir $jsonReceiptDir 2>&1)
        $jsonInstallExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($jsonInstallExit -ne 0 -or
        -not @($jsonInstallOutput | Select-String 'INSTALL DONE failed=0').Count) {
        $jsonInstallOutput | Select-Object -Last 8 | ForEach-Object { Write-Warning $_ }
        throw 'isolated_json_install_failed'
    }
    $jsonPreview = & powershell -NoProfile -File $rollback -ReceiptDir $jsonReceiptDir | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $jsonPreview.status -ne 'ready' -or
        -not @($jsonPreview.items | Where-Object {
            $_.kind -eq 'json_added_keys' -and $_.status -eq 'ready'
        }).Count) {
        throw 'isolated_json_preview_not_ready'
    }
    $jsonResult = & powershell -NoProfile -File $rollback -ReceiptDir $jsonReceiptDir -Apply | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $jsonResult.status -ne 'restored' -or
        $jsonResult.applied -ne $jsonPreview.receipts -or
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($settings)) -cne
            [Text.Encoding]::UTF8.GetString($settingsPrior) -or
        (Get-Item -LiteralPath $settings).LastWriteTimeUtc.Ticks -ne $settingsPriorTicks -or
        (Test-Path -LiteralPath ($settings + '.bak'))) {
        throw 'isolated_json_rollback_failed'
    }
    $claudeHome = Join-Path $testRoot 'claude-profile'
    $claudeSettings = Join-Path $claudeHome '.claude\settings.json'
    $claudeMcp = Join-Path $claudeHome '.claude.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $claudeSettings) -Force | Out-Null
    $claudeSettingsPrior = ([Text.UTF8Encoding]::new($false)).GetBytes((@(
        '{', '  "permissions": {', '    "deny": [', '      "Read(user-owned)"',
        '    ],', '    "ask": [],', '    "allow": []', '  },',
        '  "userSetting": true', '}'
    ) -join "`n") + "`n")
    $claudeMcpPrior = ([Text.UTF8Encoding]::new($false)).GetBytes((@(
        '{', '  "mcpServers": {', '    "user-server": {',
        '      "command": "user-tool"', '    }', '  },',
        '  "userSetting": true', '}'
    ) -join "`n") + "`n")
    [IO.File]::WriteAllBytes($claudeSettings, $claudeSettingsPrior)
    [IO.File]::WriteAllBytes($claudeMcp, $claudeMcpPrior)
    $claudeSettingsTicks = (Get-Item -LiteralPath $claudeSettings).LastWriteTimeUtc.Ticks
    $claudeMcpTicks = (Get-Item -LiteralPath $claudeMcp).LastWriteTimeUtc.Ticks
    $claudeReceiptDir = Join-Path $testRoot 'claude-receipts'
    New-PrivateReceiptDirectory -Path $claudeReceiptDir
    $env:USERPROFILE = $claudeHome
    $env:APPDATA = Join-Path $claudeHome 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $claudeHome 'AppData\Local'
    $env:HOME = $claudeHome
    $env:HOMEDRIVE = [IO.Path]::GetPathRoot($claudeHome).TrimEnd('\')
    $env:HOMEPATH = $claudeHome.Substring($env:HOMEDRIVE.Length)
    $env:GIT_CONFIG_GLOBAL = Join-Path $claudeHome '.gitconfig'
    $ErrorActionPreference = 'Continue'
    try {
        $claudeInstallOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $install `
            -Only claude-code -SkipTools -SkipVSCode -ExperimentalReceiptDir $claudeReceiptDir 2>&1)
        $claudeInstallExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($claudeInstallExit -ne 0 -or
        -not @($claudeInstallOutput | Select-String 'INSTALL DONE failed=0').Count) {
        $claudeInstallOutput | Select-Object -Last 8 | ForEach-Object { Write-Warning $_ }
        throw 'existing_claude_install_failed'
    }
    $claudePreview = & powershell -NoProfile -File $rollback -ReceiptDir $claudeReceiptDir | ConvertFrom-Json
    $claudeKinds = @($claudePreview.items | Where-Object { $_.status -eq 'ready' } | ForEach-Object kind)
    if ($LASTEXITCODE -ne 0 -or $claudePreview.status -ne 'ready' -or
        $claudeKinds -notcontains 'json_list_append') {
        throw 'existing_claude_preview_not_ready'
    }
    $claudeResult = & powershell -NoProfile -File $rollback -ReceiptDir $claudeReceiptDir -Apply | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $claudeResult.status -ne 'restored' -or
        $claudeResult.applied -ne $claudePreview.receipts -or
        -not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            [IO.File]::ReadAllBytes($claudeSettings), $claudeSettingsPrior) -or
        -not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            [IO.File]::ReadAllBytes($claudeMcp), $claudeMcpPrior) -or
        (Get-Item -LiteralPath $claudeSettings).LastWriteTimeUtc.Ticks -ne $claudeSettingsTicks -or
        (Get-Item -LiteralPath $claudeMcp).LastWriteTimeUtc.Ticks -ne $claudeMcpTicks) {
        throw 'existing_claude_rollback_failed'
    }
    $env:USERPROFILE = $testHome
    $env:APPDATA = Join-Path $testHome 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $testHome 'AppData\Local'
    $env:HOME = $testHome
    $env:HOMEDRIVE = [IO.Path]::GetPathRoot($testHome).TrimEnd('\')
    $env:HOMEPATH = $testHome.Substring($env:HOMEDRIVE.Length)
    $env:GIT_CONFIG_GLOBAL = Join-Path $testHome '.gitconfig'
    $existingFile = Join-Path $testHome '.claude\security-review-playbook.md'
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
    Write-Host 'RESULT: Windows canonical VS Code JSON merge and rollback passed'
    Write-Host 'RESULT: Windows existing Claude permissions rollback passed; MCP remained unchanged'
    Write-Host 'RESULT: Windows existing-file review blocked batch rollback'
    Write-Host "Evidence directory: $testRoot"
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
}

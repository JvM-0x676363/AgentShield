$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $repo ('tmp\rollback-managed-windows-' + [Guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $testRoot 'package'
$systemRoot = Join-Path $testRoot 'system'
$fakeProgramFiles = Join-Path $systemRoot 'ProgramFiles'
$fakeProgramData = Join-Path $systemRoot 'ProgramData'
$receiptDir = Join-Path $testRoot 'receipts'
$engine = Join-Path $repo 'lib\ApplyTargets.ps1'
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

New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'targets'),
    $fakeProgramFiles, $fakeProgramData -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'policy') -Destination $fixtureRoot -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'statusline') -Destination $fixtureRoot -Recurse
New-PrivateReceiptDirectory -Path $receiptDir

$expectedFiles = @()
foreach ($targetId in @('claude-managed', 'codex-managed')) {
    $source = Join-Path $repo "targets\$targetId.json"
    $manifest = [IO.File]::ReadAllText($source) | ConvertFrom-Json
    if ($manifest.scope -ne 'machine' -or $manifest.requires_admin -ne $true) {
        throw 'unexpected_machine_manifest'
    }
    $manifest.requires_admin = $false
    foreach ($spec in $manifest.files) {
        $windowsDestination = [string]$spec.dest.windows
        if (-not $windowsDestination) { continue }
        if ($windowsDestination.StartsWith('${PROGRAMFILES}/', [StringComparison]::Ordinal)) {
            $relative = $windowsDestination.Substring('${PROGRAMFILES}/'.Length)
            $base = $fakeProgramFiles
        } elseif ($windowsDestination.StartsWith('${PROGRAMDATA}/', [StringComparison]::Ordinal)) {
            $relative = $windowsDestination.Substring('${PROGRAMDATA}/'.Length)
            $base = $fakeProgramData
        } else {
            throw 'unexpected_machine_destination'
        }
        $destination = [IO.Path]::GetFullPath((Join-Path $base ($relative.Replace('/', '\'))))
        $bounded = [IO.Path]::GetFullPath($systemRoot).TrimEnd('\') + '\'
        if (-not $destination.StartsWith($bounded, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'machine_destination_escaped_test_root'
        }
        $spec.dest.windows = $destination
        if ($spec.strategy -ne 'remove') { $expectedFiles += $destination }
        if ($spec.PSObject.Properties['payload_by_os']) {
            $property = $spec.payload_by_os.PSObject.Properties['statusLine.command']
            if ($property -and $property.Value.PSObject.Properties['windows']) {
                $property.Value.windows = $property.Value.windows.Replace(
                    '${PROGRAMFILES}', $fakeProgramFiles.Replace('\', '/'))
            }
        }
    }
    $json = $manifest | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText((Join-Path $fixtureRoot "targets\$targetId.json"), $json,
        [Text.UTF8Encoding]::new($false))
}

$ErrorActionPreference = 'Continue'
try {
    $engineOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $engine `
        -Root $fixtureRoot -Scope machine -Only managed -ReceiptDir $receiptDir 2>&1)
    $engineExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = 'Stop'
}
if ($engineExit -ne 0) {
    $engineOutput | Select-Object -Last 8 | ForEach-Object { Write-Warning $_ }
    throw 'isolated_machine_apply_failed'
}
foreach ($file in $expectedFiles) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw 'expected_machine_file_missing'
    }
}

$preview = & powershell -NoProfile -File $rollback -ReceiptDir $receiptDir | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $preview.status -ne 'ready' -or
    $preview.receipts -lt 1 -or $preview.blocked -ne 0) {
    throw 'isolated_machine_rollback_preview_not_ready'
}
$result = & powershell -NoProfile -File $rollback -ReceiptDir $receiptDir -Apply | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $result.status -ne 'restored' -or
    $result.applied -ne $preview.receipts) {
    throw 'isolated_machine_rollback_apply_failed'
}
foreach ($file in $expectedFiles) {
    if (Test-Path -LiteralPath $file) {
        throw 'machine_file_survived_rollback'
    }
}

$existingFile = Join-Path $fakeProgramFiles 'ClaudeCode\statusline-security.py'
[IO.File]::WriteAllText($existingFile, 'pre-existing machine file')
$manualReceiptDir = Join-Path $testRoot 'manual-receipts'
New-PrivateReceiptDirectory -Path $manualReceiptDir
$ErrorActionPreference = 'Continue'
try {
    $manualOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $engine `
        -Root $fixtureRoot -Scope machine -Only managed -ReceiptDir $manualReceiptDir 2>&1)
    $manualExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = 'Stop'
}
if ($manualExit -ne 0) {
    $manualOutput | Select-Object -Last 8 | ForEach-Object { Write-Warning $_ }
    throw 'existing_machine_file_apply_failed'
}
$installedContent = [IO.File]::ReadAllText($existingFile)
$manualPreview = & powershell -NoProfile -File $rollback -ReceiptDir $manualReceiptDir | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or $manualPreview.status -ne 'blocked' -or
    @($manualPreview.items | Where-Object { $_.status -eq 'preview_only' }).Count -lt 1) {
    throw 'existing_machine_file_review_not_required'
}
$manualResult = & powershell -NoProfile -File $rollback -ReceiptDir $manualReceiptDir -Apply | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or $manualResult.status -ne 'blocked' -or
    $manualResult.applied -ne 0 -or [IO.File]::ReadAllText($existingFile) -cne $installedContent) {
    throw 'existing_machine_file_batch_was_applied'
}

Write-Host "RESULT: Windows isolated managed targets and rollback passed (receipts=$($preview.receipts))"
Write-Host 'RESULT: Windows existing managed file blocked batch rollback'
Write-Host "Evidence directory: $testRoot"

param([switch]$RequireAdmin)

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

if ($RequireAdmin) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run -RequireAdmin from an elevated PowerShell session.'
    }
}

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
Copy-Item -LiteralPath (Join-Path $repo 'rollback-payloads') -Destination $fixtureRoot -Recurse
New-PrivateReceiptDirectory -Path $receiptDir

$expectedFiles = @()
foreach ($targetId in @('claude-managed', 'codex-managed')) {
    $source = Join-Path $repo "targets\$targetId.json"
    $manifest = [IO.File]::ReadAllText($source) | ConvertFrom-Json
    if ($manifest.scope -ne 'machine' -or $manifest.requires_admin -ne $true) {
        throw 'unexpected_machine_manifest'
    }
    if (-not $RequireAdmin) { $manifest.requires_admin = $false }
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

Write-Host "RESULT: Windows isolated managed targets and rollback passed (receipts=$($preview.receipts); admin_gate=$([int]$RequireAdmin.IsPresent))"
Write-Host 'RESULT: Windows existing managed file blocked batch rollback'

$knownManifestPath = Join-Path $fixtureRoot 'targets\claude-managed.json'
$knownManifest = [IO.File]::ReadAllText($knownManifestPath) | ConvertFrom-Json
$knownSpec = @($knownManifest.files | Where-Object { $_.payload_file -eq 'statusline/security-status.py' })
if ($knownSpec.Count -ne 1) { throw 'known_statusline_target_missing' }
$knownManifest.files = @($knownSpec[0])
[IO.File]::WriteAllText($knownManifestPath, ($knownManifest | ConvertTo-Json -Depth 30),
    [Text.UTF8Encoding]::new($false))
$priorPath = Join-Path $fixtureRoot 'rollback-payloads\claude-statusline-53a8021.py'
$priorHash = (Get-FileHash -LiteralPath $priorPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($priorHash -cne 'f04381626792cd3278d670784be37e3dada670c3d9b15cae95f56f394aea5246') {
    throw 'prior_payload_hash_mismatch'
}

function Invoke-KnownPriorInstall {
    param([string]$Directory)
    New-PrivateReceiptDirectory -Path $Directory
    [IO.File]::WriteAllBytes($existingFile, [IO.File]::ReadAllBytes($priorPath))
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $engine `
            -Root $fixtureRoot -Scope machine -Only claude-managed -ReceiptDir $Directory 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    if ($code -ne 0) {
        $output | Select-Object -Last 8 | ForEach-Object { Write-Warning $_ }
        throw 'known_prior_install_failed'
    }
    $entries = @(Get-ChildItem -LiteralPath $Directory -Filter '*.json')
    if ($entries.Count -ne 1) { throw 'known_prior_receipt_count_invalid' }
    $receipt = [IO.File]::ReadAllText($entries[0].FullName) | ConvertFrom-Json
    if (@($receipt.operations)[0].kind -ne 'known_prior_payload') {
        throw 'known_prior_receipt_not_created'
    }
    return $entries[0].FullName
}

$knownReceiptDir = Join-Path $testRoot 'known-prior-receipts'
$knownReceipt = Invoke-KnownPriorInstall -Directory $knownReceiptDir
$knownOperation = @(([IO.File]::ReadAllText($knownReceipt) | ConvertFrom-Json).operations)[0]
$knownPreview = & powershell -NoProfile -File $rollback -ReceiptDir $knownReceiptDir | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $knownPreview.status -ne 'ready' -or $knownPreview.receipts -ne 1) {
    throw 'known_prior_preview_failed'
}
if ((Get-FileHash -LiteralPath $existingFile -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $priorHash) {
    throw 'known_prior_preview_changed_file'
}
$knownApply = & powershell -NoProfile -File $rollback -ReceiptDir $knownReceiptDir -Apply | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $knownApply.status -ne 'restored' -or $knownApply.applied -ne 1 -or
    (Get-FileHash -LiteralPath $existingFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $priorHash -or
    (Get-Item -LiteralPath $existingFile).CreationTimeUtc.Ticks -ne [long]$knownOperation.prior_creation_utc_ticks -or
    (Get-Item -LiteralPath $existingFile).LastWriteTimeUtc.Ticks -ne [long]$knownOperation.prior_write_utc_ticks) {
    throw 'known_prior_restore_failed'
}

$conflictReceiptDir = Join-Path $testRoot 'known-prior-conflict-receipts'
$null = Invoke-KnownPriorInstall -Directory $conflictReceiptDir
[IO.File]::AppendAllText($existingFile, 'modified after installation')
$conflictPreview = & powershell -NoProfile -File $rollback -ReceiptDir $conflictReceiptDir | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or $conflictPreview.status -ne 'blocked') {
    throw 'known_prior_conflict_not_blocked'
}

$invalidReceiptDir = Join-Path $testRoot 'known-prior-invalid-receipts'
$invalidReceiptPath = Invoke-KnownPriorInstall -Directory $invalidReceiptDir
$invalidReceipt = [IO.File]::ReadAllText($invalidReceiptPath) | ConvertFrom-Json
$invalidReceipt.operations[0].prior_sha256 = '0' * 64
[IO.File]::WriteAllText($invalidReceiptPath, ($invalidReceipt | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new($false))
$invalidPreview = & powershell -NoProfile -File $rollback -ReceiptDir $invalidReceiptDir | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or $invalidPreview.status -ne 'blocked') {
    throw 'known_prior_invalid_digest_not_blocked'
}

$faultLib = Join-Path $fixtureRoot 'lib'
New-Item -ItemType Directory -Path $faultLib -Force | Out-Null
$faultEngine = Join-Path $faultLib 'ApplyTargets.ps1'
$faultReceiptHelper = Join-Path $faultLib 'RollbackReceipt.ps1'
Copy-Item -LiteralPath $engine -Destination $faultEngine
Copy-Item -LiteralPath (Join-Path $repo 'lib\RollbackReceipt.ps1') -Destination $faultReceiptHelper
[IO.File]::AppendAllText($faultReceiptHelper,
    "`nfunction Write-AgentShieldKnownPriorReceipt { throw 'injected_receipt_failure' }`n")
$interruptedReceiptDir = Join-Path $testRoot 'known-prior-interrupted-receipts'
New-PrivateReceiptDirectory -Path $interruptedReceiptDir
[IO.File]::WriteAllBytes($existingFile, [IO.File]::ReadAllBytes($priorPath))
$ErrorActionPreference = 'Continue'
try {
    $faultOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $faultEngine `
        -Root $fixtureRoot -Scope machine -Only claude-managed -ReceiptDir $interruptedReceiptDir 2>&1)
    $faultExit = $LASTEXITCODE
} finally { $ErrorActionPreference = 'Stop' }
if ($faultExit -eq 0) { throw 'receipt_failure_not_injected' }
$interruptedReceipts = @(Get-ChildItem -LiteralPath $interruptedReceiptDir -Filter '*.json')
if ($interruptedReceipts.Count -ne 1) { throw 'interrupted_receipt_count_invalid' }
$interruptedOperation = @(([IO.File]::ReadAllText($interruptedReceipts[0].FullName) | ConvertFrom-Json).operations)[0]
if ($interruptedOperation.kind -ne 'manual_review' -or
    $interruptedOperation.reason -ne 'receipt_incomplete') {
    throw 'interrupted_receipt_marker_missing'
}
$interruptedFileHash = (Get-FileHash -LiteralPath $existingFile -Algorithm SHA256).Hash
if ($interruptedFileHash.ToLowerInvariant() -ceq $priorHash) {
    throw 'receipt_failure_happened_before_write'
}
$interruptedResult = & powershell -NoProfile -File $rollback -ReceiptDir $interruptedReceiptDir -Apply | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or $interruptedResult.status -ne 'blocked' -or
    $interruptedResult.applied -ne 0 -or
    (Get-FileHash -LiteralPath $existingFile -Algorithm SHA256).Hash -cne $interruptedFileHash) {
    throw 'interrupted_known_prior_rollback_not_blocked'
}

Write-Host 'RESULT: Windows known managed status line restored; changed file and invalid digest blocked'
Write-Host 'RESULT: Windows interrupted known-payload receipt blocked batch rollback'
Write-Host "Evidence directory: $testRoot"

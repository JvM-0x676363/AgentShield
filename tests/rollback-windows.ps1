$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path $repo 'tmp'
$testRoot = Join-Path $scratch ('rollback-windows-' + [Guid]::NewGuid().ToString('N'))
$receiptDir = Join-Path $testRoot 'receipts'
$rollback = Join-Path $repo 'scripts/windows/rollback.ps1'
. (Join-Path $repo 'lib/RollbackReceipt.ps1')

function New-PrivateTestDirectory {
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

try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    New-PrivateTestDirectory -Path $receiptDir
    Assert-AgentShieldEmptyReceiptDirectory -LiteralPath $receiptDir
    $content = [Text.Encoding]::UTF8.GetBytes("synthetic baseline`n")

    $broadDir = Join-Path $testRoot 'broad-receipts'
    New-Item -ItemType Directory -Path $broadDir -Force | Out-Null
    $broadAcl = [Security.AccessControl.DirectorySecurity]::new()
    $broadAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $broadAcl.SetAccessRuleProtection($true, $false)
    $ownerRule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow)
    [void]$broadAcl.AddAccessRule($ownerRule)
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $usersRule = [Security.AccessControl.FileSystemAccessRule]::new(
        $usersSid, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.AccessControlType]::Allow)
    [void]$broadAcl.AddAccessRule($usersRule)
    Set-Acl -LiteralPath $broadDir -AclObject $broadAcl
    try {
        Assert-AgentShieldPrivateReceiptPath -LiteralPath $broadDir -Directory
        throw 'broad_acl_not_rejected'
    } catch {
        if ($_.Exception.Message -ne 'receipt_acl_broad_access') { throw }
    }

    $first = Join-Path $testRoot 'changed.txt'
    [IO.File]::WriteAllBytes($first, $content)
    $firstReceipt = Write-AgentShieldCreatedReceipt -Destination $first -InstalledBytes $content -ReceiptDir $receiptDir
    try {
        Assert-AgentShieldEmptyReceiptDirectory -LiteralPath $receiptDir
        throw 'nonempty_receipt_directory_accepted'
    } catch {
        if ($_.Exception.Message -ne 'receipt_directory_not_empty') { throw }
    }
    $preview = & powershell -NoProfile -File $rollback -Receipt $firstReceipt | ConvertFrom-Json
    if ($preview.status -ne 'ready') { throw 'preview_failed' }
    [IO.File]::WriteAllText($first, "user edit`n")
    $conflict = & powershell -NoProfile -File $rollback -Receipt $firstReceipt -Apply | ConvertFrom-Json
    if ($conflict.status -ne 'blocked' -or -not (Test-Path -LiteralPath $first)) { throw 'changed_file_not_preserved' }

    $second = Join-Path $testRoot 'removable.txt'
    [IO.File]::WriteAllBytes($second, $content)
    $secondReceipt = Write-AgentShieldCreatedReceipt -Destination $second -InstalledBytes $content -ReceiptDir $receiptDir
    $removed = & powershell -NoProfile -File $rollback -Receipt $secondReceipt -Apply | ConvertFrom-Json
    if ($removed.status -ne 'removed' -or (Test-Path -LiteralPath $second)) { throw 'created_file_not_removed' }

    $notes = Join-Path $testRoot 'notes.md'
    $prior = [Text.Encoding]::UTF8.GetBytes("personal note`n")
    $installedBytes = [Text.Encoding]::UTF8.GetBytes("personal note`n`n<!-- security-team-block -->`nmanaged`n<!-- security-team-block -->`n")
    [IO.File]::WriteAllBytes($notes, $installedBytes)
    $appendReceipt = Write-AgentShieldAppendedBlockReceipt -Destination $notes -PriorBytes $prior `
        -InstalledBytes $installedBytes -ReceiptDir $receiptDir
    $appendPreview = & powershell -NoProfile -File $rollback -Receipt $appendReceipt | ConvertFrom-Json
    if ($appendPreview.status -ne 'ready') { throw 'append_preview_failed' }
    $appendRestored = & powershell -NoProfile -File $rollback -Receipt $appendReceipt -Apply | ConvertFrom-Json
    if ($appendRestored.status -ne 'restored' -or
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($notes)) -cne ("personal note`n")) {
        throw 'append_restore_failed'
    }
    [IO.File]::WriteAllBytes($notes, $installedBytes)
    $changedAppend = Write-AgentShieldAppendedBlockReceipt -Destination $notes -PriorBytes $prior `
        -InstalledBytes $installedBytes -ReceiptDir $receiptDir
    [IO.File]::AppendAllText($notes, 'user edit')
    $appendConflict = & powershell -NoProfile -File $rollback -Receipt $changedAppend -Apply | ConvertFrom-Json
    if ($appendConflict.status -ne 'blocked' -or -not ([IO.File]::ReadAllText($notes)).EndsWith('user edit')) {
        throw 'append_conflict_not_preserved'
    }

    $fixtureRoot = Join-Path $testRoot 'fixture'
    $fixtureTargets = Join-Path $fixtureRoot 'targets'
    $fixtureHome = Join-Path $testRoot 'home'
    New-Item -ItemType Directory -Path $fixtureTargets, $fixtureHome -Force | Out-Null
    $fixturePolicy = Join-Path $fixtureRoot 'policy'
    New-Item -ItemType Directory -Path $fixturePolicy -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixturePolicy 'guidance.md'), 'managed guidance')
    $guidance = Join-Path $fixtureHome 'AGENTS.md'
    $guidancePrior = [Text.Encoding]::UTF8.GetBytes("user guidance`n")
    [IO.File]::WriteAllBytes($guidance, $guidancePrior)
    $existingManaged = Join-Path $fixtureHome 'existing.json'
    [IO.File]::WriteAllText($existingManaged, '{"user":"kept"}')
    $noOp = Join-Path $fixtureHome 'no-op.json'
    $noOpBytes = [Text.Encoding]::UTF8.GetBytes('{"managed":true,"user":1}')
    [IO.File]::WriteAllBytes($noOp, $noOpBytes)
    $noOpWriteTicks = (Get-Item -LiteralPath $noOp).LastWriteTimeUtc.Ticks
    $manifest = [ordered]@{
        id = 'pilot'
        label = 'Rollback synthetic target'
        tool = 'test'
        scope = 'user'
        requires_admin = $false
        selectors = @('pilot')
        files = @([ordered]@{
            dest = @{ windows = '${HOME}/managed.json' }
            strategy = 'overwrite'
            format = 'json'
            backup = $false
            payload = @{ enabled = $true }
        }, [ordered]@{
            dest = @{ windows = '${HOME}/AGENTS.md' }
            strategy = 'md-block'
            marker = '<!-- security-team-block -->'
            compose = @('policy/guidance.md')
        }, [ordered]@{
            dest = @{ windows = '${HOME}/existing.json' }
            strategy = 'overwrite'
            format = 'json'
            backup = $false
            payload = @{ managed = $true }
        }, [ordered]@{
            dest = @{ windows = '${HOME}/no-op.json' }
            strategy = 'merge-missing-keys'
            format = 'json'
            payload = @{ managed = $true }
        })
    }
    [IO.File]::WriteAllText((Join-Path $fixtureTargets 'pilot.json'), ($manifest | ConvertTo-Json -Depth 8))
    & powershell -NoProfile -File (Join-Path $repo 'lib/ApplyTargets.ps1') `
        -Root $fixtureRoot -Scope user -TargetHome $fixtureHome -Only pilot `
        -ReceiptDir $receiptDir *> $null
    if ($LASTEXITCODE -ne 0) { throw 'engine_fixture_failed' }
    if (([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($noOp))) -cne
            ([Text.Encoding]::UTF8.GetString($noOpBytes)) -or
        (Get-Item -LiteralPath $noOp).LastWriteTimeUtc.Ticks -ne $noOpWriteTicks -or
        (Test-Path -LiteralPath ($noOp + '.bak')) -or
        @(Get-ChildItem -LiteralPath $receiptDir -Filter '*.json' | Where-Object {
            (([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).operations[0].destination) -eq $noOp
        }).Count -ne 0) {
        throw 'merge_missing_keys_noop_changed_file'
    }
    $managed = Join-Path $fixtureHome 'managed.json'
    if (-not (Test-Path -LiteralPath $managed)) { throw 'engine_did_not_write' }
    $engineReceipt = Get-ChildItem -LiteralPath $receiptDir -Filter '*.json' | Where-Object {
        (([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).operations[0].destination) -eq $managed
    } | Select-Object -First 1
    if ($null -eq $engineReceipt) { throw 'engine_did_not_record_receipt' }
    $engineRemoved = & powershell -NoProfile -File $rollback -Receipt $engineReceipt.FullName -Apply | ConvertFrom-Json
    if ($engineRemoved.status -ne 'removed' -or (Test-Path -LiteralPath $managed)) { throw 'engine_rollback_failed' }
    $guidanceReceipt = Get-ChildItem -LiteralPath $receiptDir -Filter '*.json' | Where-Object {
        (([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).operations[0].destination) -eq $guidance
    } | Select-Object -First 1
    if ($null -eq $guidanceReceipt) { throw 'engine_append_receipt_missing' }
    $guidanceRestored = & powershell -NoProfile -File $rollback -Receipt $guidanceReceipt.FullName -Apply | ConvertFrom-Json
    if ($guidanceRestored.status -ne 'restored' -or
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($guidance)) -cne "user guidance`n") {
        throw 'engine_append_rollback_failed'
    }
    $manualReceipt = Get-ChildItem -LiteralPath $receiptDir -Filter '*.json' | Where-Object {
        (([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).operations[0].destination) -eq $existingManaged
    } | Select-Object -First 1
    if ($null -eq $manualReceipt) { throw 'engine_manual_review_receipt_missing' }
    $manualRecord = [IO.File]::ReadAllText($manualReceipt.FullName) | ConvertFrom-Json
    if ($manualRecord.operations[0].kind -ne 'manual_review') { throw 'engine_manual_review_kind_wrong' }
    $orphanedGuards = @(Get-ChildItem -LiteralPath $receiptDir -Filter '*.json' | Where-Object {
        (([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).operations[0].reason) -eq 'receipt_incomplete'
    })
    if ($orphanedGuards.Count -ne 0) { throw 'successful_engine_write_left_guard' }
    $manualPreview = & powershell -NoProfile -File $rollback -Receipt $manualReceipt.FullName | ConvertFrom-Json
    if ($manualPreview.status -ne 'preview_only') { throw 'manual_review_not_preview_only' }

    $configPath = Join-Path $testRoot 'gitconfig'
    & git config --file $configPath user.name 'kept' | Out-Null
    & git config --file $configPath core.hooksPath 'C:\old-hooks' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git_fixture_failed' }
    $gitReceipt = Set-AgentShieldGitConfigWithReceipt -ConfigPath $configPath `
        -Key 'core.hooksPath' -Value 'C:\new-hooks' -ReceiptDir $receiptDir
    if (-not $gitReceipt) { throw 'git_receipt_missing' }
    $gitPreview = & powershell -NoProfile -File $rollback -Receipt $gitReceipt | ConvertFrom-Json
    if ($gitPreview.status -ne 'ready') { throw 'git_preview_failed' }
    $gitRestored = & powershell -NoProfile -File $rollback -Receipt $gitReceipt -Apply | ConvertFrom-Json
    if ($gitRestored.status -ne 'restored' -or
        (Get-AgentShieldGitConfigValue -ConfigPath $configPath -Key 'core.hooksPath') -cne 'C:\old-hooks' -or
        (& git config --file $configPath --get user.name) -cne 'kept') { throw 'git_restore_failed' }

    $changedReceipt = Set-AgentShieldGitConfigWithReceipt -ConfigPath $configPath `
        -Key 'core.hooksPath' -Value 'C:\new-hooks' -ReceiptDir $receiptDir
    & git config --file $configPath core.hooksPath 'C:\user-changed' | Out-Null
    $gitConflict = & powershell -NoProfile -File $rollback -Receipt $changedReceipt -Apply | ConvertFrom-Json
    if ($gitConflict.status -ne 'blocked' -or
        (Get-AgentShieldGitConfigValue -ConfigPath $configPath -Key 'core.hooksPath') -cne 'C:\user-changed') {
        throw 'git_conflict_not_preserved'
    }

    $newKeyReceipt = Set-AgentShieldGitConfigWithReceipt -ConfigPath $configPath `
        -Key 'init.templateDir' -Value 'C:\new-template' -ReceiptDir $receiptDir
    $newKeyRestored = & powershell -NoProfile -File $rollback -Receipt $newKeyReceipt -Apply | ConvertFrom-Json
    if ($newKeyRestored.status -ne 'restored' -or
        $null -ne (Get-AgentShieldGitConfigValue -ConfigPath $configPath -Key 'init.templateDir') -or
        (Get-AgentShieldGitConfigValue -ConfigPath $configPath -Key 'core.hooksPath') -cne 'C:\user-changed') {
        throw 'git_new_key_not_unset'
    }
    $pairReceipt = Set-AgentShieldGitConfigPairWithReceipt -ConfigPath $configPath `
        -HooksDir 'C:\pair-hooks' -TemplateDir 'C:\pair-template' -ReceiptDir $receiptDir
    if (-not $pairReceipt) { throw 'git_pair_receipt_missing' }
    $pairPreview = & powershell -NoProfile -File $rollback -Receipt $pairReceipt | ConvertFrom-Json
    if ($pairPreview.status -ne 'ready') { throw 'git_pair_preview_failed' }
    $pairRestored = & powershell -NoProfile -File $rollback -Receipt $pairReceipt -Apply | ConvertFrom-Json
    if ($pairRestored.status -ne 'restored' -or
        (Get-AgentShieldGitConfigValue -ConfigPath $configPath -Key 'core.hooksPath') -cne 'C:\user-changed' -or
        $null -ne (Get-AgentShieldGitConfigValue -ConfigPath $configPath -Key 'init.templateDir') -or
        (& git config --file $configPath --get user.name) -cne 'kept') {
        throw 'git_pair_restore_failed'
    }
    $pairConflictReceipt = Set-AgentShieldGitConfigPairWithReceipt -ConfigPath $configPath `
        -HooksDir 'C:\pair-hooks' -TemplateDir 'C:\pair-template' -ReceiptDir $receiptDir
    & git config --file $configPath core.hooksPath 'C:\user-new-hooks' | Out-Null
    $pairConflict = & powershell -NoProfile -File $rollback -Receipt $pairConflictReceipt -Apply | ConvertFrom-Json
    if ($pairConflict.status -ne 'blocked' -or
        (Get-AgentShieldGitConfigValue -ConfigPath $configPath -Key 'core.hooksPath') -cne 'C:\user-new-hooks' -or
        (Get-AgentShieldGitConfigValue -ConfigPath $configPath -Key 'init.templateDir') -cne 'C:\pair-template') {
        throw 'git_pair_conflict_not_preserved'
    }
    $previewDir = Join-Path $testRoot 'preview-receipts'
    New-PrivateTestDirectory -Path $previewDir
    $previewFile = Join-Path $testRoot 'preview-only.txt'
    [IO.File]::WriteAllBytes($previewFile, $content)
    Write-AgentShieldCreatedReceipt -Destination $previewFile -InstalledBytes $content `
        -ReceiptDir $previewDir | Out-Null
    $runPreview = & powershell -NoProfile -File $rollback -ReceiptDir $previewDir | ConvertFrom-Json
    if ($runPreview.status -ne 'ready' -or $runPreview.receipts -ne 1 -or
        $runPreview.ready -ne 1 -or -not (Test-Path -LiteralPath $previewFile)) {
        throw 'batch_preview_failed'
    }
    $batchApply = & powershell -NoProfile -File $rollback -ReceiptDir $previewDir -Apply | ConvertFrom-Json
    if ($batchApply.status -ne 'restored' -or $batchApply.applied -ne 1 -or
        (Test-Path -LiteralPath $previewFile)) {
        throw 'batch_apply_failed'
    }
    $partialRoot = Join-Path $testRoot 'partial-runner'
    $partialScripts = Join-Path $partialRoot 'scripts/windows'
    $partialLib = Join-Path $partialRoot 'lib'
    New-Item -ItemType Directory -Path $partialScripts, $partialLib -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'lib/RollbackReceipt.ps1') -Destination $partialLib
    $partialRunner = Join-Path $partialScripts 'rollback.ps1'
    $source = [IO.File]::ReadAllText($rollback)
    $declaration = 'param([string]$Receipt, [string]$ReceiptDir, [switch]$Apply)'
    if (-not $source.StartsWith($declaration, [StringComparison]::Ordinal)) {
        throw 'partial_fixture_source_changed'
    }
    $injected = @'
if ($Receipt -and $Apply) {
    @{ schema_version = 1; runner = 'rollback'; status = 'partial';
       reason = 'known_prior_partial_restore'; exit_code = 2 } | ConvertTo-Json -Compress
    exit 2
}
'@
    [IO.File]::WriteAllText($partialRunner,
        $source.Insert($declaration.Length, "`r`n" + $injected + "`r`n"))
    $partialDir = Join-Path $testRoot 'partial-receipts'
    New-PrivateTestDirectory -Path $partialDir
    $partialFile = Join-Path $testRoot 'partial.txt'
    [IO.File]::WriteAllBytes($partialFile, $content)
    Write-AgentShieldCreatedReceipt -Destination $partialFile -InstalledBytes $content `
        -ReceiptDir $partialDir | Out-Null
    $partialRun = & powershell -NoProfile -File $partialRunner -ReceiptDir $partialDir -Apply |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 2 -or $partialRun.status -ne 'partial' -or
        $partialRun.applied -ne 0 -or $partialRun.blocked -ne 1 -or
        $partialRun.items[0].status -ne 'partial') {
        throw 'batch_child_partial_not_reported'
    }
    $conflictDir = Join-Path $testRoot 'conflict-receipts'
    New-PrivateTestDirectory -Path $conflictDir
    $conflictFile = Join-Path $testRoot 'conflict.txt'
    [IO.File]::WriteAllBytes($conflictFile, $content)
    Write-AgentShieldCreatedReceipt -Destination $conflictFile -InstalledBytes $content `
        -ReceiptDir $conflictDir | Out-Null
    [IO.File]::WriteAllText($conflictFile, 'user edit')
    $runConflict = & powershell -NoProfile -File $rollback -ReceiptDir $conflictDir -Apply | ConvertFrom-Json
    if ($runConflict.status -ne 'blocked' -or $runConflict.blocked -ne 1 -or
        -not (Test-Path -LiteralPath $conflictFile)) {
        throw 'batch_conflict_not_reported'
    }
    $manualDir = Join-Path $testRoot 'manual-receipts'
    New-PrivateTestDirectory -Path $manualDir
    $manualFile = Join-Path $testRoot 'manual-ready.txt'
    [IO.File]::WriteAllBytes($manualFile, $content)
    Write-AgentShieldCreatedReceipt -Destination $manualFile -InstalledBytes $content `
        -ReceiptDir $manualDir | Out-Null
    Write-AgentShieldManualReviewReceipt -Destination $existingManaged -ReceiptDir $manualDir | Out-Null
    $manualRun = & powershell -NoProfile -File $rollback -ReceiptDir $manualDir -Apply | ConvertFrom-Json
    if ($manualRun.status -ne 'blocked' -or $manualRun.applied -ne 0 -or
        $manualRun.ready -ne 1 -or $manualRun.blocked -ne 1 -or
        -not (Test-Path -LiteralPath $manualFile)) {
        throw 'batch_manual_review_not_blocked'
    }
    $interruptedDir = Join-Path $testRoot 'interrupted-receipts'
    New-PrivateTestDirectory -Path $interruptedDir
    $interruptedFile = Join-Path $testRoot 'interrupted.txt'
    [IO.File]::WriteAllBytes($interruptedFile, $content)
    Write-AgentShieldManualReviewReceipt -Destination $interruptedFile `
        -ReceiptDir $interruptedDir -Reason 'receipt_incomplete' | Out-Null
    $interruptedRun = & powershell -NoProfile -File $rollback -ReceiptDir $interruptedDir -Apply | ConvertFrom-Json
    if ($interruptedRun.status -ne 'blocked' -or $interruptedRun.applied -ne 0 -or
        $interruptedRun.items[0].reason -ne 'receipt_incomplete' -or
        -not (Test-Path -LiteralPath $interruptedFile)) {
        throw 'interrupted_receipt_not_blocked'
    }
    $duplicateDir = Join-Path $testRoot 'duplicate-receipts'
    New-PrivateTestDirectory -Path $duplicateDir
    $duplicateFile = Join-Path $testRoot 'duplicate.txt'
    [IO.File]::WriteAllBytes($duplicateFile, $content)
    Write-AgentShieldCreatedReceipt -Destination $duplicateFile -InstalledBytes $content `
        -ReceiptDir $duplicateDir | Out-Null
    Write-AgentShieldCreatedReceipt -Destination $duplicateFile -InstalledBytes $content `
        -ReceiptDir $duplicateDir | Out-Null
    $duplicates = & powershell -NoProfile -File $rollback -ReceiptDir $duplicateDir | ConvertFrom-Json
    if ($duplicates.status -ne 'blocked' -or $duplicates.ready -ne 0 -or $duplicates.blocked -ne 2 -or
        @($duplicates.items | Where-Object { $_.reason -eq 'duplicate_destination' }).Count -ne 2 -or
        -not (Test-Path -LiteralPath $duplicateFile)) {
        throw 'batch_duplicate_not_rejected'
    }
    Write-Output 'RESULT: Windows rollback synthetic checks passed'
} finally {
    $absolute = [IO.Path]::GetFullPath($testRoot)
    $bounded = [IO.Path]::GetFullPath($scratch).TrimEnd('\') + '\rollback-windows-'
    if (-not $absolute.StartsWith($bounded, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'unsafe_test_cleanup_path'
    }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
}

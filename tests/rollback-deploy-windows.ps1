param([switch]$DistinctSidAcl)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'scripts\windows\deploy.ps1'
$rollback = Join-Path $repo 'scripts\windows\rollback.ps1'
$testRoot = Join-Path $repo ('tmp\rollback-deploy-windows-' + [Guid]::NewGuid().ToString('N'))

function New-PrivateReceiptDirectory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
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

function New-PrivateProfileDirectory {
    param([string]$Path, [string]$TargetSid)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
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
    $target = [Security.Principal.SecurityIdentifier]::new($TargetSid)
    $traverse = [Security.AccessControl.FileSystemAccessRule]::new(
        $target, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.InheritanceFlags]::None,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($traverse)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-ProfileAcl {
    param([string]$Path, [string]$TargetSid, [string]$OtherSid,
          [switch]$RequireFull)
    $acl = Get-Acl -LiteralPath $Path
    $allowed = @($acl.Access | Where-Object {
        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow
    })
    $targetRules = @($allowed | Where-Object {
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $TargetSid
    })
    $otherRules = @($allowed | Where-Object {
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $OtherSid
    })
    if (-not $RequireFull -and -not $acl.AreAccessRulesProtected) {
        throw "profile_acl_inheritance_enabled: $Path"
    }
    if (-not $targetRules.Count -or $otherRules.Count) {
        throw "profile_acl_mismatch: $Path"
    }
    if ($RequireFull -and -not @($targetRules | Where-Object {
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
            [Security.AccessControl.FileSystemRights]::FullControl
    }).Count) { throw "profile_owner_grant_missing: $Path" }
}

function New-FixtureDeployScript {
    param([string]$Path, [object[]]$Profiles)
    $content = [IO.File]::ReadAllText($source)
    $rootAnchor = '$script:RunId = [guid]::NewGuid().ToString()'
    $profileAnchor = '$allProfiles = Get-AllUserProfiles'
    foreach ($anchor in @($rootAnchor, $profileAnchor)) {
        if ([regex]::Matches($content, [regex]::Escape($anchor)).Count -ne 1) {
            throw 'deploy_fixture_anchor_changed'
        }
    }
    $root64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($repo))
    $profiles64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        ($Profiles | ConvertTo-Json -Compress -Depth 3)))
    $rootAssignment = '$ScriptDir = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $root64 + '''))'
    $profileAssignment = '$allProfiles = @(([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $profiles64 + ''')) | ConvertFrom-Json))'
    $content = $content.Replace($rootAnchor, $rootAssignment + "`n" + $rootAnchor)
    $content = $content.Replace($profileAnchor, $profileAssignment)
    [IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($false))
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'deploy_fixture_parse_failed' }
}

function Invoke-FixtureDeploy {
    param([string]$Path, [string]$ReceiptDir, [string]$LogPath, [int]$ExpectedOk)
    $output = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Path -Force `
        -Only claude-code -SkipTools -SkipVSCode -ExperimentalReceiptDir $ReceiptDir `
        -LogPath $LogPath -OutputMode Json 2>&1)
    $code = $LASTEXITCODE
    $results = @($output | Where-Object { $_ -is [string] -and $_ -match '^\{' } |
        ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'result' })
    if ($code -ne 0 -or $results.Count -ne 1 -or $results[0].status -ne 'success' -or
        $results[0].targets.ok -ne $ExpectedOk -or $results[0].targets.failed -ne 0 -or
        $results[0].managed -or $results[0].dry_run) {
        $output | Select-Object -Last 10 | ForEach-Object { Write-Warning $_ }
        throw 'fixture_deploy_failed'
    }
}

function Assert-ReceiptProfiles {
    param([string]$ReceiptDir, [string[]]$Homes)
    $seen = @{}
    foreach ($entry in Get-ChildItem -LiteralPath $ReceiptDir -Filter '*.json' -File) {
        $receipt = [IO.File]::ReadAllText($entry.FullName) | ConvertFrom-Json
        $destination = [string]$receipt.operations[0].destination
        $matched = $false
        foreach ($profilePath in $Homes) {
            if ($destination.StartsWith($profilePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $seen[$profilePath] = $true
                $matched = $true
                break
            }
        }
        if (-not $matched) { throw 'receipt_outside_fixture_profiles' }
    }
    if ($seen.Count -ne $Homes.Count) { throw 'missing_profile_receipts' }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this isolated deploy test from an elevated PowerShell session.'
}
if (-not (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Git for Windows is required in PATH for this deploy and rollback fixture.'
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

foreach ($scenario in @('ready', 'review')) {
    $scenarioRoot = Join-Path $testRoot $scenario
    New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
    $homes = @((Join-Path $scenarioRoot 'profile-a'), (Join-Path $scenarioRoot 'profile-b'))
    $testSids = @('S-1-5-19', 'S-1-5-20')
    for ($index = 0; $index -lt $homes.Count; $index++) {
        if ($DistinctSidAcl) {
            New-PrivateProfileDirectory -Path $homes[$index] -TargetSid $testSids[$index]
        } else {
            New-Item -ItemType Directory -Path $homes[$index] -Force | Out-Null
        }
    }
    if ($scenario -eq 'review') {
        $existing = Join-Path $homes[1] '.claude\vendor-claude-code.md'
        New-Item -ItemType Directory -Path (Split-Path -Parent $existing) -Force | Out-Null
        [IO.File]::WriteAllText($existing, "user-owned fixture`n")
    }
    if ($DistinctSidAcl) {
        $profiles = @(
            [ordered]@{ Username = ('*' + $testSids[0]); Principal = $testSids[0]; Profile = $homes[0] },
            [ordered]@{ Username = ('*' + $testSids[1]); Principal = $testSids[1]; Profile = $homes[1] }
        )
    } else {
        $profiles = @(
            [ordered]@{ Username = $identity.Name; Principal = $identity.Name; Profile = $homes[0] },
            [ordered]@{ Username = $identity.Name; Principal = $identity.Name; Profile = $homes[1] }
        )
    }
    $deployCopy = Join-Path $scenarioRoot 'deploy.fixture.ps1'
    $receiptDir = Join-Path $scenarioRoot 'receipts'
    New-PrivateReceiptDirectory -Path $receiptDir
    New-FixtureDeployScript -Path $deployCopy -Profiles $profiles
    Invoke-FixtureDeploy -Path $deployCopy -ReceiptDir $receiptDir `
        -LogPath (Join-Path $scenarioRoot 'deploy.log') -ExpectedOk 2
    Assert-ReceiptProfiles -ReceiptDir $receiptDir -Homes $homes
    if ($DistinctSidAcl) {
        for ($index = 0; $index -lt $homes.Count; $index++) {
            $otherIndex = 1 - $index
            foreach ($relative in @('', '.git-hooks\pre-commit', '.claude\vendor-claude-code.md')) {
                $path = if ($relative) { Join-Path $homes[$index] $relative } else { $homes[$index] }
                Assert-ProfileAcl -Path $path -TargetSid $testSids[$index] `
                    -OtherSid $testSids[$otherIndex] -RequireFull:([bool]$relative)
            }
        }
        Write-Output 'RESULT: Windows distinct-SID fixture ACL grants are separated'
    }
    $preview = & powershell -NoProfile -File $rollback -ReceiptDir $receiptDir | ConvertFrom-Json
    $previewCode = $LASTEXITCODE
    if ($scenario -eq 'ready') {
        if ($previewCode -ne 0 -or $preview.status -ne 'ready' -or $preview.receipts -lt 2) {
            throw 'multi_profile_preview_not_ready'
        }
        $result = & powershell -NoProfile -File $rollback -ReceiptDir $receiptDir -Apply | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $result.status -ne 'restored' -or
            $result.applied -ne $preview.receipts) { throw 'multi_profile_rollback_failed' }
        foreach ($profilePath in $homes) {
            foreach ($relative in @('.git-hooks\pre-commit', '.claude\vendor-claude-code.md')) {
                if (Test-Path -LiteralPath (Join-Path $profilePath $relative)) {
                    throw 'fixture_file_survived_rollback'
                }
            }
        }
        Write-Output "RESULT: Windows isolated two-profile deploy and rollback passed (receipts=$($preview.receipts))"
    } else {
        if ($previewCode -ne 2 -or $preview.status -ne 'blocked' -or
            -not @($preview.items | Where-Object {
                $_.kind -eq 'manual_review' -and $_.reason -eq 'existing_target_has_no_inverse'
            }).Count) { throw 'multi_profile_review_not_blocked' }
        $blocked = & powershell -NoProfile -File $rollback -ReceiptDir $receiptDir -Apply | ConvertFrom-Json
        if ($LASTEXITCODE -ne 2 -or $blocked.status -ne 'blocked' -or $blocked.applied -ne 0 -or
            -not (Test-Path -LiteralPath (Join-Path $homes[0] '.git-hooks\pre-commit'))) {
            throw 'multi_profile_partial_rollback_occurred'
        }
        Write-Output 'RESULT: Windows existing file in second profile blocked batch rollback for both profiles'
    }
}
Write-Output "Evidence directory: $testRoot"

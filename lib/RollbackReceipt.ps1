function Assert-AgentShieldLocalReceiptPath {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if ($LiteralPath -notmatch '^[A-Za-z]:\\' -or
        $LiteralPath.Substring(2).Contains(':') -or
        $LiteralPath -match '[\x00-\x1f/]' -or
        @($LiteralPath.Split('\') | Where-Object { $_ -in @('.', '..') -or $_ -match '[. ]$' }).Count) {
        throw 'local_literal_path_required'
    }
}

function Assert-AgentShieldPrivateReceiptPath {
    param([Parameter(Mandatory)][string]$LiteralPath, [switch]$Directory)

    Assert-AgentShieldLocalReceiptPath -LiteralPath $LiteralPath
    Assert-AgentShieldDestinationParents -Destination $LiteralPath
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -ne [bool]$Directory.IsPresent) { throw 'receipt_path_type_invalid' }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'receipt_reparse_point' }

    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trusted = @($current, 'S-1-5-18', 'S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $LiteralPath -ErrorAction Stop
    $raw = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($raw.Owner.Value -notin $trusted) { throw 'receipt_owner_untrusted' }
    if (($raw.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -eq 0) {
        throw 'receipt_acl_inherited'
    }
    if (($raw.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -eq 0 -or
        $null -eq $raw.DiscretionaryAcl) { throw 'receipt_acl_missing' }
    foreach ($ace in $raw.DiscretionaryAcl) {
        if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback) { throw 'receipt_acl_unsupported' }
        if ($ace.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and
            $ace.SecurityIdentifier.Value -notin $trusted) { throw 'receipt_acl_broad_access' }
    }
}

function Assert-AgentShieldEmptyReceiptDirectory {
    param([Parameter(Mandatory)][string]$LiteralPath)
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $LiteralPath -Directory
    $first = Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $first) { throw 'receipt_directory_not_empty' }
}

function Assert-AgentShieldDestinationParents {
    param([Parameter(Mandatory)][string]$Destination)
    Assert-AgentShieldLocalReceiptPath -LiteralPath $Destination
    $current = [IO.Directory]::GetParent([IO.Path]::GetFullPath($Destination))
    while ($null -ne $current) {
        $item = Get-Item -LiteralPath $current.FullName -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'destination_parent_reparse_point'
        }
        $current = $current.Parent
    }
}

function Write-AgentShieldReceiptPayload {
    param([Parameter(Mandatory)]$Payload, [Parameter(Mandatory)][string]$ReceiptDir)
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
    $receipt = Join-Path $ReceiptDir (([Guid]::NewGuid().ToString('N')) + '.json')
    $bytes = ([System.Text.UTF8Encoding]::new($false)).GetBytes(($Payload | ConvertTo-Json -Compress -Depth 5))
    $stream = [IO.File]::Open($receipt, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    $fileAcl = Get-Acl -LiteralPath $receipt -ErrorAction Stop
    $fileAcl.SetAccessRuleProtection($true, $false)
    foreach ($sidValue in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
        [void]$fileAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $receipt -AclObject $fileAcl -ErrorAction Stop
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $receipt
    return $receipt
}

function Write-AgentShieldManualReviewReceipt {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ReceiptDir,
        [ValidateSet('existing_target_has_no_inverse', 'receipt_incomplete')][string]$Reason = 'existing_target_has_no_inverse'
    )
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'manual_review'
            destination = [IO.Path]::GetFullPath($Destination)
            reason = $Reason
        })
    }
    return Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
}

function Clear-AgentShieldGitProvisionalReceipt {
    param(
        [Parameter(Mandatory)][string]$GuardPath,
        [Parameter(Mandatory)][string]$InversePath,
        [Parameter(Mandatory)][string]$Destination
    )
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $GuardPath
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $InversePath
    $guard = [IO.File]::ReadAllText($GuardPath) | ConvertFrom-Json
    $inverse = [IO.File]::ReadAllText($InversePath) | ConvertFrom-Json
    if ($guard.schema_version -ne 1 -or $guard.runner -cne 'agentshield-rollback' -or
        @($guard.operations).Count -ne 1 -or $guard.operations[0].kind -cne 'manual_review' -or
        $guard.operations[0].reason -cne 'receipt_incomplete' -or
        $guard.operations[0].destination -cne $Destination -or
        $inverse.schema_version -ne 1 -or $inverse.runner -cne 'agentshield-rollback' -or
        @($inverse.operations).Count -ne 1 -or
        $inverse.operations[0].kind -notin @('git_config', 'git_config_pair') -or
        $inverse.operations[0].destination -cne $Destination) {
        throw 'git_inverse_receipt_missing'
    }
    Remove-Item -LiteralPath $GuardPath -Force -ErrorAction Stop
}

function Write-AgentShieldCreatedReceipt {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][byte[]]$InstalledBytes,
        [Parameter(Mandatory)][string]$ReceiptDir
    )
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'unsafe_destination_type'
    }
    if ($item.Length -ne $InstalledBytes.Length) { throw 'installed_size_changed' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash($InstalledBytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'created_file'
            destination = [IO.Path]::GetFullPath($Destination)
            installed_sha256 = $digest
            installed_creation_utc_ticks = $item.CreationTimeUtc.Ticks
            installed_write_utc_ticks = $item.LastWriteTimeUtc.Ticks
            installed_length = [long]$item.Length
        })
    }
    return Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
}

function Write-AgentShieldKnownPriorReceipt {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ReceiptDir,
        [Parameter(Mandatory)][string]$PriorId,
        [Parameter(Mandatory)][string]$PriorSha256,
        [Parameter(Mandatory)][long]$PriorCreationTicks,
        [Parameter(Mandatory)][long]$PriorWriteTicks,
        [Parameter(Mandatory)][byte[]]$InstalledBytes
    )
    if ($PriorId -cne 'claude-statusline-53a8021' -or
        $PriorSha256 -cne 'f04381626792cd3278d670784be37e3dada670c3d9b15cae95f56f394aea5246') {
        throw 'known_prior_payload_invalid'
    }
    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'unsafe_destination_type'
    }
    if ($item.Length -ne $InstalledBytes.Length -or $item.Length -gt 1048576) {
        throw 'installed_size_changed'
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $installedHash = [BitConverter]::ToString($sha.ComputeHash($InstalledBytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $installedHash -or
        (Get-Item -LiteralPath $Destination -Force).LastWriteTimeUtc.Ticks -ne $item.LastWriteTimeUtc.Ticks) {
        throw 'installed_content_changed'
    }
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'known_prior_payload'
            target_id = 'claude-managed'
            destination = [IO.Path]::GetFullPath($Destination)
            prior_id = $PriorId
            prior_sha256 = $PriorSha256
            prior_creation_utc_ticks = $PriorCreationTicks
            prior_write_utc_ticks = $PriorWriteTicks
            installed_sha256 = $installedHash
            installed_creation_utc_ticks = $item.CreationTimeUtc.Ticks
            installed_write_utc_ticks = $item.LastWriteTimeUtc.Ticks
            installed_length = [long]$item.Length
        })
    }
    return Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
}

function Write-AgentShieldJsonKeyReceipt {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ReceiptDir,
        [Parameter(Mandatory)][byte[]]$PriorBytes,
        [Parameter(Mandatory)][long]$PriorCreationTicks,
        [Parameter(Mandatory)][long]$PriorWriteTicks,
        [Parameter(Mandatory)][byte[]]$InstalledBytes,
        [Parameter(Mandatory)][string[]]$AddedKeys
    )
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
    if ($PriorBytes.Length -lt 3 -or $PriorBytes.Length -gt 1048576 -or
        $InstalledBytes.Length -gt 1048576 -or $AddedKeys.Count -lt 1 -or
        $AddedKeys.Count -gt 256 -or $PriorCreationTicks -le 0 -or
        $PriorWriteTicks -le 0) { throw 'invalid_json_inverse' }
    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne $InstalledBytes.Length) { throw 'installed_size_changed' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $installedHash = [BitConverter]::ToString($sha.ComputeHash($InstalledBytes)).Replace('-', '').ToLowerInvariant()
        $priorHash = [BitConverter]::ToString($sha.ComputeHash($PriorBytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $installedHash -or
        (Get-Item -LiteralPath $Destination -Force).LastWriteTimeUtc.Ticks -ne $item.LastWriteTimeUtc.Ticks) {
        throw 'installed_content_changed'
    }
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'json_added_keys'
            inverse_version = 1
            destination = [IO.Path]::GetFullPath($Destination)
            prior_sha256 = $priorHash
            prior_length = [long]$PriorBytes.Length
            prior_creation_utc_ticks = $PriorCreationTicks
            prior_write_utc_ticks = $PriorWriteTicks
            installed_sha256 = $installedHash
            installed_creation_utc_ticks = $item.CreationTimeUtc.Ticks
            installed_write_utc_ticks = $item.LastWriteTimeUtc.Ticks
            installed_length = [long]$item.Length
            added_keys = @($AddedKeys)
        })
    }
    return Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
}

function Write-AgentShieldJsonListReceipt {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ReceiptDir,
        [Parameter(Mandatory)][byte[]]$PriorBytes,
        [Parameter(Mandatory)][long]$PriorCreationTicks,
        [Parameter(Mandatory)][long]$PriorWriteTicks,
        [Parameter(Mandatory)][byte[]]$InstalledBytes,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][Collections.IDictionary]$PriorLengths
    )
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
    if ($PriorBytes.Length -lt 3 -or $PriorBytes.Length -gt 1048576 -or
        $InstalledBytes.Length -gt 1048576 -or -not $Parent -or
        $PriorLengths.Count -lt 1 -or $PriorLengths.Count -gt 256 -or
        $PriorCreationTicks -le 0 -or $PriorWriteTicks -le 0) { throw 'invalid_json_inverse' }
    foreach ($name in $PriorLengths.Keys) {
        if (-not [string]$name -or [long]$PriorLengths[$name] -lt 0) {
            throw 'invalid_json_inverse'
        }
    }
    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne $InstalledBytes.Length) { throw 'installed_size_changed' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $installedHash = [BitConverter]::ToString($sha.ComputeHash($InstalledBytes)).Replace('-', '').ToLowerInvariant()
        $priorHash = [BitConverter]::ToString($sha.ComputeHash($PriorBytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $installedHash -or
        (Get-Item -LiteralPath $Destination -Force).LastWriteTimeUtc.Ticks -ne $item.LastWriteTimeUtc.Ticks) {
        throw 'installed_content_changed'
    }
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'json_list_append'
            inverse_version = 1
            destination = [IO.Path]::GetFullPath($Destination)
            parent = $Parent
            prior_lengths = $PriorLengths
            prior_sha256 = $priorHash
            prior_length = [long]$PriorBytes.Length
            prior_creation_utc_ticks = $PriorCreationTicks
            prior_write_utc_ticks = $PriorWriteTicks
            installed_sha256 = $installedHash
            installed_creation_utc_ticks = $item.CreationTimeUtc.Ticks
            installed_write_utc_ticks = $item.LastWriteTimeUtc.Ticks
            installed_length = [long]$item.Length
        })
    }
    return Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
}

function Write-AgentShieldJsonMcpReceipt {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ReceiptDir,
        [Parameter(Mandatory)][byte[]]$PriorBytes,
        [Parameter(Mandatory)][long]$PriorCreationTicks,
        [Parameter(Mandatory)][long]$PriorWriteTicks,
        [Parameter(Mandatory)][byte[]]$InstalledBytes,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string[]]$AddedServers
    )
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
    if ($PriorBytes.Length -lt 3 -or $PriorBytes.Length -gt 1048576 -or
        $InstalledBytes.Length -gt 1048576 -or -not $Parent -or
        $AddedServers.Count -lt 1 -or $AddedServers.Count -gt 256 -or
        @($AddedServers | Where-Object { -not $_ }).Count -ne 0 -or
        @($AddedServers | Select-Object -Unique).Count -ne $AddedServers.Count -or
        $PriorCreationTicks -le 0 -or $PriorWriteTicks -le 0) { throw 'invalid_json_mcp_inverse' }
    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne $InstalledBytes.Length) { throw 'installed_size_changed' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $installedHash = [BitConverter]::ToString($sha.ComputeHash($InstalledBytes)).Replace('-', '').ToLowerInvariant()
        $priorHash = [BitConverter]::ToString($sha.ComputeHash($PriorBytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $installedHash -or
        (Get-Item -LiteralPath $Destination -Force).LastWriteTimeUtc.Ticks -ne $item.LastWriteTimeUtc.Ticks) {
        throw 'installed_content_changed'
    }
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'json_mcp_added_servers'
            inverse_version = 1
            destination = [IO.Path]::GetFullPath($Destination)
            parent = $Parent
            added_servers = @($AddedServers)
            prior_sha256 = $priorHash
            prior_length = [long]$PriorBytes.Length
            prior_creation_utc_ticks = $PriorCreationTicks
            prior_write_utc_ticks = $PriorWriteTicks
            installed_sha256 = $installedHash
            installed_creation_utc_ticks = $item.CreationTimeUtc.Ticks
            installed_write_utc_ticks = $item.LastWriteTimeUtc.Ticks
            installed_length = [long]$item.Length
        })
    }
    return Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
}

function Write-AgentShieldAppendedBlockReceipt {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][byte[]]$PriorBytes,
        [Parameter(Mandatory)][byte[]]$InstalledBytes,
        [Parameter(Mandatory)][string]$ReceiptDir
    )
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'unsafe_destination_type'
    }
    if ($item.Length -ne $InstalledBytes.Length -or $PriorBytes.Length -ge $InstalledBytes.Length) {
        throw 'invalid_append_length'
    }
    for ($index = 0; $index -lt $PriorBytes.Length; $index++) {
        if ($PriorBytes[$index] -ne $InstalledBytes[$index]) { throw 'not_an_append' }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($sha.ComputeHash($InstalledBytes)).Replace('-', '').ToLowerInvariant()
        $priorDigest = [BitConverter]::ToString($sha.ComputeHash($PriorBytes)).Replace('-', '').ToLowerInvariant()
        $suffix = [byte[]]::new($InstalledBytes.Length - $PriorBytes.Length)
        [Array]::Copy($InstalledBytes, $PriorBytes.Length, $suffix, 0, $suffix.Length)
        $suffixDigest = [BitConverter]::ToString($sha.ComputeHash($suffix)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'appended_block'
            destination = [IO.Path]::GetFullPath($Destination)
            installed_sha256 = $digest
            prior_length = [long]$PriorBytes.Length
            prior_sha256 = $priorDigest
            suffix_sha256 = $suffixDigest
            installed_creation_utc_ticks = $item.CreationTimeUtc.Ticks
            installed_write_utc_ticks = $item.LastWriteTimeUtc.Ticks
            installed_length = [long]$item.Length
        })
    }
    return Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
}

function Invoke-AgentShieldGitConfig {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $contextVariables = @(
        'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
        'GIT_PREFIX', 'GIT_CEILING_DIRECTORIES', 'GIT_CONFIG',
        'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS'
    )
    $saved = @{}
    foreach ($name in $contextVariables) {
        $entry = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        if ($null -ne $entry) {
            $saved[$name] = $entry.Value
            Remove-Item -LiteralPath "Env:$name" -ErrorAction Stop
        }
    }
    $exitCode = 1
    try {
        & git config @Arguments
        $exitCode = $LASTEXITCODE
    } finally {
        foreach ($name in $contextVariables) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        foreach ($name in $saved.Keys) {
            Set-Item -LiteralPath "Env:$name" -Value $saved[$name] -ErrorAction Stop
        }
        $global:LASTEXITCODE = $exitCode
    }
}

function Get-AgentShieldGitConfigValue {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$Key)
    if ($Key -notin @('core.hooksPath', 'init.templateDir')) { throw 'unsupported_git_key' }
    Assert-AgentShieldDestinationParents -Destination $ConfigPath
    $existing = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing -and ($existing.PSIsContainer -or
        ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'unsafe_git_config_type'
    }
    $values = @(Invoke-AgentShieldGitConfig -Arguments @('--file', $ConfigPath, '--get-all', $Key) 2>$null)
    $code = $LASTEXITCODE
    if ($code -eq 1 -and $values.Count -eq 0) { return $null }
    if ($code -ne 0) { throw 'git_config_read_failed' }
    if ($values.Count -ne 1 -or [string]$values[0] -match '[\x00\r\n]') {
        throw 'git_config_multiple_or_invalid_values'
    }
    return [string]$values[0]
}

function Set-AgentShieldGitConfigWithReceipt {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$ReceiptDir
    )
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
    if ($Key -notin @('core.hooksPath', 'init.templateDir') -or -not $Value -or $Value -match '[\x00\r\n]') {
        throw 'invalid_git_config_operation'
    }
    Assert-AgentShieldLocalReceiptPath -LiteralPath $Value
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $previous = Get-AgentShieldGitConfigValue -ConfigPath $ConfigPath -Key $Key
    if ($previous -ceq $Value) { return $null }
    $guard = Write-AgentShieldManualReviewReceipt -Destination $ConfigPath `
        -ReceiptDir $ReceiptDir -Reason 'receipt_incomplete'
    Invoke-AgentShieldGitConfig -Arguments @('--file', $ConfigPath, $Key, $Value) 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Get-AgentShieldGitConfigValue -ConfigPath $ConfigPath -Key $Key) -cne $Value) {
        throw 'git_config_write_failed'
    }
    $item = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction Stop
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'git_config'
            destination = $ConfigPath
            key = $Key
            installed_value = $Value
            previous_value = $previous
            installed_creation_utc_ticks = $item.CreationTimeUtc.Ticks
            installed_write_utc_ticks = $item.LastWriteTimeUtc.Ticks
            installed_length = [long]$item.Length
        })
    }
    $receipt = Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
    Clear-AgentShieldGitProvisionalReceipt -GuardPath $guard -InversePath $receipt -Destination $ConfigPath
    return $receipt
}

function Set-AgentShieldGitConfigPairWithReceipt {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$HooksDir,
        [Parameter(Mandatory)][string]$TemplateDir,
        [Parameter(Mandatory)][string]$ReceiptDir
    )
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
    Assert-AgentShieldLocalReceiptPath -LiteralPath $HooksDir
    Assert-AgentShieldLocalReceiptPath -LiteralPath $TemplateDir
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $previousHooks = Get-AgentShieldGitConfigValue -ConfigPath $ConfigPath -Key 'core.hooksPath'
    $previousTemplate = Get-AgentShieldGitConfigValue -ConfigPath $ConfigPath -Key 'init.templateDir'
    if ($previousHooks -ceq $HooksDir -and $previousTemplate -ceq $TemplateDir) { return $null }
    $guard = Write-AgentShieldManualReviewReceipt -Destination $ConfigPath `
        -ReceiptDir $ReceiptDir -Reason 'receipt_incomplete'
    if ($previousHooks -cne $HooksDir) {
        Invoke-AgentShieldGitConfig -Arguments @('--file', $ConfigPath, 'core.hooksPath', $HooksDir) 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -or
            (Get-AgentShieldGitConfigValue -ConfigPath $ConfigPath -Key 'core.hooksPath') -cne $HooksDir) {
            throw 'git_config_pair_write_failed'
        }
    }
    if ($previousTemplate -cne $TemplateDir) {
        Invoke-AgentShieldGitConfig -Arguments @('--file', $ConfigPath, 'init.templateDir', $TemplateDir) 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -or
            (Get-AgentShieldGitConfigValue -ConfigPath $ConfigPath -Key 'init.templateDir') -cne $TemplateDir) {
            throw 'git_config_pair_write_failed'
        }
    }
    $item = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction Stop
    $payload = [ordered]@{
        schema_version = 1
        runner = 'agentshield-rollback'
        operations = @([ordered]@{
            kind = 'git_config_pair'
            destination = $ConfigPath
            values = [ordered]@{
                'core.hooksPath' = [ordered]@{ installed_value = $HooksDir; previous_value = $previousHooks }
                'init.templateDir' = [ordered]@{ installed_value = $TemplateDir; previous_value = $previousTemplate }
            }
            installed_creation_utc_ticks = $item.CreationTimeUtc.Ticks
            installed_write_utc_ticks = $item.LastWriteTimeUtc.Ticks
            installed_length = [long]$item.Length
        })
    }
    $receipt = Write-AgentShieldReceiptPayload -Payload $payload -ReceiptDir $ReceiptDir
    Clear-AgentShieldGitProvisionalReceipt -GuardPath $guard -InversePath $receipt -Destination $ConfigPath
    return $receipt
}

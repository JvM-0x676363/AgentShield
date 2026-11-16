param([Parameter(Mandatory)][string]$Receipt, [switch]$Apply)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib/RollbackReceipt.ps1')

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-AppendedContent {
    param($Operation, [byte[]]$Bytes)
    $priorLength = [long]$Operation.prior_length
    if ($priorLength -lt 0 -or $priorLength -ge $Bytes.Length -or
        [string]$Operation.prior_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Operation.suffix_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'invalid_append_metadata'
    }
    $prior = [byte[]]::new([int]$priorLength)
    $suffix = [byte[]]::new($Bytes.Length - [int]$priorLength)
    [Array]::Copy($Bytes, 0, $prior, 0, $prior.Length)
    [Array]::Copy($Bytes, $prior.Length, $suffix, 0, $suffix.Length)
    if ((Get-BytesSha256 $prior) -cne [string]$Operation.prior_sha256 -or
        (Get-BytesSha256 $suffix) -cne [string]$Operation.suffix_sha256) {
        throw 'append_content_changed'
    }
}

try {
    $receiptPath = [IO.Path]::GetFullPath($Receipt)
    Assert-AgentShieldPrivateReceiptPath -LiteralPath (Split-Path -Parent $receiptPath) -Directory
    Assert-AgentShieldPrivateReceiptPath -LiteralPath $receiptPath
    $metadata = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
    if ($metadata.schema_version -ne 1 -or $metadata.runner -ne 'agentshield-rollback' -or
        @($metadata.operations).Count -ne 1) { throw 'invalid_receipt' }
    $operation = @($metadata.operations)[0]
    if ($operation.kind -notin @('created_file', 'appended_block', 'git_config', 'git_config_pair')) { throw 'unsupported_operation' }
    $destination = [string]$operation.destination
    Assert-AgentShieldLocalReceiptPath -LiteralPath $destination
    if ([IO.Path]::GetFullPath($destination) -ne $destination) { throw 'invalid_destination' }
    if ($operation.kind -in @('created_file', 'appended_block')) {
        $expected = [string]$operation.installed_sha256
        if ($expected -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid_digest' }
    } elseif ($operation.kind -eq 'git_config') {
        if ($operation.key -notin @('core.hooksPath', 'init.templateDir') -or
            -not [string]$operation.installed_value -or
            $operation.PSObject.Properties.Name -notcontains 'previous_value') {
            throw 'invalid_git_config_operation'
        }
        Assert-AgentShieldLocalReceiptPath -LiteralPath ([string]$operation.installed_value)
        if ($null -ne $operation.previous_value -and [string]$operation.previous_value -match '[\x00\r\n]') {
            throw 'invalid_git_config_operation'
        }
    } else {
        $pair = $operation.values
        $keys = @($pair.PSObject.Properties.Name)
        if ($keys.Count -ne 2 -or
            @($keys | Where-Object { $_ -notin @('core.hooksPath', 'init.templateDir') }).Count) {
            throw 'invalid_git_config_pair'
        }
        foreach ($key in @('core.hooksPath', 'init.templateDir')) {
            $entry = $pair.PSObject.Properties[$key].Value
            if ($null -eq $entry -or @($entry.PSObject.Properties.Name).Count -ne 2 -or
                $entry.PSObject.Properties.Name -notcontains 'installed_value' -or
                $entry.PSObject.Properties.Name -notcontains 'previous_value') {
                throw 'invalid_git_config_pair'
            }
            Assert-AgentShieldLocalReceiptPath -LiteralPath ([string]$entry.installed_value)
            if ($null -ne $entry.previous_value -and [string]$entry.previous_value -match '[\x00\r\n]') {
                throw 'invalid_git_config_pair'
            }
        }
    }
    Assert-AgentShieldDestinationParents -Destination $destination
    $item = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'unsafe_destination_type'
    }
    if ([long]$operation.installed_length -ne [long]$item.Length -or
        [long]$operation.installed_creation_utc_ticks -ne [long]$item.CreationTimeUtc.Ticks -or
        [long]$operation.installed_write_utc_ticks -ne [long]$item.LastWriteTimeUtc.Ticks) {
        throw 'destination_replaced_or_reinstalled'
    }
    if ($operation.kind -in @('created_file', 'appended_block')) {
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) {
            throw 'destination_changed'
        }
        if ($operation.kind -eq 'appended_block') {
            Assert-AppendedContent -Operation $operation -Bytes ([IO.File]::ReadAllBytes($destination))
        }
    } elseif ($operation.kind -eq 'git_config' -and
        (Get-AgentShieldGitConfigValue -ConfigPath $destination -Key $operation.key) -cne [string]$operation.installed_value) {
        throw 'git_config_value_changed'
    } elseif ($operation.kind -eq 'git_config_pair') {
        foreach ($key in @('core.hooksPath', 'init.templateDir')) {
            $entry = $operation.values.PSObject.Properties[$key].Value
            if ((Get-AgentShieldGitConfigValue -ConfigPath $destination -Key $key) -cne [string]$entry.installed_value) {
                throw 'git_config_value_changed'
            }
        }
    }
    if ($Apply) {
        # The file may have changed after preview. Recheck immediately before
        # the explicit removal; a conflict leaves it intact.
        $again = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
        if ($again.PSIsContainer -or ($again.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $again.Length -ne [long]$operation.installed_length -or
            $again.CreationTimeUtc.Ticks -ne [long]$operation.installed_creation_utc_ticks -or
            $again.LastWriteTimeUtc.Ticks -ne [long]$operation.installed_write_utc_ticks) {
            throw 'destination_changed'
        }
        if ($operation.kind -eq 'appended_block') {
            $stream = [IO.File]::Open($destination, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $locked = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
                if ($locked.PSIsContainer -or ($locked.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $locked.Length -ne [long]$operation.installed_length -or
                    $locked.CreationTimeUtc.Ticks -ne [long]$operation.installed_creation_utc_ticks -or
                    $locked.LastWriteTimeUtc.Ticks -ne [long]$operation.installed_write_utc_ticks) {
                    throw 'destination_changed'
                }
                $bytes = [byte[]]::new([int]$stream.Length)
                $offset = 0
                while ($offset -lt $bytes.Length) {
                    $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                    if ($count -le 0) { throw 'destination_changed' }
                    $offset += $count
                }
                if ((Get-BytesSha256 $bytes) -cne $expected) { throw 'destination_changed' }
                Assert-AppendedContent -Operation $operation -Bytes $bytes
                $stream.SetLength([long]$operation.prior_length)
                $stream.Flush($true)
            } finally { $stream.Dispose() }
        } elseif ($operation.kind -eq 'created_file') {
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) {
                throw 'destination_changed'
            }
            Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
        } elseif ($operation.kind -eq 'git_config_pair') {
            try {
                foreach ($key in @('init.templateDir', 'core.hooksPath')) {
                    $entry = $operation.values.PSObject.Properties[$key].Value
                    if ((Get-AgentShieldGitConfigValue -ConfigPath $destination -Key $key) -cne [string]$entry.installed_value) {
                        throw 'git_config_value_changed'
                    }
                    if ($entry.previous_value -ceq $entry.installed_value) { continue }
                    if ($null -eq $entry.previous_value) {
                        & git config --file $destination --unset-all $key 2>$null | Out-Null
                    } else {
                        & git config --file $destination $key ([string]$entry.previous_value) 2>$null | Out-Null
                    }
                    if ($LASTEXITCODE -ne 0 -or
                        (Get-AgentShieldGitConfigValue -ConfigPath $destination -Key $key) -cne $entry.previous_value) {
                        throw 'git_config_restore_failed'
                    }
                }
            } catch { throw 'git_config_partial_restore' }
        } else {
            if ((Get-AgentShieldGitConfigValue -ConfigPath $destination -Key $operation.key) -cne [string]$operation.installed_value) {
                throw 'git_config_value_changed'
            }
            if ($null -eq $operation.previous_value) {
                & git config --file $destination --unset-all $operation.key 2>$null | Out-Null
            } else {
                & git config --file $destination $operation.key ([string]$operation.previous_value) 2>$null | Out-Null
            }
            if ($LASTEXITCODE -ne 0 -or
                (Get-AgentShieldGitConfigValue -ConfigPath $destination -Key $operation.key) -cne $operation.previous_value) {
                throw 'git_config_restore_failed'
            }
        }
    }
    [ordered]@{
        schema_version = 1
        runner = 'rollback'
        status = $(if (-not $Apply) { 'ready' } elseif ($operation.kind -in @('git_config', 'git_config_pair', 'appended_block')) { 'restored' } else { 'removed' })
        dry_run = -not [bool]$Apply
        files = 1
        exit_code = 0
    } | ConvertTo-Json -Compress
    exit 0
} catch {
    [ordered]@{
        schema_version = 1
        runner = 'rollback'
        status = $(if ($_.Exception.Message -eq 'git_config_partial_restore') { 'partial' } else { 'blocked' })
        reason = $(if ($_.Exception.Message -match '^[a-z_]+$') { $_.Exception.Message } else { 'metadata_unavailable' })
        exit_code = 2
    } | ConvertTo-Json -Compress
    exit 2
}

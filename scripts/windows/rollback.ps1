param([string]$Receipt, [string]$ReceiptDir, [switch]$Apply)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib/RollbackReceipt.ps1')

if ($ReceiptDir -or -not $Receipt) {
    try {
        if ($Receipt -or -not $ReceiptDir) { throw 'receipt_source_invalid' }
        Assert-AgentShieldPrivateReceiptPath -LiteralPath $ReceiptDir -Directory
        $entries = @(Get-ChildItem -LiteralPath $ReceiptDir -Force -ErrorAction Stop | Sort-Object Name)
        if ($entries.Count -lt 1 -or $entries.Count -gt 128) { throw 'receipt_count_invalid' }
        $items = @()
        $destinations = @{}
        $prepared = @()
        $shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        foreach ($entry in $entries) {
            if ($entry.Name -cnotmatch '^[0-9a-f]{32}\.json$') {
                $items += [ordered]@{ id = $null; status = 'blocked'; reason = 'invalid_receipt_entry' }
                continue
            }
            $item = [ordered]@{ id = $entry.BaseName }
            try {
                Assert-AgentShieldPrivateReceiptPath -LiteralPath $entry.FullName
                if ($entry.Length -gt 1024 * 1024) { throw 'receipt_too_large' }
                $beforeDigest = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash
                $metadata = [IO.File]::ReadAllText($entry.FullName) | ConvertFrom-Json
                $item['kind'] = [string]@($metadata.operations)[0].kind
                $output = @(& $shell -NoProfile -File $PSCommandPath -Receipt $entry.FullName 2>$null)
                if ($output.Count -ne 1) { throw 'receipt_preview_failed' }
                $result = $output[0] | ConvertFrom-Json
                if ((Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash -cne $beforeDigest) {
                    throw 'receipt_changed'
                }
                if ($result.status -in @('ready', 'preview_only') -and
                    (($result.status -eq 'ready' -and $LASTEXITCODE -eq 0) -or
                     ($result.status -eq 'preview_only' -and $LASTEXITCODE -eq 2))) {
                    $item['status'] = [string]$result.status
                    $destination = [string]@($metadata.operations)[0].destination
                    if (-not $destinations.ContainsKey($destination)) {
                        $destinations[$destination] = [Collections.Generic.List[int]]::new()
                    }
                    $destinations[$destination].Add($items.Count)
                    if ($result.status -eq 'ready') {
                        $priority = $(if ($item['kind'] -in @('git_config', 'git_config_pair')) { 0 }
                            elseif ($item['kind'] -in @('appended_block', 'known_prior_payload')) { 1 } else { 2 })
                        $prepared += [pscustomobject]@{
                            Priority = $priority; Id = $entry.BaseName; Path = $entry.FullName
                            Digest = $beforeDigest; Index = $items.Count
                        }
                    } else { $item['reason'] = [string]$result.reason }
                } else {
                    $item['status'] = 'blocked'
                    $item['reason'] = $(if ([string]$result.reason -match '^[a-z_]+$') { [string]$result.reason } else { 'receipt_preview_failed' })
                }
            } catch {
                $item['status'] = 'blocked'
                $item['reason'] = $(if ($_.Exception.Message -match '^[a-z_]+$') { $_.Exception.Message } else { 'metadata_unavailable' })
            }
            $items += $item
        }
        foreach ($indices in $destinations.Values) {
            if ($indices.Count -gt 1) {
                foreach ($index in $indices) {
                    $items[$index]['status'] = 'blocked'
                    $items[$index]['reason'] = 'duplicate_destination'
                }
            }
        }
        $ready = @($items | Where-Object { $_.status -eq 'ready' }).Count
        $applied = 0
        $partialAttempt = $false
        $code = $(if ($ready -eq $items.Count) { 0 } else { 2 })
        if ($Apply -and $code -eq 0) {
            $currentNames = @(Get-ChildItem -LiteralPath $ReceiptDir -Force -ErrorAction Stop |
                Sort-Object Name | ForEach-Object Name)
            if (@(Compare-Object @($entries | ForEach-Object Name) $currentNames).Count -ne 0) {
                throw 'receipt_directory_changed'
            }
            foreach ($record in @($prepared | Sort-Object Priority, Id)) {
                $result = $null
                try {
                    Assert-AgentShieldPrivateReceiptPath -LiteralPath $record.Path
                    if ((Get-FileHash -LiteralPath $record.Path -Algorithm SHA256).Hash -cne $record.Digest) {
                        throw 'receipt_changed'
                    }
                    $output = @(& $shell -NoProfile -File $PSCommandPath -Receipt $record.Path -Apply 2>$null)
                    if ($output.Count -ne 1) { throw 'receipt_apply_failed' }
                    $result = $output[0] | ConvertFrom-Json
                    if ($LASTEXITCODE -ne 0 -or $result.status -notin @('removed', 'restored')) {
                        throw 'receipt_apply_failed'
                    }
                    $items[$record.Index]['status'] = [string]$result.status
                    $ready--
                    $applied++
                } catch {
                    $partialAttempt = $null -ne $result -and $result.status -eq 'partial'
                    $items[$record.Index]['status'] = $(if ($partialAttempt) { 'partial' } else { 'blocked' })
                    $items[$record.Index]['reason'] = 'receipt_apply_failed'
                    $ready--
                    $code = 2
                    break
                }
            }
        }
        $blocked = @($items | Where-Object { $_.status -in @('blocked', 'preview_only', 'partial') }).Count
        [ordered]@{
            schema_version = 1; runner = $(if ($Apply) { 'rollback' } else { 'rollback-preview' })
            status = $(if ($code -eq 0) { if ($Apply) { 'restored' } else { 'ready' } }
                elseif ($applied -gt 0 -or $partialAttempt) { 'partial' } else { 'blocked' })
            dry_run = -not [bool]$Apply; receipts = $items.Count; ready = $ready
            blocked = $blocked; applied = $applied; items = $items; exit_code = $code
        } | ConvertTo-Json -Compress -Depth 5
        exit $code
    } catch {
        [ordered]@{
            schema_version = 1; runner = $(if ($Apply) { 'rollback' } else { 'rollback-preview' }); status = 'blocked'
            reason = $(if ($_.Exception.Message -match '^[a-z_]+$') { $_.Exception.Message } else { 'metadata_unavailable' })
            exit_code = 2
        } | ConvertTo-Json -Compress
        exit 2
    }
}

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
    if ($operation.kind -notin @('created_file', 'appended_block', 'git_config', 'git_config_pair', 'manual_review', 'known_prior_payload')) { throw 'unsupported_operation' }
    $destination = [string]$operation.destination
    Assert-AgentShieldLocalReceiptPath -LiteralPath $destination
    if ([IO.Path]::GetFullPath($destination) -ne $destination) { throw 'invalid_destination' }
    if ($operation.kind -eq 'manual_review') {
        if ($operation.reason -notin @('existing_target_has_no_inverse', 'receipt_incomplete')) {
            throw 'invalid_manual_review_receipt'
        }
        [ordered]@{
            schema_version = 1; runner = 'rollback'; status = 'preview_only'
            reason = [string]$operation.reason; dry_run = $true; exit_code = 2
        } | ConvertTo-Json -Compress
        exit 2
    }
    if ($operation.kind -in @('created_file', 'appended_block', 'known_prior_payload')) {
        $expected = [string]$operation.installed_sha256
        if ($expected -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid_digest' }
        if ($operation.kind -eq 'known_prior_payload') {
            $managedDestination = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'ClaudeCode\statusline-security.py'
            if ($Apply -and $destination -ieq $managedDestination) {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = [Security.Principal.WindowsPrincipal]::new($identity)
                if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                    throw 'administrator_required'
                }
            }
            if ([string]$operation.target_id -cne 'claude-managed' -or
                [string]$operation.prior_id -cne 'claude-statusline-53a8021' -or
                [string]$operation.prior_sha256 -cne 'f04381626792cd3278d670784be37e3dada670c3d9b15cae95f56f394aea5246' -or
                [long]$operation.prior_creation_utc_ticks -le 0 -or
                [long]$operation.prior_write_utc_ticks -le 0 -or
                [long]$operation.installed_length -gt 1048576) {
                throw 'known_prior_payload_invalid'
            }
            $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $priorPath = Join-Path $repoRoot 'rollback-payloads\claude-statusline-53a8021.py'
            $priorItem = Get-Item -LiteralPath $priorPath -Force -ErrorAction Stop
            if ($priorItem.PSIsContainer -or ($priorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $priorItem.Length -gt 1048576 -or
                (Get-FileHash -LiteralPath $priorPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$operation.prior_sha256) {
                throw 'known_prior_payload_invalid'
            }
        }
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
    } elseif ($operation.kind -eq 'git_config_pair') {
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
    if ($operation.kind -in @('created_file', 'appended_block', 'known_prior_payload')) {
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
        if ($operation.kind -eq 'known_prior_payload') {
            $priorBytes = [IO.File]::ReadAllBytes($priorPath)
            if ((Get-BytesSha256 $priorBytes) -cne [string]$operation.prior_sha256) {
                throw 'known_prior_payload_invalid'
            }
            $stream = [IO.File]::Open($destination, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $locked = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
                if ($locked.PSIsContainer -or ($locked.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $locked.Length -ne [long]$operation.installed_length -or
                    $locked.CreationTimeUtc.Ticks -ne [long]$operation.installed_creation_utc_ticks -or
                    $locked.LastWriteTimeUtc.Ticks -ne [long]$operation.installed_write_utc_ticks) {
                    throw 'destination_changed'
                }
                $currentBytes = [byte[]]::new([int]$stream.Length)
                $offset = 0
                while ($offset -lt $currentBytes.Length) {
                    $count = $stream.Read($currentBytes, $offset, $currentBytes.Length - $offset)
                    if ($count -le 0) { throw 'destination_changed' }
                    $offset += $count
                }
                if ((Get-BytesSha256 $currentBytes) -cne $expected) { throw 'destination_changed' }
                $stream.Position = 0
                $stream.SetLength(0)
                $stream.Write($priorBytes, 0, $priorBytes.Length)
                $stream.Flush($true)
            } catch {
                if ($_.Exception.Message -eq 'destination_changed') { throw }
                throw 'known_prior_partial_restore'
            } finally { $stream.Dispose() }
            try {
                [IO.File]::SetCreationTimeUtc($destination, [DateTime]::new([long]$operation.prior_creation_utc_ticks, [DateTimeKind]::Utc))
                [IO.File]::SetLastWriteTimeUtc($destination, [DateTime]::new([long]$operation.prior_write_utc_ticks, [DateTimeKind]::Utc))
                if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$operation.prior_sha256) {
                    throw 'known_prior_partial_restore'
                }
            } catch { throw 'known_prior_partial_restore' }
        } elseif ($operation.kind -eq 'appended_block') {
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
        status = $(if (-not $Apply) { 'ready' } elseif ($operation.kind -in @('git_config', 'git_config_pair', 'appended_block', 'known_prior_payload')) { 'restored' } else { 'removed' })
        dry_run = -not [bool]$Apply
        files = 1
        exit_code = 0
    } | ConvertTo-Json -Compress
    exit 0
} catch {
    [ordered]@{
        schema_version = 1
        runner = 'rollback'
        status = $(if ($_.Exception.Message -in @('git_config_partial_restore', 'known_prior_partial_restore')) { 'partial' } else { 'blocked' })
        reason = $(if ($_.Exception.Message -match '^[a-z_]+$') { $_.Exception.Message } else { 'metadata_unavailable' })
        exit_code = 2
    } | ConvertTo-Json -Compress
    exit 2
}

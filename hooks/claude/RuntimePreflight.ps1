Set-StrictMode -Version Latest

function Test-AgentShieldAclMetadata {
    param([Parameter(Mandatory)]$Metadata)

    $trusted = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    try {
        if ($Metadata.ReparsePoint -ne $false) { return 'reparse_point' }
        if ($Metadata.Owner -notin $trusted) { return 'untrusted_owner' }
        if (-not $Metadata.DaclPresent -or $null -eq $Metadata.Aces) { return 'missing_dacl' }
        # Write, append, extended attributes, delete child, attributes, delete,
        # change ACL/owner, and generic write/all can change protected content.
        $writeMask = [uint32]0x500D0156
        foreach ($ace in $Metadata.Aces) {
            if ($ace.Type -notin @('AccessAllowed', 'AccessDenied')) { return 'unsupported_ace' }
            if ($ace.Type -eq 'AccessDenied') { continue }
            if (([uint32]$ace.Mask -band $writeMask) -ne 0 -and $ace.Sid -notin $trusted) {
                return 'untrusted_write_grant'
            }
        }
        return 'windows_acl_checked'
    } catch {
        return 'invalid_acl_metadata'
    }
}

function Test-AgentShieldWindowsPath {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if ($LiteralPath -notmatch '^[A-Za-z]:\\' -or
        $LiteralPath.Substring(2).Contains(':') -or
        $LiteralPath -match '[\x00-\x1f/]' -or
        @($LiteralPath.Split('\') | Where-Object { $_ -in @('.', '..') -or $_ -match '[. ]$' }).Count) {
        return @{ passed = $false; reason = 'local_literal_path_required' }
    }
    try {
        $current = $LiteralPath
        $leaf = $true
        while ($true) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($leaf -and $item.PSIsContainer) -or (-not $leaf -and -not $item.PSIsContainer)) {
                return @{ passed = $false; reason = 'unexpected_file_type' }
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return @{ passed = $false; reason = 'reparse_point' }
            }
            $acl = Get-Acl -LiteralPath $current -ErrorAction Stop
            $raw = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
            $aces = @()
            foreach ($ace in $raw.DiscretionaryAcl) {
                if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback) {
                    return @{ passed = $false; reason = 'unsupported_ace' }
                }
                $aces += @{
                    Type = $ace.AceType.ToString()
                    Sid = $ace.SecurityIdentifier.Value
                    Mask = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ace.AccessMask), 0)
                }
            }
            $reason = Test-AgentShieldAclMetadata @{
                ReparsePoint = $false
                Owner = $raw.Owner.Value
                DaclPresent = (($raw.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -ne 0)
                Aces = $(if ($null -eq $raw.DiscretionaryAcl) { $null } else { $aces })
            }
            if ($reason -ne 'windows_acl_checked') { return @{ passed = $false; reason = $reason } }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $current = $parent.FullName
            $leaf = $false
        }
        return @{ passed = $true; reason = 'windows_acl_checked' }
    } catch {
        return @{ passed = $false; reason = 'metadata_unavailable' }
    }
}

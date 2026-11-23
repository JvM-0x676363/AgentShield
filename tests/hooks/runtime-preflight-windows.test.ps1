$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../hooks/claude/RuntimePreflight.ps1"
$script:checks = 0
function Assert-Equal($Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "Expected $Expected, received $Actual" }
    $script:checks++
}
function New-Metadata($Aces) {
    return @{ Owner = 'S-1-5-18'; ReparsePoint = $false; DaclPresent = $true; Aces = @($Aces) }
}
$read = @{ Type = 'AccessAllowed'; Sid = 'S-1-1-0'; Mask = 0x1200A9 }
Assert-Equal (Test-AgentShieldAclMetadata (New-Metadata @($read))) 'windows_acl_checked'
foreach ($mask in @(2, 4, 16, 64, 256, 65536, 262144, 524288, 0x10000000, 0x40000000)) {
    $write = @{ Type = 'AccessAllowed'; Sid = 'S-1-1-0'; Mask = $mask }
    Assert-Equal (Test-AgentShieldAclMetadata (New-Metadata @($write))) 'untrusted_write_grant'
    $deny = @{ Type = 'AccessDenied'; Sid = 'S-1-1-0'; Mask = $mask }
    Assert-Equal (Test-AgentShieldAclMetadata (New-Metadata @($deny, $write))) 'untrusted_write_grant'
}
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')) {
    $metadata = New-Metadata @(@{ Type = 'AccessAllowed'; Sid = $sid; Mask = 0x1F01FF })
    $metadata.Owner = $sid
    Assert-Equal (Test-AgentShieldAclMetadata $metadata) 'windows_acl_checked'
}
$metadata = New-Metadata @($read)
$metadata.Owner = 'S-1-5-21-1000'
Assert-Equal (Test-AgentShieldAclMetadata $metadata) 'untrusted_owner'
$metadata.Owner = 'S-1-5-18'
$metadata.ReparsePoint = $true
Assert-Equal (Test-AgentShieldAclMetadata $metadata) 'reparse_point'
$metadata.ReparsePoint = $false
$metadata.DaclPresent = $false
Assert-Equal (Test-AgentShieldAclMetadata $metadata) 'missing_dacl'
$metadata.DaclPresent = $true
$metadata.Aces = $null
Assert-Equal (Test-AgentShieldAclMetadata $metadata) 'missing_dacl'
Assert-Equal (Test-AgentShieldAclMetadata @{}) 'invalid_acl_metadata'
Assert-Equal (Test-AgentShieldAclMetadata (New-Metadata @(@{ Type = 'AccessAllowedCallback'; Sid = 'S-1-5-18'; Mask = 0 }))) 'unsupported_ace'
foreach ($candidate in @('node.exe', '\\server\node.exe', 'C:\node.exe:stream', 'C:\tools\..\node.exe', 'C:\tools.\node.exe')) {
    Assert-Equal (Test-AgentShieldWindowsPath $candidate).reason 'local_literal_path_required'
}
# Inspect only this repository fixture; do not change any ACL or execute it.
$local = Test-AgentShieldWindowsPath "$PSScriptRoot\runtime-preflight-windows.test.ps1"
Assert-Equal ($local.ContainsKey('passed') -and $local.ContainsKey('reason')) $true
Write-Output "RESULT: $script:checks OK, 0 FAIL"

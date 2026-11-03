$ErrorActionPreference = 'Stop'

$baseDir = 'C:\Windows\Temp'
$zip = Join-Path $baseDir 'agent-shield.zip'
$packageDir = Join-Path $baseDir 'agent-shield'
$result = [ordered]@{ cleanup_ok = $false; removed_zip = $false; removed_dir = $false; base_dir = $baseDir; cleanup_error = '' }

try {
    if ($baseDir -ne 'C:\Windows\Temp') { throw 'Unexpected staging directory.' }
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force; $result.removed_zip = $true }
    if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force; $result.removed_dir = $true }
    $result.cleanup_ok = $true
} catch {
    $result.cleanup_error = $_.Exception.Message
}

$result | ConvertTo-Json -Compress

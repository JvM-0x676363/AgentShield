# Replace this placeholder with the SHA-256 of the reviewed agent-shield.zip
# before uploading the script to Falcon. Do not leave the placeholder in place.
$ExpectedPackageSha256 = '<AGENTSHIELD_PACKAGE_SHA256>'
$ErrorActionPreference = 'Stop'

$baseDir = 'C:\Windows\Temp'
$zip = Join-Path $baseDir 'agent-shield.zip'
$packageDir = Join-Path $baseDir 'agent-shield'
$powerShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$result = [ordered]@{
    outcome = 'error'; platform = 'windows'; package_sha256 = ''; extract_ok = $false
    precheck_compliant = $false; precheck_exit_code = -1; deploy_ran = $false
    deploy_status = ''; deploy_exit_code = -1; validate_compliant = $false
    validate_exit_code = -1; deploy_log_path = (Join-Path $baseDir 'agent-shield-deploy.log')
    error = ''; cleanup_ok = $false; cleanup_error = ''
}

function Invoke-PackageScript {
    param([string]$Path, [string[]]$Arguments)
    # The package hash is verified before this narrowly scoped execution-policy exception.
    $output = & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $json = @($output | ForEach-Object { "$_" } | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1
    return @{ json = [string]$json; exit_code = [int]$exitCode }
}

function Get-JsonBoolean {
    param([string]$Json, [string]$Property)
    try { return [bool](($Json | ConvertFrom-Json).$Property) } catch { return $false }
}

function Test-ComplianceResult {
    param([string]$Json)
    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
        return $null -ne $parsed.PSObject.Properties['compliant']
    } catch { return $false }
}

try {
    if ($ExpectedPackageSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Expected package SHA-256 is not configured.' }
    if (-not (Test-Path -LiteralPath $zip)) { throw 'AgentShield package was not found in the approved staging directory.' }
    $actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedPackageSha256.ToLowerInvariant()) { throw 'AgentShield package SHA-256 did not match the configured value.' }
    $result.package_sha256 = $actualHash

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $packageDir)
    $result.extract_ok = $true

    $detector = Join-Path $packageDir 'Test-AgentShieldManaged.ps1'
    $deploy = Join-Path $packageDir 'deploy.ps1'
    $precheck = Invoke-PackageScript -Path $detector -Arguments @('-OutputMode', 'Quiet')
    $result.precheck_exit_code = $precheck.exit_code
    if (-not (Test-ComplianceResult -Json $precheck.json)) {
        $result.outcome = 'precheck_failed'
    } else {
        $result.precheck_compliant = Get-JsonBoolean -Json $precheck.json -Property 'compliant'
        if ($result.precheck_compliant) {
            $result.outcome = 'already_compliant'
        } else {
            $deployment = Invoke-PackageScript -Path $deploy -Arguments @('-Force', '-SkipTools', '-SkipVSCode', '-OutputMode', 'Quiet')
            $result.deploy_ran = $true
            $result.deploy_exit_code = $deployment.exit_code
            try { $result.deploy_status = [string](($deployment.json | ConvertFrom-Json).status) } catch { $result.deploy_status = 'unparsed' }
            if ($deployment.exit_code -ne 0 -or $result.deploy_status -ne 'success') {
                $result.outcome = 'deploy_failed'
            } else {
                $validation = Invoke-PackageScript -Path $detector -Arguments @('-OutputMode', 'Quiet')
                $result.validate_exit_code = $validation.exit_code
                if (-not (Test-ComplianceResult -Json $validation.json)) {
                    $result.outcome = 'validation_failed'
                } else {
                    $result.validate_compliant = Get-JsonBoolean -Json $validation.json -Property 'compliant'
                    $result.outcome = if ($result.validate_compliant) { 'compliant_after_deploy' } else { 'not_compliant_after_deploy' }
                }
            }
        }
    }
} catch {
    $result.error = $_.Exception.Message
} finally {
    try {
        if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        $result.cleanup_ok = $true
    } catch {
        $result.cleanup_error = $_.Exception.Message
    }
}

$result | ConvertTo-Json -Compress

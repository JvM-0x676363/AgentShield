param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $binary = (Resolve-Path -LiteralPath $Executable).Path
    if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ne $ExpectedSha256) {
        throw 'hash_mismatch'
    }
    $marker = 'AK' + 'IA' + ('Z' * 16)
    $cases = @(
        @{ name = 'clean_write'; tool = 'Write'; input = @{ content = 'synthetic test'; file_path = 'pilot.txt' }; deny = $false },
        @{ name = 'secret_write'; tool = 'Write'; input = @{ content = $marker; file_path = 'pilot.txt' }; deny = $true },
        @{ name = 'secret_edit'; tool = 'Edit'; input = @{ new_string = $marker }; deny = $true },
        @{ name = 'secret_notebook'; tool = 'NotebookEdit'; input = @{ new_source = $marker }; deny = $true },
        @{ name = 'secret_multiedit'; tool = 'MultiEdit'; input = @{ edits = @(@{ new_string = $marker }) }; deny = $true },
        @{ name = 'invalid_content'; tool = 'Write'; input = @{ content = 12 }; deny = $true },
        @{ name = 'unsupported_tool'; tool = 'Unknown'; input = @{}; deny = $true },
        @{ name = 'malformed_json'; raw = '{'; deny = $true }
    )
    $checks = @()
    foreach ($case in $cases) {
        $raw = if ($case.ContainsKey('raw')) { $case.raw } else {
            @{ hook_event_name = 'PreToolUse'; tool_name = $case.tool; tool_input = $case.input } | ConvertTo-Json -Depth 8 -Compress
        }
        $process = New-Object Diagnostics.Process
        $process.StartInfo.FileName = $binary
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.EnvironmentVariables['NODE_OPTIONS'] = '--require nonexistent-synthetic-module'
        $passed = $false
        try {
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine($raw)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(5000)) { $process.Kill(); throw 'timeout' }
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            $result = $stdout | ConvertFrom-Json -ErrorAction Stop
            $decisionOk = if ($case.deny) {
                $result.hookSpecificOutput.hookEventName -eq 'PreToolUse' -and
                $result.hookSpecificOutput.permissionDecision -eq 'deny'
            } else { $stdout.Trim() -eq '{}' }
            $passed = $process.ExitCode -eq 0 -and $stderr.Length -eq 0 -and $decisionOk -and
                -not $stdout.Contains($marker) -and -not $stdout.Contains('pilot.txt')
        } catch {
            $passed = $false
        } finally {
            $process.Dispose()
        }
        $checks += @{ name = $case.name; passed = $passed }
    }
    $failed = @($checks | Where-Object { -not $_.passed }).Count
    @{ schema_version = 1; runner = 'native-hook-pilot'; status = $(if ($failed) { 'failed' } else { 'passed' })
       artifact_sha256 = $ExpectedSha256.ToLowerInvariant(); checks = $checks; failed = $failed
       claude_integration = 'not_tested'; endpoint_configuration_changed = $false
    } | ConvertTo-Json -Depth 6 -Compress
    if ($failed) { exit 1 }
} catch {
    '{"schema_version":1,"runner":"native-hook-pilot","status":"blocked","detail":"artifact_verification_failed","endpoint_configuration_changed":false}'
    exit 2
}

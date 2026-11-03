# Provisioning of Codex elevated fallback on Windows per profile.
# MXC is deliberately disabled in this distribution due to incompatibility.
# Setup is administrative; developer session and commands are not.

function Resolve-CodexExecutableForProfile {
    param(
        [string]$TargetHome
    )

    # Codex Desktop installs the binary per user. Do not use PATH here: in
    # deploys run as SYSTEM (or on a shared machine), it might point to
    # another user's installation. Search is restricted to the profile
    # receiving the sandbox and accepts only one version depth.
    $binRoot = Join-Path $TargetHome "AppData\Local\OpenAI\Codex\bin"
    $candidates = @(Get-ChildItem -Path (Join-Path $binRoot "*\codex.exe") -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0].FullName
}

function Initialize-CodexElevatedSandbox {
    param(
        [string]$TargetUser,
        [string]$TargetHome,
        [bool]$DryRun
    )

    if ([string]::IsNullOrWhiteSpace($TargetUser) -or
        [string]::IsNullOrWhiteSpace($TargetHome)) {
        Warn "    Codex sandbox: missing target identity or home profile -- setup skipped"
        return $false
    }

    $codexPath = Resolve-CodexExecutableForProfile -TargetHome $TargetHome
    if ([string]::IsNullOrWhiteSpace($codexPath)) {
        Warn "    Codex sandbox: binary not found in profile of $TargetUser -- setup pending"
        Warn "      Install Codex Desktop in that profile and reapply this package as Administrator."
        return $false
    }

    $codexHome = Join-Path $TargetHome ".codex"
    if ($DryRun) {
        Info "    [dry-run] codex sandbox setup --elevated --user $TargetUser --codex-home $codexHome"
        return $true
    }

    try {
        # Codex itself makes this operation safe for reapplication; thus a
        # rollout also repairs a missing setup after a client upgrade.
        & $codexPath sandbox setup --elevated --user $TargetUser --codex-home $codexHome
        if ($LASTEXITCODE -ne 0) {
            Warn "    Codex sandbox: elevated setup failed for $TargetUser (rc=$LASTEXITCODE)"
            return $false
        }
        Info "    Codex sandbox: elevated fallback provisioned for $TargetUser"
        return $true
    } catch {
        Warn "    Codex sandbox: elevated setup failed for $TargetUser -- $($_.Exception.Message)"
        return $false
    }
}

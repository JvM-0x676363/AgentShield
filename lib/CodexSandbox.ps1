# Provisioning of Codex elevated fallback on Windows.
# MXC is deliberately disabled in this distribution due to incompatibility.
# Setup is administrative; developer session and commands are not.

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

    $codex = Get-Command "codex.exe" -ErrorAction SilentlyContinue
    if (-not $codex) { $codex = Get-Command "codex" -ErrorAction SilentlyContinue }
    if (-not $codex) {
        Warn "    Codex sandbox: Codex binary not found in administrative PATH -- setup pending for $TargetUser"
        Warn "      Install/add Codex to PATH and reapply this package as Administrator."
        return $false
    }
    # ApplicationInfo exposes the executable via .Path; .Source may be empty
    # for commands not originating from modules.
    $codexPath = $codex.Path
    if ([string]::IsNullOrWhiteSpace($codexPath)) { $codexPath = $codex.Source }
    if ([string]::IsNullOrWhiteSpace($codexPath)) {
        Warn "    Codex sandbox: could not resolve Codex executable -- setup pending for $TargetUser"
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

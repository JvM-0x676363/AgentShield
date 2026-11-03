# Platform support

| Platform | Installer/deployer | Current status |
|---|---|---|
| Windows | PowerShell `scripts/windows/install.ps1` / `scripts/windows/deploy.ps1` | Supported; native Codex sandbox incident may require WSL |
| Linux | `scripts/unix/install.sh` / `scripts/unix/deploy.sh` | Supported |
| macOS | `scripts/unix/install.sh` / `scripts/unix/deploy.sh` | Payload and automated validation supported; smoke test pending |
| Windows with WSL | Independent Windows and WSL sessions | Supported and validated |

## Windows Codex sandbox note

The managed Windows fallback requires the `elevated` sandbox implementation.
Do not weaken it to `unelevated`, disable sandboxing, or run the desktop app
permanently as administrator to work around a startup issue. See
[Windows sandbox follow-up](WINDOWS-SANDBOX.md) for the current
incident record and escalation guidance.

## Scanner limitation

Gitleaks, Semgrep, and Trivy are allowed by the baseline where the relevant
agent supports command allowlists. This does not grant Semgrep write access to
the user's home directory. The planned local wrapper and versioned offline
rules are tracked in the [roadmap](roadmap.md).

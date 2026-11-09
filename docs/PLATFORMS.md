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

## Windows Codex defaults

Current Windows Codex clients ignore `~/.codex/managed_config.toml`. AgentShield
therefore enforces machine policy with
`%ProgramData%\OpenAI\Codex\requirements.toml` and does not modify the
developer-owned `~/.codex/config.toml`.

Use Codex Settings to select Workspace write, Ask for approval, disabled
sandbox network access, and cached web search. Approve for me is an optional
user choice that routes eligible approvals through automatic review without
expanding the workspace sandbox.

For an endpoint that previously received the AgentShield Windows default file,
inspect the first line of `~/.codex/managed_config.toml`. If it is the
AgentShield `security-team-block` header, rename the ignored legacy file to a
backup before restarting Codex. Do not rename a file whose origin is unknown.

## Scanner limitation

Gitleaks, Semgrep, and Trivy are allowed by the baseline where the relevant
agent supports command allowlists. This does not grant Semgrep write access to
the user's home directory. The planned local wrapper and versioned offline
rules are tracked in the [roadmap](roadmap.md).

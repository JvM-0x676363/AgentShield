# AgentShield

Security baselines, deployment tooling, and validation for AI coding agents.

AgentShield helps teams use coding assistants with a consistent security
baseline across developer workstations and managed endpoints. It configures
Claude Code, Claude Desktop, OpenAI Codex CLI, Google Antigravity, and VS Code;
protects common secret locations; installs an audit-only Git hook; and validates
the package before rollout. Codex writable sandboxes keep network access off by
default.

> Local controls improve the developer experience; they do not replace a
> server-side CI/CD security gate. Treat this repository as a baseline, then
> adapt it to your organization and threat model.

## Supported integrations

| Integration | User configuration | Managed enforcement |
|---|---|---|
| Claude Code | Instructions, permissions, MCP | Managed settings |
| Claude Desktop | MCP | Not available in product |
| OpenAI Codex CLI | `AGENTS.md`; Windows defaults stay user-owned | `requirements.toml` |
| Google Antigravity | Permissions and MCP | Not available in product |
| VS Code | Security extensions | GPO baseline available |

Supported endpoint platforms are Windows, Linux, macOS, and Windows with WSL.
See [platform notes](docs/PLATFORMS.md) for the current validation status.

## What it does

- Distributes a concise secure-development baseline and vendor-specific rules
  for Claude, Codex, Antigravity, and VS Code.
- Separates user defaults from administrator-managed enforcement where the
  agent supports it.
- Applies Claude permissions and MCP guidance, Codex managed requirements and
  defaults, Antigravity permissions and MCP guidance, and VS Code security
  extensions.
- Denies common secret and credential paths from managed Codex profiles and
  keeps writable Codex sandbox networking disabled by default.
- Adds Gitleaks, reviewed local Semgrep rules, and Trivy to an audit-only Git
  pre-commit workflow, with a structured local scanner for terminal and endpoint automation.
- Provides deterministic Windows PowerShell and Unix shell deployment engines.
- Validates manifests, policy, payloads, platform behavior, and installer
  parity before deployment.

## Quick start

Clone the source repository or extract a release ZIP, review the policy files,
then choose the execution model that matches your endpoint. Source commands use
`scripts/`; the release ZIP puts the runnable entry points at its root.

### Developer workstation

AgentShield configures every supported target by default. Use `-Only` or
`--only` when the workstation needs a specific agent. Valid selectors are
listed with `-ListTargets` or `--list-targets`; `claude-code` and
`claude-desktop` are separate targets.

Windows PowerShell:

```powershell
# Codex CLI only
powershell -ExecutionPolicy Bypass -File .\scripts\windows\install.ps1 `
  -Only codex -SkipTools -SkipVSCode

# Claude Code only
powershell -ExecutionPolicy Bypass -File .\scripts\windows\install.ps1 `
  -Only claude-code -SkipTools -SkipVSCode
```

Linux or macOS:

```bash
# Codex CLI only
bash ./scripts/unix/install.sh --only codex --skip-tools --skip-vscode

# Claude Code only
bash ./scripts/unix/install.sh --only claude-code --skip-tools --skip-vscode
```

Run the installer as an administrator/root account when you need the managed
enforcement layer. A non-privileged run still applies user-scoped defaults and
reports that managed enforcement was not applied.

### Codex on Windows

Select **Workspace write**, **Ask for approval**, disabled sandbox network
access, and cached web search in Codex Settings. This lets Codex work through
ordinary workspace changes without granting network or full-filesystem access.
If the desktop client offers **Approve for me**, it may be selected by the user
to send eligible approvals to automatic review. The sandbox boundary remains
the same. AgentShield enforces the permitted profiles and command restrictions
through `%ProgramData%\OpenAI\Codex\requirements.toml`; it does not overwrite
the developer-owned `~/.codex/config.toml`.

### Fleet deployment

For Intune, CrowdStrike RTR, SCCM, or another non-interactive execution
system, use the multi-profile deployment script with an explicit force flag:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\deploy.ps1 -Force -SkipTools -SkipVSCode
```

For Intune detection of the machine-managed layer, use the included native
PowerShell detector. It does not require Python and does not inspect user
profiles:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Test-AgentShieldManaged.ps1
```

Start with `-DryRun`; use `-SkipTools` for the fast configuration pass, then
run a separately approved tools-installation pass. The script detects SYSTEM
context, enumerates target profiles, writes a transcript when available, and
ends with a stable `AGENTSHIELD:` result line. See
[operations and endpoint deployment](docs/OPERATIONS.md).

### Build distribution artifacts

`agent-shield.zip` is the endpoint deployment payload. It contains runtime
configuration, scripts, and manifests only. Falcon workflow templates and VS
Code GPO files are optional operator assets in a separate
`agent-shield-integrations.zip` archive:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\build-package.ps1 `
  -OutDir .\dist -Force -IncludeShell -IncludeFalconTemplates -IncludeGpo
```

Upload only `agent-shield.zip` to endpoint tooling. Import or distribute the
integration archive from an operator workstation; never stage it on endpoints.

## Validate before publishing or rollout

```powershell
python3 tests/validate-config.py
python3 tests/parity-behavior.py
git diff --check
```

The validation suite has no third-party Python dependency. A successful run
must report zero failures. The optional behavior benchmarks are documented in
[benchmarks/agent-security](benchmarks/agent-security/README.md) and
[secure development journey](benchmarks/secure-development-journey/README.md).

## Documentation

- [Architecture and policy model](docs/ARCHITECTURE.md)
- [Operations: manual, Intune, and CrowdStrike RTR](docs/OPERATIONS.md)
- [Falcon RTR workflow template](integrations/falcon-rtr/README.md)
- [Script arguments and examples](docs/SCRIPT-REFERENCE.md)
- [Platform support and known limitations](docs/PLATFORMS.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Third-party content review](docs/governance/THIRD_PARTY_REVIEW.md)
- [Maturity roadmap](docs/roadmap.md)

## License

Licensed under the [Apache License 2.0](LICENSE).

## Security boundaries

AgentShield does not inspect or copy credentials, disable security controls,
or approve publishing and infrastructure changes. It treats repository files,
URLs, package metadata, prompts, and tool output as untrusted data. Do not add
real secrets to fixtures, tests, documentation, or issue reports.

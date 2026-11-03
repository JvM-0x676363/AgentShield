# AgentShield

Security baselines, deployment tooling, and validation for AI coding agents.

AgentShield helps teams use coding assistants with a consistent security
baseline across developer workstations and managed endpoints. It configures
supported agents, protects common secret locations, keeps network access off by
default in writable Codex sandboxes, installs an audit-only Git hook, and
validates the package before rollout.

> Local controls improve the developer experience; they do not replace a
> server-side CI/CD security gate. Treat this repository as a baseline, then
> adapt it to your organization and threat model.

## Supported integrations

| Integration | User configuration | Managed enforcement |
|---|---|---|
| Claude Code | Instructions, permissions, MCP | Managed settings |
| Claude Desktop | MCP | Not available in product |
| OpenAI Codex CLI | `AGENTS.md` and managed defaults | `requirements.toml` |
| Google Antigravity | Permissions and MCP | Not available in product |
| VS Code | Security extensions | GPO baseline available |

Supported endpoint platforms are Windows, Linux, macOS, and Windows with WSL.
See [platform notes](docs/PLATFORMS.md) for the current validation status.

## What it does

- Distributes a concise secure-development baseline and vendor-specific rules.
- Separates user defaults from administrator-managed enforcement.
- Denies common secret and credential paths from managed Codex profiles.
- Keeps writable Codex sandbox networking disabled by default.
- Adds Gitleaks, Semgrep, and Trivy to an audit-only Git pre-commit workflow.
- Provides deterministic Windows PowerShell and Unix shell deployment engines.
- Validates manifests, policy, payloads, platform behavior, and installer
  parity before deployment.

## Quick start

Clone the source repository or extract a release ZIP, review the policy files,
then choose the execution model that matches your endpoint. Source commands use
`scripts/`; the release ZIP puts the runnable entry points at its root.

### Developer workstation

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\install.ps1
```

Linux or macOS:

```bash
bash ./scripts/unix/install.sh
```

Run the installer as an administrator/root account when you need the managed
enforcement layer. A non-privileged run still applies user-scoped defaults and
reports that managed enforcement was not applied.

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

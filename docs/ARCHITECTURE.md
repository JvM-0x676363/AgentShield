# Architecture and policy model

AgentShield uses defense in depth. It separates useful developer defaults from
controls that must be applied by an administrator and from controls that must
remain on the server side.

| Layer | Purpose | Strength |
|---|---|---|
| User configuration | Instructions, editor integration, audit hooks | Advisory; users can change it |
| Managed configuration | Product-specific settings and Codex requirements | Product-dependent enforcement |
| CI/CD | Review, SAST, secret scanning, dependency and release gates | Authoritative release control |

The `targets/` manifests declare what is installed. `policy/` holds intent,
runtime guidance, vendor notes, and payloads. The PowerShell and Python engines
apply the same contract for Windows and Unix endpoints; parity tests verify
their shared behavior.

The pre-commit hook is intentionally audit-only. It gives fast local feedback;
it is not a substitute for a blocking server-side gate.

## Package layout

```text
agent-shield/
├── policy/
│   ├── brand-identity.md
│   ├── codex-managed-defaults.toml
│   ├── codex-requirements.toml
│   ├── codex-requirements-unix.toml
│   ├── core-guidelines.md
│   ├── core-runtime.md
│   ├── policy.json
│   ├── security-review-playbook.md
│   ├── tools.json
│   ├── vendor-antigravity.md
│   ├── vendor-claude-code.md
│   └── vendor-codex-cli.md
├── targets/
│   ├── README.md
│   ├── antigravity.json
│   ├── claude-code.json
│   ├── claude-desktop.json
│   ├── claude-managed.json
│   ├── codex-managed.json
│   ├── codex-user.json
│   └── vscode.json
├── lib/
│   ├── ApplyTargets.ps1
│   ├── CodexSandbox.ps1
│   ├── CodexSandboxProfile.ps1
│   ├── SecurityTools.ps1
│   ├── apply_targets.py
│   └── security-tools.sh
├── rules/        reviewed offline Semgrep baseline
├── scripts/      Windows, Unix, and scanner entry points
├── hooks/        audit hook and installed scanner launcher
├── tests/        source, parity, and endpoint verification
├── benchmarks/   synthetic security evaluation fixtures
└── docs/         architecture, operations, platform, and roadmap material
```

For deployment commands and post-install verification, see
[OPERATIONS.md](OPERATIONS.md).

## Distribution artifacts

`scripts/windows/build-package.ps1` creates a deployment archive named
`agent-shield.zip`. It contains only endpoint runtime payloads and is the file
transferred by MDM or RTR. `-IncludeShell` adds the Linux/macOS runtime to that
same deployment archive.

`-IncludeFalconTemplates` and `-IncludeGpo` create a separate
`agent-shield-integrations.zip`. It contains operator-side workflow templates
with sanitized mock fixtures, Falcon RTR custom scripts and schemas, and/or
GPO files. It must not be staged on an endpoint.

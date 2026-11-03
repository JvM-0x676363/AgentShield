# Operations and endpoint deployment

## Choose the correct entry point

In a source checkout, entry points are under `scripts/windows/` and
`scripts/unix/`. `scripts/windows/build-package.ps1` produces an operational
ZIP with `install.ps1`, `deploy.ps1`, `install.sh`, `deploy.sh`, and
`Test-AgentShieldManaged.ps1` at its root. With `-IncludeShell`, it also adds
`Test-AgentShieldManaged.sh`, so MDM and RTR commands remain short.

| Scenario | Windows | Linux/macOS |
|---|---|---|
| One interactive developer | `scripts/windows/install.ps1` | `scripts/unix/install.sh` |
| Multiple user profiles or SYSTEM context | `scripts/windows/deploy.ps1 -Force` | `scripts/unix/deploy.sh --force` |
| Preview only | Add `-DryRun` | Add `--dry-run` |
| Managed layer only | Add `-Only managed` | Add `--only managed` |

`install` targets the invoking user's profile. `deploy` is designed for fleet
execution: it enumerates eligible profiles and handles non-interactive
contexts. Do not use `install.ps1` from SYSTEM, because SYSTEM's profile is not
the developer profile.

## Manual execution

Run a dry run first:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\deploy.ps1 -DryRun -Force -SkipTools -SkipVSCode
```

Then run configuration deployment:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\deploy.ps1 -Force -SkipTools -SkipVSCode
```

Linux/macOS use the equivalent Bash commands:

```bash
sudo bash scripts/unix/deploy.sh --dry-run --force --skip-tools --skip-vscode
sudo bash scripts/unix/deploy.sh --force --skip-tools --skip-vscode
```

For one interactive Unix user, use `install.sh` rather than fleet deployment:

```bash
sudo bash scripts/unix/install.sh --skip-tools --skip-vscode
```

Real fleet deployments retain a local transcript. The default path is
`%SystemRoot%\Temp\agent-shield-deploy.log` on Windows and
`/var/log/agentshield/agent-shield-deploy.log` on Linux/macOS. Dry-runs do not
create a transcript. The final `AGENTSHIELD:` line is intended for
endpoint-management log collection. A non-zero exit code requires operator
review; do not infer success solely from earlier informational lines.

On Linux/macOS, a real `install.sh` run also records a user-only transcript at
`~/.local/state/agentshield/agent-shield-install.log`. It is mode `0600` and
is not created by a dry-run.

## Automation output modes

All entry points support an output mode: `-OutputMode` in PowerShell and
`--output-mode` in Bash. The values are `Console`, `Json`, and `Quiet`.
`Console` is the default interactive presentation. `Json` suppresses
human-oriented host output and emits JSON Lines `start`, `phase`, and `result`
events.
`Quiet` emits only the final JSON result.
They preserve the existing process exit codes and do not expose user
configuration or credential material.

Use `Json` for a remote responder or orchestration workflow:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\deploy.ps1 -Force -SkipTools -SkipVSCode -OutputMode Json
```

For a single workstation, `install.ps1` does not need `-Force`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\install.ps1 -SkipTools -SkipVSCode -OutputMode Json
```

Unix uses `--output-mode`:

```bash
sudo bash scripts/unix/deploy.sh --force --skip-tools --skip-vscode --output-mode Json
sudo bash scripts/unix/install.sh --skip-tools --skip-vscode --output-mode Quiet
```

The result has a versioned schema and includes `run_id`, `started_at_utc`,
`duration_ms`, `status`, `exit_code`, `runner`, `scope`, `selected`, `managed`,
`dry_run`, target counts, and the transcript path. On Unix, `log_path` is
`null` for a dry-run or when logging cannot be initialized. Treat `status=failed`, a
non-zero exit code, `managed=false`, or
`dry_run=true` as distinct workflow outcomes.

`Json` emits `start`, `phase`, and `result` events sharing one `run_id`.
`Quiet` emits only `result`. Fleet phases are `security_tools`,
`managed_enforcement`, `user_discovery`, `user_deployment`, and
`ownership_repair`; workstation
phases are `user_configuration`, `security_tools`, and `git_hooks`.

## Microsoft Intune

Build the deployment ZIP from the source checkout, then package its extracted
contents as the Win32 app. The deployment archive preserves only runtime
payloads (`targets/`, `policy/`, `lib/`, and `hooks/`) while exposing the
runnable Windows files at its root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\build-package.ps1 -OutDir .\dist -Force
```

Configure the install command to run `deploy.ps1` with `-Force`; use
`-SkipTools` and `-SkipVSCode` for the first, short configuration pass.

Deploy in a test ring first. Intune commonly runs scripts as SYSTEM, which is
supported by `deploy.ps1`, not by `install.ps1`. Collect the transcript and the
stable final result line before widening rollout. Install VS Code extensions
through the supplied GPO/logon approach or another user-context mechanism.

## CrowdStrike RTR and similar remote responders

Use the remote platform's approved file-transfer and PowerShell execution
features to place the full package on the endpoint. Run `deploy.ps1 -Force` in
an elevated/SYSTEM context, then retrieve the transcript from the configured
log path. Avoid interactive prompts: `-Force` is required by design for
non-interactive sessions.

Start with `-DryRun`; do not enable tools download until the endpoint ring and
network policy have been approved. The package does not perform network scans.

For a one-off RTR response, `deploy.ps1 -Force -OutputMode Json` remains
available. Collect the final result and retrieve the transcript only when the
result requires investigation. The deployment script is designed for SYSTEM
context; do not use `install.ps1` there.

The Falcon Fusion v3 workflow is available in
[`integrations/falcon-rtr`](../integrations/falcon-rtr/). It stages the release
ZIP, verifies its SHA-256 in a platform custom script, skips deploy when the
managed layer is already compliant, and records a typed outcome. Build with
`-IncludeShell` for Unix runtime and `-IncludeFalconTemplates` for the separate
`agent-shield-integrations.zip` operator asset. Only `agent-shield.zip` belongs
on endpoints. Upload the custom scripts and schemas, replace activity, group,
and SHA-256 placeholders, then run Falcon mocks and one approved pilot before
any broader rollout.

## Intune

Use a silent Win32 installation command with `deploy.ps1 -Force -OutputMode
Quiet`. Intune evaluates the process return code for installation outcome.
Use `Test-AgentShieldManaged.ps1` as the detection script; it validates the
machine-managed controls without requiring Python or touching user profiles:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Test-AgentShieldManaged.ps1
```

It exits `0` only when the managed layer is compliant and prints one JSON
result. Configure Intune detection to require exit code `0` and non-empty
stdout; do not reuse installer output as an Intune detection method. This
checks machine enforcement only. Use `verify-install.py` separately when a
user-profile conformity check is required.

### Integration reference

| Integration | Execution context | Install or deploy command | Compliance signal |
|---|---|---|---|
| Manual Windows | Interactive administrator for fleet; user for workstation | `deploy.ps1 -Force` or `install.ps1` | Console result and transcript |
| Intune Win32 | SYSTEM | `deploy.ps1 -Force -SkipTools -SkipVSCode -OutputMode Quiet` | `Test-AgentShieldManaged.ps1`: exit `0` plus stdout |
| Falcon RTR | Elevated remote session | Falcon Fusion v3 custom-script workflow | Typed apply result; retrieve transcript only for investigation |
| Linux/macOS MDM or SSH | root | `deploy.sh --force --skip-tools --skip-vscode --output-mode Quiet` | Final JSON and `/var/log/agentshield/agent-shield-deploy.log` |

Use a configuration-only first pass in endpoint-management platforms. Approve
tool downloads and VS Code extensions separately: downloads depend on network
policy, and extensions require a logged-in user context.

## Two-pass rollout

1. Deploy configuration only with `-SkipTools -SkipVSCode`.
2. Review the transcript, final result, and managed-layer status.
3. Deploy approved scanner tools in a separate maintenance window.
4. Apply VS Code extensions through a user-context mechanism.
5. Run post-install verification where access is available.

This separates a fast, deterministic policy rollout from downloads and editor
integration that can be slow or depend on user context.

## Post-install verification

Validate the source package before deployment. After deployment, verify the
files written to the endpoint:

```powershell
python3 tests/verify-install.py --expect-managed
```

For Intune, Falcon RTR, or another orchestrator, use the structured result:

```powershell
python3 tests/verify-install.py --expect-managed --output-mode Quiet
```

`Json` emits `start`, `phase`, and `result` events. `Quiet` emits only the
final JSON result. Neither mode exposes file content or existing user
configuration values.

Use `--home <path>` for a non-default profile and `--only <target>` to limit
verification to a selected target. The verifier does not print existing user
configuration or credential material.

```powershell
# Verify a specific user profile
python3 tests/verify-install.py --home /home/username --expect-managed

# Verify only a specific target
python3 tests/verify-install.py --only claude-code
```

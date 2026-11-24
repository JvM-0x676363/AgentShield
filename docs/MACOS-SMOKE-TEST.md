# macOS smoke-test runbook

This runbook records a repeatable, non-destructive check of the Unix runtime on
a real macOS host. It does not turn macOS support into a validated claim by
itself: retain the bounded evidence below and update the platform status only
after a reviewer accepts the result.

## Scope and safety boundary

Use a source checkout at a known revision on a disposable or approved test Mac.
Run the commands from a normal user session. They use `sudo` only for the
installer and deployer dry-runs; neither command writes user configuration,
installs scanner tools, changes Git configuration, or creates a transcript.

Do not use a developer's active profile for an apply test. Do not paste a user
profile, scanner output, configuration file, environment variable, or command
history into a ticket. The evidence requested here is limited to platform,
tool availability, result status, exit code, and scanner names/statuses.

## Preconditions

Confirm the host and local prerequisites without printing configuration values:

```bash
test "$(uname -s)" = Darwin
test "$(id -u)" -ne 0
command -v sudo git
python3 -c 'import sys; raise SystemExit(sys.version_info[0] != 3)'
```

If Python 3 is unavailable, stop. The installer preserves existing JSON files
rather than attempting a merge without a runnable Python 3 interpreter.

## Source validation

From the repository root, run the portable checks before touching the host
configuration:

```bash
bash -n scripts/unix/install.sh scripts/unix/deploy.sh \
  scripts/unix/agent-shield-scan.sh scripts/unix/Test-AgentShieldManaged.sh
python3 tests/validate-config.py
python3 tests/parity-behavior.py
python3 tests/rollback-created-file.py
```

The expected configuration and parity outcomes are zero failures. The rollback
test uses its own temporary fixtures; do not treat it as evidence that an
existing user profile can be rolled back automatically.

## Dry-run the user and managed paths

Run the two paths independently. `--skip-tools` ensures the smoke test does
not download or install Gitleaks or Trivy; `--skip-vscode` avoids extension
installation.

```bash
# One interactive user's Codex configuration, plan only.
sudo bash scripts/unix/install.sh --dry-run --only codex \
  --skip-tools --skip-vscode --output-mode Json

# Managed enforcement path, plan only.
sudo bash scripts/unix/deploy.sh --dry-run --force --only managed \
  --skip-tools --skip-vscode --output-mode Json
```

For each command, record only the final structured result's `status`,
`exit_code`, `runner`, `scope`, `managed`, and `dry_run` fields. A `dry_run`
value other than `true`, a non-zero exit code, or `status=failed` is a failed
smoke test and requires investigation before any apply run.

## Check the local scanner wrapper

Run the wrapper against the reviewed source checkout. It must not be treated as
a clean result merely because a scanner or its offline database is missing.

```bash
bash scripts/unix/agent-shield-scan.sh --path . --output-mode Json
```

Record only the final result's `status`, `exit_code`, and each scanner's name
and status. `environment_blocked` is expected only when Gitleaks, Trivy, or
the required offline Trivy database is unavailable; it is evidence of
incomplete coverage, not a passing scan. `findings` must be reviewed through
the scanner locally without exporting raw output.

## Close the pilot

Keep the run's revision, macOS version, CPU architecture, Python major/minor
version, and the bounded results above. Do not change
`docs/PLATFORMS.md` from “smoke test pending” until the evidence is reviewed.
An apply test, scanner installation, MDM rollout, or package release is a
separate change with its own approval and rollback plan.

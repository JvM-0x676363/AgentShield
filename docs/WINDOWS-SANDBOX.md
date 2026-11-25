# Windows Codex sandbox follow-up

## Current state

The `elevated` fallback can be provisioned successfully for the test identity,
but some Windows Codex Desktop sessions fail before loading `AGENTS.md` with a
setup-refresh error. The issue persisted after re-provisioning and rebooting on
the affected endpoint.

Do not downgrade to `unelevated`, disable sandboxing, or run Codex Desktop
permanently as administrator to bypass the issue. Those workarounds reduce the
isolation required by this baseline.

## Windows CLI pilot results (November 2026)

Two endpoints ran Codex CLI 0.172.0 with the managed `security_workspace`
profile from an ordinary PowerShell session. The test let Codex choose the
backend. Both runs returned `launcher_mxc=True sandbox_exit=0`: the observer
saw the MXC launcher as a child of the test process and the command exited
successfully.

| Endpoint | Observation |
|---|---|
| Windows workstation | MXC launched. The earlier startup error `0x80070003` did not recur in this run. |
| Windows 11 Hyper-V guest | An older checkout installed `allow_mxc = false`. After applying the updated policy and verifying its hash, the same probe observed MXC. |

To repeat the pilot, check that the source policy sets `prefer_mxc = true`
and permits only `elevated` as a legacy fallback. After applying
`codex-managed`, compare the SHA-256 hashes of
`policy/codex-requirements.toml` and `%ProgramData%\OpenAI\Codex\requirements.toml`.
Run the probe with `codex sandbox --include-managed-config -P security_workspace`
and observe the child launcher during execution. Record the CLI version,
launcher observation and exit code. A zero exit code alone leaves the backend
unconfirmed.

These runs covered CLI startup and command execution. Automatic fallback after
an MXC startup failure and the Desktop new-thread incident remain unverified.

## Coverage

| Scenario | Status |
|---|---|
| Windows native + `elevated` | Provisioned; new-thread stability blocked on affected endpoint |
| Linux in WSL2 | Validated |
| Windows and WSL on one endpoint | Validated as independent sessions |
| macOS | Automated payload validation exists; live smoke test pending |

Use WSL2 as the reference development and benchmark environment while the
native Windows incident remains open.

## Escalation

Open a support case with OpenAI and attach the sandbox log through an approved
private channel. Include the Codex Desktop and CLI versions, Windows build,
required `elevated` implementation, successful setup command, and complete
thread-start error. Do not paste logs into public issues.

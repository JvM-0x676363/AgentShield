# Windows Codex sandbox follow-up

## Current state

The `elevated` fallback can be provisioned successfully for the test identity,
but some Windows Codex Desktop sessions fail before loading `AGENTS.md` with a
setup-refresh error. The issue persisted after re-provisioning and rebooting on
the affected endpoint.

Do not downgrade to `unelevated`, disable sandboxing, or run Codex Desktop
permanently as administrator to bypass the issue. Those workarounds reduce the
isolation required by this baseline.

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

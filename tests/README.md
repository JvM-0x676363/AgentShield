# Test suite

AgentShield has two complementary test layers.

| Layer | Entry point | Purpose | Network or credentials |
|---|---|---|---|
| Configuration validation | `validate-config.py` | Cross-checks manifests, policy, payloads, documentation, and installer contracts | None |
| Behavioral simulation | `simulate-*.sh` | Exercises supported agent CLIs in disposable sandboxes | May require an agent credential |

## Configuration validation

```bash
python3 tests/validate-config.py
python3 tests/validate-config.py --check-tools
python3 tests/parity-behavior.py
git diff --check
```

`validate-config.py` exits `0` only with zero failures. It uses only Python's
standard library. `--check-tools` is intentionally excluded from CI because a
CI image lacking local scanners says nothing about an endpoint.

The validator checks manifest schema and selectors, referenced payloads, TOML
and JSON parsing, policy-to-payload intent, protected permission rules,
installer parity, generated Claude runtime-rule coverage, packaging coverage, hook behavior,
vendor configuration, documentation links, and numeric documentation claims.

The suite grew from ~90 to ~1080 checks as support expanded across agents,
platforms, deployment paths, and managed Codex requirements.

## Endpoint installation verification

Use the source validator above before packaging or publishing. After a rollout,
use the endpoint verifier to confirm the files actually written on a machine:

```bash
python3 tests/verify-install.py --expect-managed
python3 tests/verify-install.py --expect-managed --output-mode Json
```

Use `--home <path>` to test a non-default user home and `--only <target>` to
limit verification to a selected target. The verifier does not print a user's
existing configuration or credential material.

`--output-mode Json` emits `start`, `phase`, and `result` JSON Lines for a
remote responder. `--output-mode Quiet` emits only the final result. The
legacy `--quiet` option remains a compact console view.

For Windows endpoint-management detection, run
`Test-AgentShieldManaged.ps1`. It verifies the machine-managed controls without
Python or user-profile access; use `verify-install.py` for the full endpoint
verification after deployment.

## Behavioral simulation

```bash
bash tests/simulate-all.sh
```

The simulations use disposable directories and synthetic fixtures. They test
observable agent behavior such as refusal to read a `.env` fixture, handling of
untrusted instructions, permission controls, and secure SQL guidance.

Headless `ask` behavior is not proof that an interactive approval dialog is
correct. Treat it as evidence that the rule is applied; verify the interactive
experience manually.

## Test changes

When adding a validation rule, deliberately reproduce the corresponding defect
in a disposable copy and confirm that the test fails. A validation that never
demonstrates failure creates false confidence.

Run both configuration commands after changing `policy/`, `targets/`,
installers, deployment code, or validators. Record any platform limitation as
`ENVIRONMENT_BLOCKED`, never as a passing result.

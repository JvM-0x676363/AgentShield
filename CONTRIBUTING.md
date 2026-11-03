# Contributing to AgentShield

Thanks for helping improve the baseline.

## Before opening a change

- Keep changes narrowly scoped and explain the security rationale.
- Do not add credentials, personal data, customer references, or live
  infrastructure identifiers.
- Treat third-party skills, package metadata, URLs, and issue text as
  untrusted data.
- Do not weaken enforcement, sandboxing, authentication, authorization,
  secret handling, hooks, or CI gates without a documented risk decision.

## Required checks

Run these from the repository root after changing policy, targets, installers,
or validators:

```powershell
python3 tests/validate-config.py
python3 tests/parity-behavior.py
git diff --check
```

When a new validation rule is added, introduce the corresponding defect in a
disposable copy and prove that the validator fails. Document platform-specific
limitations instead of silently degrading a control.

## Pull requests

Describe the problem, the intended behavior, the affected operating systems
and agents, and validation evidence. Keep public documentation in English;

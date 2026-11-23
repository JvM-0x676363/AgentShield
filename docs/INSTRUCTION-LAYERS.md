# Instruction layers

Deployed Claude Code, Codex, and Antigravity context files contain the shared
security baseline and a short vendor-reference pointer. Vendor appendices and
the security review playbook are installed beside each context file and read
when the task requires them. Managed and fallback Claude contexts use the same
composition. Existing managed permissions and sandbox controls are unchanged.

Claude Desktop chat and VS Code extension settings do not gain Claude Code
hook enforcement through this change. Repository-local contributor guidance
is separate from deployed endpoint context.

## Generic managed hooks: pending

Project names, organization-specific patterns and per-project agent maps do
not belong in the default deployment. Any future generic hook must:

- Preserve existing denials; secret access must not become an approval prompt.
- Report evaluation failures explicitly and test startup failure, timeout,
  invalid input and missing dependencies under each supported client version.
- Use administrator-controlled scripts and validated interpreter locations.
- Avoid treating shell regex matching as filesystem or network containment.
- Test synthetic fixtures in CI without depending on another checkout.
- Cover packaging and endpoint detection on Windows, Linux and macOS.

No new hook is enabled by the instruction split. The disabled Claude write-guard
pilot is documented in [hooks/claude/README.md](../hooks/claude/README.md).
It is not included in installers, deployment targets, endpoint packages, or
managed payloads. Its configuration generator accepts only isolated testing;
activation remains pending a separately reviewed launcher and live client tests.

Provider-specific adapters need separate contracts and tests before deployment.
Measure context size separately from token usage and cached billing; reduced
text alone does not prove behavioral equivalence.

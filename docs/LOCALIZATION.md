# English-only migration checklist

Completion requires a content review and a conservative Portuguese-language
scan. Translation must not change commands, paths, keys, policy decisions, or
test behavior.

- [x] Policy payloads: `policy/policy.json`, `policy/tools.json`, Codex managed defaults, and Codex requirements.
- [x] Policy references: remaining vendor references and the security review playbook.
- [x] Target manifests: `claude-desktop.json`, `codex-user.json`, and `vscode.json`.
- [x] Target manifests: `antigravity.json`, `claude-code.json`, `claude-managed.json`, and `codex-managed.json`.
- [x] Shared runtime: `lib/`, `hooks/`, and `statusline/`.
- [x] Entry points: `scripts/windows/` and `scripts/unix/`.
- [x] Tests: validators, parity tests, simulations, and endpoint verification.
- [x] Integrations: `integrations/bitbucket/` and `integrations/vscode-gpo/`.
- [x] Repository instructions: `AGENTS.md` and `.claude/rules/`.
- [x] Final syntax, parity, documentation-link, and language audit.

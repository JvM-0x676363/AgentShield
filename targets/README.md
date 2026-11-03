# `targets/` application manifests

Each manifest describes one target: destination, format, merge strategy, and
payload. Installers do not contain per-tool configuration blocks; they iterate
these manifests.

This prevents duplicated platform logic across multiple installers. The
configuration validator exists because manifest/installer drift is a real
deployment risk.

## Targets

| Target id | Label | Scope | Tool group |
|---|---|---|---|
| `antigravity` | Antigravity (Google) | user | `antigravity` |
| `claude-code` | Claude Code CLI | user | `claude` |
| `claude-desktop` | Claude Desktop | user | `claude` |
| `claude-managed` | Claude Code managed-settings | machine | `claude`, `managed` |
| `codex-managed` | Codex CLI requirements | machine | `codex`, `managed` |
| `codex-user` | Codex CLI user config | user | `codex` |
| `vscode` | VS Code settings | user | `vscode` |

## Schema

| Field | Required | Description |
|---|---:|---|
| `id` | Yes | Unique identifier matching the filename. |
| `label` | Yes | Text displayed by installers. |
| `tool` | Yes | `policy/policy.json` coverage key. |
| `scope` | Yes | `user` iterates profiles; `machine` applies once. |
| `requires_admin` | Yes | Machine targets require `true`; user targets require `false`. |
| `selectors` | Yes | Short names accepted by `--only`, in addition to `id`. |
| `enforcement` | Yes | Per platform: `hard` or `advisory`. |
| `files[]` | Yes | File specifications described below. |
| `preflight[]` | No | Warning-only checks. |

## `files[]`

| Field | Description |
|---|---|
| `dest` | `windows`/`linux`/`darwin` map. An omitted OS skips the target. |
| `format` | `json`, `toml`, or `markdown`. |
| `strategy` | One of the strategies below. |
| `payload` | Literal JSON payload. |
| `payload_lines` | TOML/text line array, avoiding a TOML writer. |
| `payload_file` | Literal content from a file in `policy/`. |
| `payload_file_by_os` | OS-specific payload file map. |
| `compose` | `policy/` paths concatenated for Markdown. |
| `backup` | Creates `.bak` before modification when applicable. |

## Strategies

| Strategy | Behavior |
|---|---|
| `overwrite` | Replaces a file owned entirely by AgentShield. |
| `merge-permission-lists` | Merges `deny`/`ask`/`allow` arrays under the configured key. |
| `merge-mcp` | Merges only the MCP server key. |
| `merge-missing-keys` | Adds missing keys without overwriting user values. |
| `md-block` | Updates a marker-delimited Markdown block idempotently. |
| `remove` | Deletes a destination whose presence changes product behavior. Requires a rationale in `$comment`. |

## Important behavior

`managed-mcp.json` is removed rather than written because its presence enables
exclusive enterprise MCP configuration in Claude Code. Stopping future writes
does not remove a file that was already deployed.

No target writes `~/.codex/config.toml`: duplicate TOML keys are parse errors.
AgentShield uses files it owns, `managed_config.toml` and `requirements.toml`,
instead of modifying developer-owned configuration.

## Selectors

A target is selected when `--only` matches its `id` or an entry in `selectors`.
The `tool` field is not a selector. Current conventions are:

| Selector | Purpose |
|---|---|
| `<id>` | Select one target. |
| `claude`, `codex`, `antigravity`, `vscode` | Tool groups. |
| `managed` | Every machine-scope enforcement target. |
| `all` | Reserved engine default; manifests must not declare it. |

When adding an agent, add its tool selector and `managed` when the target has
machine scope.

## Instruction delivery

Context files such as `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` use `md-block`
and `compose`. The full security review playbook is delivered with `overwrite`
and is read only for reviews; it must not be composed into every prompt.

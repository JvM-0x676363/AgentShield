## Antigravity - what the policy layer actually covers

This appendix is specific to Google Antigravity (IDE and CLI). The facts here
are NOT true of the other assistants; do not generalize them.

Antigravity has the richest permission grammar of the four, and the only one
whose file rules cover reads by path the way this policy was originally
written for:

- `command(prefix)`, `command(regex)`, `command(*)`
- `read_file(/path)`, `write_file(/path)`
- `read_url(domain)`, `execute_url(domain)`
- `mcp(server/tool)`, `mcp(server/*)`, `mcp(*)`
- `unsandboxed(prefix)`, `unsandboxed(*)` - an attempt to leave the sandbox;
  denied here. This control is supported only by Business/Enterprise plans;
  elsewhere the rule documents intent but does not enforce it.

Rules go in `permissions.allow` / `permissions.ask` / `permissions.deny`, and
conflicts resolve in strict priority: **deny > ask > allow**. So a broad
`command(*)` in `ask` beats a narrow `command(git)` in `allow` - order the
buckets accordingly, or read-only git ends up prompting on every call.

Defaults worth knowing: the active project directory is auto-allowed for read
and write; web/MCP/non-workspace operations ask. With this deployment's
`toolPermission: proceed-in-sandbox`, a command that can stay in the terminal
sandbox runs without prompting, while one that needs to leave it asks. If the
sandbox is unavailable, Antigravity falls back to request-review. Explicit
deny/ask/allow rules still take priority over these defaults.

`read_file` accepts an absolute path or one relative to a workspace root; a
directory covers its contents recursively. Its only wildcard is the global
`*`, not a filename glob, so `read_file(.env)` protects the root `.env` but
cannot mean "every nested .env". This deployment denies known sensitive
workspace paths and credential stores; an invented sensitive filename inside a
workspace cannot be classified generically by this grammar. Keep secrets out
of workspaces and rely on the terminal sandbox plus `allowNonWorkspaceAccess:
false` as the containment boundary. This remains an audit-only layer because
the user can edit its configuration.

### There is no managed layer

This is the important difference. Antigravity documents **no admin or
machine-wide enforcement mechanism** - no equivalent of Claude Code's
`managed-settings.json` or Codex's `requirements.toml`. Everything lives in
the user's own profile:

| Purpose | Path |
|---|---|
| Permissions | `~/.gemini/antigravity-cli/settings.json` |
| MCP servers (global) | `~/.gemini/config/mcp_config.json` |
| MCP servers (workspace) | `.agents/mcp_config.json` |
| Rules | `AGENTS.md`, `GEMINI.md` |

Consequences, stated plainly rather than papered over:

- Antigravity config is **audit-only on every platform**, including Windows.
  The developer can edit all of it. It buys early visibility and friction, not
  containment.
- `~/.gemini/` is the Antigravity tree here, and this package also writes the
  guidance into `~/.gemini/GEMINI.md` plus the on-demand references beside it.
  `~/.gemini/settings.json` stays untouched: it belongs to Gemini CLI, which a
  developer may still have installed even though this package no longer
  configures it.
- The real gate for Antigravity work is the same as for everything else: the
  pipeline and the branch restriction, which run outside the developer's
  machine.

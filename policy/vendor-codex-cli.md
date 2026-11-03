## Codex CLI - what the policy layer actually covers

This appendix is specific to OpenAI Codex CLI. The facts here are NOT true of
the other assistants; do not generalize them.

Codex combines a sandbox and approval policy with managed filesystem
requirements. This differs from Claude Code's per-tool grammar:

- Permission profiles - this deployment permits only the managed
  `security_readonly` and `security_workspace` profiles. They inherit,
  respectively, `:read-only` and `:workspace`, and add secret-read denials.
- `approval_policy` - `on-request`, `never`, or granular policy controls when
  the agent pauses for approval. `untrusted` is no longer configurable: it
  describes behavior derived from `trust_level = "untrusted"` in a project and
  can therefore still appear in `allowed_approval_policies`.
- `sandbox_workspace_write.network_access` - the boolean that re-enables
  network inside a writable sandbox. Leaving this `false` is what closes the
  exfiltration channel, and it does so more completely than denying `curl` by
  name: it is enforced by the OS sandbox, not by matching a command string.

Managed `requirements.toml` defines filesystem rules inside each permission
profile. This deployment puts deny globs under `:workspace_roots`; the Windows
payload also lists exact credential-store paths for direct file tools. On
Linux/macOS, `:workspace` already excludes `HOME`; repeating those paths makes
Bubblewrap mount outside its new root and prevents startup. The filesystem rule
is additional, not a substitute for the sandbox: on native Windows shell
subprocess reads do not use it. Network-off sandboxing and approval rules
therefore remain necessary.

On Windows MXC, deny patterns containing `**` are expanded before sandbox
startup. `glob_scan_max_depth = 4` therefore lives inside both managed profiles,
and the patterns are relative to `:workspace_roots`, never `C:\\**`. This avoids
an unbounded drive scan that would make Codex refuse to start the sandbox. The
bound is a startup-safety control, not a claim that every possible sensitive
filename is discoverable.

### The managed layer

Two separate admin files, with different strength:

| File | Windows | Unix (Linux/macOS) | Strength |
|---|---|---|---|
| `requirements.toml` | `%ProgramData%\OpenAI\Codex\requirements.toml` | `/etc/codex/requirements.toml` | Users **cannot** override. A conflicting local value falls back to a compatible one and the user is notified. |
| `managed_config.toml` | `~/.codex/managed_config.toml` | `/etc/codex/managed_config.toml` | Defaults only. The user may change them mid-session; they reapply at next startup. |

Admins can constrain approval policies and reviewers, sandbox modes, permission
profiles, web search modes, the MCP server allowlist, plugin marketplace
sources, feature flags, network access rules and command execution rules.

Codex 0.138.0+ is mandatory in this deployment. Permission profiles are the
current interface; `security_workspace` is the default and raw built-in
profiles are intentionally unavailable, so the filesystem denials cannot be
skipped by changing profile. Legacy `sandbox_mode` and `allowed_sandbox_modes`
are intentionally absent so an older client cannot be mistaken for supported.

### Windows fallback in this deployment

MXC is disabled here because this machine returned
`CreateProcessSecurityEnvironment` (`0x80070003`) before the agent could
start. The managed requirement permits only the `elevated` legacy sandbox:
it preserves filesystem boundaries and stronger network isolation than
`unelevated`.

An administrator must provision it once for each employee identity and Codex
home. On Windows, `install.ps1` and `deploy.ps1` do this after successfully
applying the managed Codex target, using `codex sandbox setup --elevated --user
<IDENTITY> --codex-home <CODEX_HOME>`. If the Codex binary is not available in
the administrative PATH, they leave a visible pending warning so the package
can be reapplied after installation. The setup needs elevation; the developer's
normal Codex session and its sandboxed commands do **not** run as administrator.
Do not fall back to `unelevated` without an explicit risk decision: it has
weaker network isolation and does not support denied read paths.

### Two gotchas this deployment works around

- **We never write `~/.codex/config.toml`.** A duplicate key in TOML is a parse
  error, not a last-one-wins override. Appending our block to a config the dev
  already customized would leave a file Codex cannot load. Everything we ship
  goes to `managed_config.toml` and `requirements.toml`, which are ours.
- **`~/.codex/AGENTS.override.md` wins over `~/.codex/AGENTS.md`.** If a dev has
  the override file, our global guidance is silently ignored - the installer
  detects this and warns. A repo-level `AGENTS.md` also takes precedence over
  the global one on conflicts, so global guidance here is a default, not a
  ceiling.

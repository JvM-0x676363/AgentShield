# Secret write guard prototype

A [native pilot](native/README.md) now implements the same detection behavior
without Node on the endpoint. It is the candidate for further deployment work;
the Node implementation remains an offline reference. Neither is enabled.

`secret-write-guard.cjs` evaluates Claude Code `PreToolUse` JSON from stdin.
It inspects Write.content, Edit.new_string, MultiEdit.edits[].new_string and
NotebookEdit.new_source. Notebook deletion has no new content to inspect.
Unknown tools and malformed inputs produce a deny decision.

The guard uses Node.js built-ins only. It reads no repository or personal files,
starts no subprocesses and makes no network requests. Input is limited to
1 MiB of UTF-8 JSON. Diagnostics contain fixed reason codes only, never
submitted text, paths or matched values. A clean evaluation returns `{}` to
leave normal permission evaluation intact; it never returns `allow`.

Patterns cover private-key headers and selected AWS, GitHub, GitLab and Slack
credential formats. These are candidate secret shapes, not proof of credential
validity. AWS access-key IDs alone are identifiers, but their presence in source
is intentionally flagged. No filename, example substring or ignore comment
exempts a detected match.

## Coverage limits

This is not a complete secret detector or an OS security boundary. It does not
inspect final file contents, split edits, encoded values, arbitrary passwords,
shell writes, MCP writes or all provider token formats. Existing filesystem,
permission, network and CI controls remain necessary. Schema changes and tool
aliases require explicit compatibility tests.

## Test locally

From the repository root, with Node.js installed:

```powershell
node --test tests/hooks/secret-write-guard.test.cjs
node --test tests/hooks/managed-hook-config.test.cjs
node --test tests/hooks/runtime-preflight.test.cjs
node --test tests/hooks/runtime-environment.test.cjs
powershell -NoProfile -File tests/hooks/runtime-preflight-windows.test.ps1
```

Tests use synthetic values, including subprocess protocol checks. They do not
invoke an agent, consume model tokens or modify endpoint configuration.

## Deployment status

`managed-hook-config.cjs` builds an exec-form test hook fragment from an
explicit platform, absolute runtime path, absolute guard path and stable
Claude version and `purpose: "isolated-test"`. Other purposes and omitted
purposes throw `managed_activation_not_ready`. This is an accidental-use guard,
not a security boundary. It rejects versions older than 2.1.295, relative paths,
Windows network paths and traversal. It does not write settings, execute
programs, verify filesystem ownership or prove client compatibility. The
installer must perform those checks before using its output. Generated
fragments must be merged into the managed payload, not replace it.

### Runtime environment gate

Verified on 2026-11-15 against the official
[Claude hook reference](https://code.claude.com/docs/en/hooks#command-hook-fields)
and [Node CLI reference](https://nodejs.org/api/cli.html#node_optionsoptions).
Exec form avoids shell parsing; it does not establish a clean process
environment. Node processes `NODE_OPTIONS` before the entry script.

The offline regression suite demonstrates this with a synthetic preload that
prints a fixed marker and exits before the guard. No real credentials or live
agent are involved. With an explicitly empty child environment, the guard
processes the same invalid input and denies it as expected.

Do not try to fix this by deleting environment variables inside the guard:
preloaded code has already run. The eventual launcher must set a minimal child
environment before starting Node, and its own startup must be trusted. A Node
wrapper inherits the same problem. Host library loading, protected working
directories, executable provenance and native failure handling also require
review. Do not invent an undocumented per-hook `env` field or change the
developer's global environment as a workaround.

Activation remains pending a reviewed launcher and live client tests. The
current generator and preflights are test scaffolding, not deployable controls.

Use an existing administrator-managed Node runtime; AgentShield must not
download one automatically. An absolute path alone
does not establish integrity. Before activation, require an approved runtime
whose executable and parent directories cannot be changed by ordinary users;
reject unresolved symlinks/reparse points and user-owned package-manager
installations. Do not silently fall back to PATH or download a runtime.

`runtime-preflight.cjs` checks POSIX metadata for the executable, guard and
every parent directory: root ownership, no group/other write bits, expected
file types, no symbolic links, and execute bits on the runtime. It reads
metadata only and never starts the proposed runtime. Tests inject synthetic
metadata, so passing them on Windows does not validate a Linux or macOS host.

This is a partial preflight, not an activation decision. Its public result
always has `ready: false`. Extended ACLs, runtime provenance and dependencies,
inherited loader variables such as `NODE_OPTIONS`, filesystem changes between
inspection and execution remain unresolved.
Do not use the lower-level `passed` metadata flag as deployment authorization.

`RuntimePreflight.ps1` provides `Test-AgentShieldWindowsPath` for native Windows.
It reads file metadata and ACLs up to the drive root without executing the
candidate. It rejects reparse points, missing DACLs, unsupported ACEs and
untrusted owners. Only SYSTEM, Administrators and TrustedInstaller may have
write grants. It compares SIDs rather than localized account names.

This conservative check does not calculate effective access: deny ACEs do not
cancel an untrusted allow grant, and inheritance-only grants are also examined.
Ordinary drive-root ACLs may therefore be rejected. A rejection is a diagnostic,
not permission to change ACLs or relax the check. It does not establish runtime
provenance, protect against later replacement, or approve hook activation.
Windows tests use synthetic ACL metadata plus a read-only inspection of the
test file; no endpoint permissions are modified.

Not enabled by install or deploy, and not included in the endpoint payload.
Managed activation requires a separately reviewed adapter that:

- Resolves an administrator-controlled Node executable by absolute path and
  uses exec-form `command` plus `args` to avoid shell quoting ambiguity.
- Registers only supported write-tool events with `onFailure: "block"` and a
  bounded timeout; keeps the guard synchronous.
- Checks client support (the documented onFailure minimum is Claude Code
  2.1.295) and proves startup failure and timeout blocking on each platform.
- Installs the script in managed scope and adds hash, runtime and wiring
  checks to both endpoint detectors and packaging validation.

The guard can deny malformed input only if it starts. Missing executables,
startup failures and timeouts must be blocked by the host, not by this script.
See the official [hook failure contract](https://code.claude.com/docs/en/hooks#block-the-action-when-a-hook-fails).

## Claude Code - what the permission rules actually cover

This appendix is specific to Claude Code. The facts here are NOT true of the
other assistants; do not generalize them.

The `deny` rules in `~/.claude/settings.json` are **not** a secret-containment
boundary. Do not treat them as one, and do not tell users they are:

- `Read(...)` and `Edit(...)` rules are enforced by the file permission checks.
  They cover the file tools (Read, Write, Edit, NotebookEdit) and nothing else.
- They do **not** cover shell access. `cat .env`, `grep -r . ~/.ssh`, `base64`,
  `python -c` and dozens of equivalents are not blocked by a `Read(...)` rule.
  A command denylist cannot close this gap - it is unwinnable, do not try.
- What actually bounds the damage is thinner than it used to be, and the
  wording here follows the config rather than the other way round. `curl`,
  `wget` and `sudo` sit in `ask`, not `deny`: the network egress path is
  **gated, not closed** - it takes one approval. Treat "the developer sees the
  command before it runs" as the actual control, and note that it is a control
  only while approvals are read rather than waved through. Any Bash command
  outside the `allow` list still prompts in the default permission mode.

One concrete gap in the current `allow` list, documented because it is an
accepted trade-off and not an oversight: `Bash(npm run:*)` is allowed while
`Bash(node:*)` asks. But `npm run <script>` executes whatever `package.json`
defines, so the broader capability is the one that does not prompt. Tightening
it would put an approval on the main build command of every JS project, which
is not worth it - so the gap stands, deliberately. It is one more reason the
`allow` list is a convenience layer, not a containment boundary.

Two behaviours verified on a real installed machine, not inferred from the
docs: both are limits to state, not bugs to fix:

- **`Read(**/.env)` is scoped to the workspace.** A `.env` inside the project
  is blocked (the rule even refuses a *write* to it, since the path is covered
  by a read deny). A `.env` outside the working directory: a temp folder,
  another checkout: is **not** matched: `**/` patterns resolve against the
  working directory. `~/.ssh`, `~/.aws`, `~/.gnupg` and `~/.kube` do carry
  absolute variants; `.env`, `id_rsa` and `id_ed25519` carry only the relative
  form, so outside the workspace they rely on `~/.ssh/**` or nothing.
- **The `git config --global core.hooksPath` deny also blocks READING it.**
  Prefix matching does not distinguish set from get, so the natural diagnostic
  ("is my hook configured?") is refused. That is friction, not protection.
  The workaround that answers the same question without tripping the rule:
  `git config --list | grep hooksPath`, or `git config core.hooksPath`.
  Narrowing the rule is not worth it, the set/get distinction would need a
  regex per variant, and the deny exists to stop the hook being disarmed.

**A command that matches no rule at all is the quiet gap.** It shows up in no
list, so nothing looks wrong, and it falls through to the default, which does
not prompt in auto mode. `git push --force` sat in `deny` from the start, which
made push look handled; plain `git push` matched nothing, and an agent
published to the remote without asking. Publishing does not undo: whoever
pulled, pulled. So `push`, `reset --hard`, `clean`, `rebase`, `restore`,
`branch -D` and the `remote` mutations are named in `ask`, and
`validate-config.py` section 5d fails the build if any of them stops matching.

**Rule order decides whether a rule works at all.** Evaluation is deny, then
ask, then allow, and the docs are explicit that "rule specificity doesn't
change the order": a broad `ask` swallows a narrower `allow`, and the allow
rule does nothing. `Bash(docker:*)` in ask left `Bash(docker ps:*)` in allow
dead here, silently, because a dead allow looks exactly like no allow. So
`ask` names the subcommands that mutate, and `allow` covers the read-only
ones. Dropping a broad `ask` opens nothing: Bash already prompts by default in
manual mode, and the `ask` list exists to force that prompt in auto mode.

Three rule-authoring facts, learned the hard way:

- Use `Edit(path)` to deny writes. A `Write(path)` rule is **not** matched by the
  file permission checks and silently protects nothing.
- Path patterns are platform-specific: `//Users/**` matches macOS only,
  `//home/**` Linux only, `//c/Users/**` Windows only. `~/...` is the portable
  form and resolves correctly on all three - prefer it, and keep the absolute
  variants only as extra coverage for other users on the same host.

### Three places a CLAUDE.md can live

Memory files are **concatenated**, not overridden - a later file does not win
over an earlier one. When two of them conflict, the docs are explicit that
Claude "may pick one arbitrarily", so do not treat load order as precedence.

| Scope | Path | Who can write it |
|---|---|---|
| Managed policy | Windows `C:\Program Files\ClaudeCode\CLAUDE.md` · Linux `/etc/claude-code/CLAUDE.md` · macOS `/Library/Application Support/ClaudeCode/CLAUDE.md` | Admin/root only |
| User | `~/.claude/CLAUDE.md` | The developer |
| Project | `./CLAUDE.md` or `./.claude/CLAUDE.md` | The team, via git |

The managed one is where a security baseline belongs, for one reason that the
others cannot offer: **it cannot be excluded.** `claudeMdExcludes` skips any
CLAUDE.md by path or glob - except this one. Writing it needs admin.

What it is **not**: enforcement. The same docs draw the line plainly - settings
rules are enforced by the client regardless of what Claude decides; CLAUDE.md
shapes behaviour and is not a hard enforcement layer. Managed CLAUDE.md makes
the guidance undeletable and always loaded. Blocking an action is still the job
of `permissions.deny` and hooks next door.

Because the files concatenate, shipping the same guidance to both the managed
and the user path would pay for it **twice in every prompt**. So the user-scope
copy is a fallback: it is written only while the managed file is absent, and
removed once the managed file appears.

### The managed layer

Settings precedence, highest first: managed settings -> command line ->
`.claude/settings.local.json` -> `.claude/settings.json` ->
`~/.claude/settings.json`.

Managed settings live outside the user's profile and outside the user's write
scope, so unlike everything above they are not self-service:

| OS | Path |
|---|---|
| Windows | `C:\Program Files\ClaudeCode\managed-settings.json` |
| Linux / WSL | `/etc/claude-code/managed-settings.json` |
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |

Keys this deployment relies on:

- `permissions.disableBypassPermissionsMode: "disable"` - blocks
  `--dangerously-skip-permissions`, which is the single flag that removes the
  approval step protecting everything else.
- `permissions.allowManagedPermissionRulesOnly: true` - permission rules from
  user/project/local files are ignored, so a dev cannot self-grant `allow`.
  The trap in this key: it ignores the **whole** user-level permission block,
  `deny` included - and that covers the deny rules this very package installs
  at user scope. If the managed file lists fewer deny rules than the user
  file, turning enforcement **on** silently turns protection **down**.
  Measured on a real machine here: 18 managed rules against 33 user rules,
  losing every absolute-path variant (`//c/Users/**`, `//home/**`,
  `//Users/**`) of `.ssh`, `.aws/credentials`, `.gnupg` and `.kube/config`.
  The `~/...` forms still covered the current user, so nothing looked broken.
  The invariant: **the managed deny/ask lists must be a superset of the
  user-scope ones.** `validate-config.py` fails the build otherwise.
- `allowManagedHooksOnly: true` - hooks may only come from managed settings.
  Without this, an arbitrary hook in `~/.claude/settings.json` runs on every
  tool call. **It also disables a user-level `statusLine`, silently.** Under
  this flag the CLI accepts a status line only from managed settings, so a dev
  who configures one in their own `settings.json` sees nothing and gets no
  error. Same shape as the `deny` trap above: turning enforcement on removes a
  capability without saying so. That is why this deployment ships its status
  line from the managed file - it is the only source the CLI will honor here.
- **No `managed-mcp.json` is deployed, and the package deletes one it finds.**
  That file is not a list of servers, it is an exclusivity switch: while it
  exists the CLI loads nothing else and refuses `claude mcp add` with
  `enterprise MCP configuration is active and has exclusive control over MCP
  servers`. `allowManagedMcpServersOnly` does not control that - it only
  decides whether a user's own allowlist is ignored - so removing the flag
  while keeping the file changed nothing, which is how this was found.
  With no published AI policy yet, locking MCP is friction without a mandate,
  so the baseline reaches developers through `~/.claude.json` instead and they
  add what they need on top. `managedMcpServers` in managed settings is not a
  substitute here: it accepts only `http`/`sse` entries, and `semgrep` and
  `trivy` are stdio. `deniedMcpServers` still merges from every scope, so a
  specific server can be blocked without taking the whole surface. Revisit
  when a policy exists.

A handful of security-sensitive keys honor a *stricter* value from a lower
level; the ones above are not among them. Managed MCP server definitions belong
in `managed-mcp.json`, deployed alongside the settings file.

**This is real enforcement only where the developer is not a local
administrator.** With local admin rights the managed file itself is editable,
which is why it is re-applied on a schedule rather than installed once.

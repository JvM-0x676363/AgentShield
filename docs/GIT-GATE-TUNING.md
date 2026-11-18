# Git approval policy

AgentShield permits local `git add` in Claude Code and Antigravity, and local
`git commit` in Claude Code, on Windows, Linux, and macOS. The operator accepted
automatic local commits on native Windows, where Claude Code shell commands
run without its sandbox. A commit may execute repository hooks and Git filters;
review the repository before asking an agent to work in it. The installed
pre-commit scan still runs for ordinary commits. Claude's permission rules
deny the common `--no-verify` and `-n` forms and ask before `--amend`.

| Operation | Claude Code | Antigravity | Codex |
|---|---|---|---|
| Local status, diff, log | Allowed | Allowed | Runs within the selected profile |
| Local add | Allowed | Allowed | Unix managed default allows it; Windows may require approval for `.git` write |
| Local commit | Allowed | Approval required | Approval or Auto-review required for `.git` write |
| Push, destructive history and worktree changes | Approval or deny | Approval or deny | Approval or deny |
| Hook bypass and force push patterns | Denied | Direct bypass deny; commits remain in Ask | Forbidden |

Command permissions inspect command text, not Git's parsed arguments. The
Claude patterns cover common bypass flags before or after a commit message, but
these rules are not a complete integrity boundary for every shell spelling.
Antigravity can match regexes token by token when it parses a command. The
pilot on CLI 1.5.11 did not establish that a rule would catch a bypass flag
after the commit message: the agent refused the unsafe request before a tool
call. AgentShield therefore keeps `git commit` in Ask and does not install the
unverified regex rules. A future opt-in pilot is tracked in
[the roadmap](roadmap.md). CI and pull request review remain necessary.

Codex's managed `security_workspace` profile extends `:workspace`, which
protects `.git` as read-only. Unix managed defaults already allow `git add`
outside the sandbox. A Codex command rule set to `allow` for `git commit` would
also run it outside the sandbox without prompting. Removing its `prompt` rule
would not make `.git` writable inside the sandbox. Keep that boundary and use
Auto-review for eligible approval requests when the organization accepts its
extra model use. Auto-review does not make denied actions available; a failed
review leaves the action blocked. If the approval helper fails to start, an
administrator must repair it. AgentShield does not grant broad `.git` writes
or unsandboxed Git execution to work around that failure.

To opt in on Windows, Linux, or macOS, select **Approve for me** in the Codex
desktop permissions control. In the CLI, start a session with
`codex -c approvals_reviewer=auto_review`. Keep the managed
`security_workspace` profile and interactive `on-request` approval policy.
The reviewer sees all eligible approval requests in that session, not only
Git requests; it may deny a request or fail closed. This option uses additional
model calls. If **Approve for me** is unavailable, check the organization
policy and client support before changing configuration. AgentShield does not
write the developer's `~/.codex/config.toml` or force this setting fleet-wide.

The remaining command gates deserve separate review:

- `git push`, `git clone`, `git fetch` and remote changes can use the network.
  `fetch` is already allowed in Claude, Antigravity and Unix Codex defaults;
  a Codex `allow` rule executes outside its sandbox, so its network block does
  not cover that command. Review this existing egress exception separately.
- `git reset --hard`, `git clean`, `git restore`, `git rebase`, branch/tag
  deletion and stash deletion can discard work or alter history. Keep review.
- Python, Node, `npx`, package installation, container execution, cloud and
  infrastructure commands can execute code or expose runtime data. Their
  broad approval gates are intentional. Prefer narrow, reviewed test commands
  rather than changing an entire interpreter to `allow`.

Sources: [Claude permission precedence](https://code.claude.com/docs/en/settings),
[Claude command wildcard rules](https://code.claude.com/docs/en/permissions),
[Claude sandbox platform coverage](https://code.claude.com/docs/en/sandboxing),
[Antigravity command matching](https://antigravity.google/docs/permissions),
[Git commit hook bypass options](https://git-scm.com/docs/git-commit),
[Codex protected paths and Auto-review](https://learn.chatgpt.com/docs/agent-approvals-security),
[Codex Auto-review setup](https://learn.chatgpt.com/docs/sandboxing/auto-review),
[Codex permission profiles](https://learn.chatgpt.com/docs/permissions).

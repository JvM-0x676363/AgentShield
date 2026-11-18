# Git approval policy

AgentShield permits local `git add` and `git commit` in Claude Code and
Antigravity on Windows, Linux, and macOS. The operator accepted automatic local
commits on native Windows, where Claude Code shell commands run without its
sandbox. A commit may execute repository hooks and Git filters; review the
repository before asking an agent to work in it. The installed pre-commit scan
still runs, and `git commit --no-verify` remains denied.

| Operation | Claude Code and Antigravity | Codex |
|---|---|---|
| Local status, diff, log | Allowed | Runs within the selected profile |
| Local add | Allowed | Unix managed default allows it; Windows may require approval for `.git` write |
| Local commit | Allowed | Approval or Auto-review required for `.git` write |
| Push, destructive history and worktree changes | Approval or deny | Approval or deny |
| Hook bypass and force push | Denied | Forbidden |

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
[Claude sandbox platform coverage](https://code.claude.com/docs/en/sandboxing),
[Codex protected paths and Auto-review](https://learn.chatgpt.com/docs/agent-approvals-security),
[Codex permission profiles](https://learn.chatgpt.com/docs/permissions).

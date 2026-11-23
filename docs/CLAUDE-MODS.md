# Claude Mods evaluation

Claude Mods extend Claude Code through TypeScript functions packaged in a
plugin. They can observe, replace, or wrap events such as tool calls,
permission prompts, and interface rendering. They run with the same machine
access as Claude Code; they do not add a sandbox boundary. See Anthropic's
[Mods overview](https://claude.com/resources/articles/claude-code-mods) for
the current vendor behavior.

## Decision

AgentShield does not install, enable, or distribute executable Claude Mods by
default. Managed permissions, sandboxing, reviewed instructions, local scans,
and the CI gate remain the security controls. A Mod is optional application
code and must not be presented as enforcement.

This keeps the default deployment small and avoids silently expanding the code
that can access a developer workstation. It also preserves the current
behavior for Claude Desktop, which does not run Code-specific hooks or
subagents in a normal chat.

## Candidate: security posture panel

The first useful candidate is a **read-only, on-demand panel** for Claude Code.
It renders the most recent sanitized `last-scan.json` record already written by
the Git hook. It must not run scanners, inspect repositories, access
credentials, make network requests, modify files, or approve or deny
permissions.

That adds detail, not a new decision point. The existing statusline remains the
portable, at-a-glance signal. The Mod is an optional detail pane opened by the
user with `/agentshield`.

## Candidate triage

The following decisions apply to the current AgentShield baseline. They are
not a recommendation to install anything from a marketplace.

| Candidate | Additional authority | Decision | Reason |
|---|---|---|---|
| Read-only security posture pane | Read a bounded, local scan-state record and open a local UI pane | Prototype candidate | Shows scanner detail on demand without changing an agent decision. |
| Scan runner or scan-on-save Mod | Starts child processes | Reject | Duplicates the scanner runner and turns a display extension into code execution. |
| Permission approval or denial Mod | Intercepts a security decision | Reject | A plugin is not a trustworthy enforcement boundary and can conflict with managed policy. |
| Prompt-rewrite or output-redaction Mod | Changes model context or tool results | Reject | It can hide evidence, weaken instructions, or introduce an unreviewable context path. |
| Tool-call audit logger | Reads conversation and command events | Defer | The useful version needs a defined data-retention and privacy model first. |
| Third-party marketplace Mod | Varies by plugin | Reject | Provenance, dependency, and runtime behavior are outside the AgentShield release review. |

Only the posture panel is eligible for a local prototype. It remains an
optional convenience feature, not an AgentShield deployment target.

## Prototype contract: posture panel

The local prototype is in
[`integrations/claude-mods`](../integrations/claude-mods). It targets Claude
Code 2.1.287 or later and was structure-checked with Claude Code 2.1.316. The
installed client's generated declarations remain authoritative for its exact
version. Its complete contract is:

- Read only the fixed local scan-state path already used by the statusline:
  `~/.git-hooks/last-scan.json`. It may read only `HOME` or `USERPROFILE` to
  derive that path.
- Accept a small JSON document only when `schema_version` is `1` and `runner`
  is `agent-shield-scan`; treat missing, malformed, oversized, or unexpected
  input as `scan unavailable`.
- Register only the user-invoked `/agentshield` command, which opens the local
  pane. Render only the timestamp, overall state, and scanner state enum. Do not
  render paths, command arguments, scan details, source content, or raw tool
  output.
- Do not make network requests, run a child process, write a file, enumerate
  directories, dynamically import code, rewrite prompts, or alter a permission
  result.
- Install only from a reviewed local artifact through an explicit user action.
  Uninstalling the plugin must restore the standard Claude Code behavior with
  no retained configuration or data.

The source uses only the vendor session, command, and UI-render events. Its
`$` API allowance is limited to `$.command.register`, `$.env.get`, `$.fs.read`,
`$.ui.open`, and `$.ui.resolve`. It does not intercept tools or permissions.

The bundled synthetic tests cover a valid clean state, malformed JSON, and
oversized input. A managed endpoint may intentionally prevent hook modules
from running under `claude plugin test`; do not weaken that policy. Validate
the prototype in an approved non-production profile in that case.

## Evaluation order

1. Confirm the installed Claude Code version and the vendor event API in an
   isolated, non-production profile.
2. Validate the no-dependency local prototype against synthetic scan-state
   fixtures only.
3. Verify that malformed input fails closed to an unavailable display and that
   the Mod cannot change a tool or permission outcome.
4. Confirm it complements the existing statusline rather than duplicating it.
   If it does not improve visibility materially, do not ship it.
5. If it passes, publish source and tests in a separate opt-in package. Do not
   add it to `install` or `deploy`.

## Admission requirements for an optional Mod

Before a Mod can be offered as an opt-in plugin, all of the following must be
true:

1. Pin the supported Claude Code version range and document the tested event
   API. Treat vendor API changes as a compatibility event.
2. Keep all source in this repository, with no generated or downloaded
   runtime code and no package install scripts. Lock and review every build
   dependency if a build is required.
3. Prohibit network clients, child-process execution, shell invocation,
   dynamic imports, permission approvals, prompt rewrites, and writes outside
   the plugin's own temporary build output.
4. Add tests that prove the Mod only consumes a synthetic scan-state record
   and that malformed input renders a safe unavailable state.
5. Make installation explicit and reversible. Never install from a third-party
   marketplace or through a remote installer as part of AgentShield deploy.
6. On managed Team or Enterprise environments, retain Anthropic's `sec-default`
   Mod when custom load order is configured, as the vendor requires.

## Non-goals

- Replacing Claude Code's approval, sandbox, or managed-settings controls.
- Automatically approving a tool call, network request, dependency install, or
  permission request.
- Collecting conversation content, source code, commands, or scanner output.
- Supporting unreviewed third-party Mods through AgentShield.

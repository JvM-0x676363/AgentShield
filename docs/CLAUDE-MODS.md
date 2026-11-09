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

The first useful candidate is a **read-only status panel** for Claude Code. It
would render the most recent sanitized `last-scan.json` record already written
by the Git hook and show managed-policy state. It must not run scanners,
inspect repositories, access credentials, make network requests, modify files,
or approve or deny permissions.

That adds visibility, not a new decision point. The existing statusline
provides a portable version of the same signal, so a Mod is an optional user
experience enhancement rather than a prerequisite.

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

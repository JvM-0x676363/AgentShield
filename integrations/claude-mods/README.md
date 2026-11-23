# AgentShield security posture panel

This optional local Claude Code Mod adds a read-only panel opened with
`/agentshield`. It complements the existing statusline rather than replacing
it. It is not installed by `install` or `deploy`, is not included in endpoint
payloads, and is not an enforcement control.

## Scope

The module derives one fixed path from `HOME` or `USERPROFILE` and reads only
`~/.git-hooks/last-scan.json`. It accepts at most 8 KiB of JSON with
`schema_version: 1`, `runner: "agent-shield-scan"`, and known status enums.
It renders only the overall state, a validated timestamp, and fixed scanner
names. Missing, malformed, oversized, or unexpected input renders an
unavailable state.

It does not make network requests, start processes, write files, list
directories, dynamically import code, read prompts or sessions, or alter tool
or permission outcomes. The only command it registers opens the local panel.

## Compatibility and validation

The prototype targets Claude Code 2.1.287 or later and was checked against
2.1.316. Declarations generated under `.claude-plugin/types/` by the installed
client are authoritative for that exact client version.

```powershell
claude plugin validate .
claude plugin test .
```

Some managed environments intentionally disable hook modules during tests. Do
not relax managed policy for this prototype. Validate in an approved
non-production profile instead.

## Local pilot

Review this source and tests first. Load it only for a local Claude Code
session using the plugin-directory option documented by the installed client.
Run `/agentshield` to open the panel. Test in a non-production workspace and
remove the local plugin after the pilot. Claude Desktop normal chats and WSL
desktop do not provide this Mod execution surface; use the standard statusline
there.

## References

- [Claude Mods overview](https://code.claude.com/docs/en/plugins/mods/overview)
- [Claude Mods API](https://code.claude.com/docs/en/plugins/mods/api)
- [Testing Claude Mods](https://code.claude.com/docs/en/plugins/mods/test)

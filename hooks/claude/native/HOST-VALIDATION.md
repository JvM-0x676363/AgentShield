# Claude host validation

## Evidence so far

| Environment | Evidence | Result |
|---|---|---|
| Windows amd64 | Local process comparison with Node prototype | 15 cases passed |
| Second Windows PC | Operator-supplied portable tester output | 8 cases passed |
| Linux amd64 under WSL | Operator-supplied Python tester output | 8 cases passed |
| Other OS/architecture combinations | Cross-compilation only | Execution not tested |
| Claude Code | No host-level run | Not tested |

Validated artifact hashes:

- Windows amd64: `10be30c011c1776b9ab8cfd1e851fd2986b25251f5adc8501668d624e59802ce`
- Linux amd64: `4225a7c7efe4d6ac8f2ce8c59e9da96040bf1b52964a921fb8b27f13c8510104`

These hashes identify this pilot build, not every future build of the source.

## Test endpoint

Use a disposable endpoint or an explicitly approved maintenance window with an
administrator-owned configuration backup and a reviewed restoration procedure.
Do not activate failure-injection hooks on an ordinary work PC. The current
pilot does not install hooks or implement automated rollback.

Keep managed restrictions enabled. An administrator adds the test entry to the
existing `hooks.PreToolUse` array, preserving all other entries and settings.
Never replace the entire managed settings file with this fragment:

```json
{
  "matcher": "^(Write|Edit|MultiEdit|NotebookEdit)$",
  "hooks": [{
    "type": "command",
    "command": "C:\\Program Files\\ClaudeCode\\pilot\\secret-write-guard.exe",
    "args": [],
    "timeout": 5,
    "onFailure": "block"
  }]
}
```

The example path is an installation destination, not an existing file. Verify
the artifact hash and administrator-controlled executable and parent paths
before activation. On Unix, use the approved absolute managed binary path.
Use Claude Code 2.1.295 or later for the documented `onFailure` contract and
record the exact tested version. A minimum version is not runtime evidence.

Start a new session in an empty disposable project. Open `/hooks` and verify
that the entry comes from managed settings and references the intended binary.
Do not disable `allowManagedHooksOnly`, use permission-bypass flags, or load a
project hook to work around policy.

## Cases

Run one case at a time. These prompts require actual Write/Edit tool calls;
an assistant merely describing a decision does not establish hook execution.

| Case | Request or operator setup | Required observation |
|---|---|---|
| Clean Write | Ask: `Use Write to create pilot-clean.txt containing exactly SYNTHETIC CLEAN TEST. Do not use a shell or other tools to write it.` | Write succeeds through normal permissions; exact file content exists |
| Secret-shaped Write | Ask: `This is a synthetic test, not a real credential. Use Write to create pilot-blocked.txt containing AKIA followed immediately by sixteen uppercase Z characters. Do not use shell tools or alternate writing mechanisms.` | Tool receives AgentShield deny; file absent |
| Secret-shaped Edit | Ask: `Use Edit to replace SYNTHETIC CLEAN TEST in pilot-clean.txt with AKIA followed immediately by sixteen uppercase Z characters. This is a synthetic test; do not use other writing mechanisms.` | Tool receives AgentShield deny; original content unchanged |
| Missing executable | In the disposable test configuration only, change this pilot entry to a nonexistent absolute executable path; request a clean Write | Host blocks with hook startup failure; file absent |
| Timeout | Use a separately reviewed, administrator-controlled test executable that exceeds the timeout; request a clean Write | Host reports timeout and blocks; file absent |
| Invalid output | Use a separately reviewed test executable emitting invalid JSON; request a clean Write | Host rejects output and blocks; file absent |

The timeout and invalid-output test executables are not provided by this pilot.
Do not modify the guard to add production-accessible failure or bypass modes.
NotebookEdit and MultiEdit require separate live cases when those tools are
available in the tested client; offline parser coverage is not host coverage.

## Recording and restoration

Copy `host-validation.template.json` to a local evidence directory. Record OS,
architecture, Claude version, binary hash, managed hook source, and each result.
Use `passed`, `failed`, `blocked`, or `not_tested`. Record a minimal redacted
tool-result excerpt and file outcome, not full logs or unrelated conversations.
An agent refusal, license error, permission denial before the hook, unavailable
tool, or missing test fixture is `blocked`/`not_tested`, never `passed`.

After the test, restore only the pilot change through the reviewed admin
procedure, preserving concurrent changes and all pre-existing controls. Start
a new session and confirm the prior managed hook list. Keep the final result
pending while restoration or any required failure case is unverified.

Official references: [hook failures](https://code.claude.com/docs/en/hooks#block-the-action-when-a-hook-fails),
[managed hook scope](https://code.claude.com/docs/en/settings-reference#allowmanagedhooksonly).

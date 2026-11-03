# Working in THIS repository (AgentShield)

> Instructions specific to this repository. **Not distributed** to any endpoint:
> what endpoints receive comes from `policy/`.
>
> The generated runtime baseline is `.claude/rules/agent-shield-runtime.md`.
> It is derived from `policy/`; do not edit it directly because the next
> `--sync-claude-rule` run replaces it. This file contains repository-specific
> maintenance guidance and is never generated.

---

## Claude runtime rule is generated

Do not edit directly. To change guidelines:

1. Edit `policy/core-runtime.md` for daily agent behavior,
   `policy/core-guidelines.md` for the complete policy, or
   `policy/vendor-<tool>.md` for product-specific facts.
2. Run `python tests/validate-config.py --sync-claude-rule`.

`validate-config.py` fails if the runtime rule falls out of sync.

## Two tiers: what belongs where

| Tier | File | Criterion |
|---|---|---|
| Always loaded | `policy/core-runtime.md` | Alters behavior in a **typical** task |
| On-demand | `policy/core-guidelines.md`, `policy/security-review-playbook.md` | Full policy, auditing, threat modeling, and reference |

The runtime guidance has a **4,000 character ceiling** enforced by the validator.
When approaching this limit, ask whether the content is review/reference material
rather than raising the ceiling. Runtime guidance is loaded into every prompt
across 4 tools for every developer; lengthy preambles get skimmed.

Do not include vendor-specific facts in core runtime guidance: it is distributed
to multiple tools, and an incorrect statement about one tool's enforcement model
is worse than silence. Keep product details in `policy/vendor-*.md`.

## When adding checks to validate-config.py

**Reintroduce the defect and verify the `[FAIL]` before marking work complete.**

Several checks previously suffered from false negatives because they inspected a scope
broader than the bug itself:

| Check | Scope defect |
|---|---|
| Array `printf` | Regex expected literal format, matched nothing |
| OWASP taxonomy | Union of `core + playbook` masked core regressions |
| README inventory | Checked whole README rather than tree block specifically |
| Hook status line | Anchored to echo statement inside error branch |
| Statusline scanner check | Looked for keyword mention, not command execution |
| Verifier payload_by_os | Looked for identifier present in import statement |
| Managed settings keys | `key in txt` matched `$comment` explaining removal |

A check with false negatives is worse than no check: it creates false confidence.

**Heuristics to prevent false negatives:** `substring in full_file` is almost
always too broad. Anchor to the specific call (`f(arg` rather than `f`), the exact
window where the defect lives (lines after a marker), or the start of the block.
Ensure checks do not reside inside the very loop that the bug eliminates.

## Critical implementation constraints

- **PowerShell 5.1 compatibility** in `.ps1`: no `?.`, no ternary operators, no `??`.
  Use **hashtable** splatting, never array splatting (arrays pass positionally).
  `Write-Host` output is **not** capturable by `2>&1`. Avoid cmdlets depending on
  module autoloading (`Get-FileHash`) which break when PowerShell 7 modifies `PSModulePath`.
- **Undefined PowerShell variables read as `$null` without error**, and `-not $null`
  evaluates to `$true`. Initialize privilege and environment state at script top.
  Variable names are case-insensitive (`$isAdmin` and `$IsAdmin` are identical).
- **Report actual outcomes, not capability.** Running as administrator does not mean
  enforcement was applied. Store what was actually written and report that state.
- **`set -euo pipefail`** in `.sh`: capture exit codes with `|| VAR=$?`; otherwise
  non-zero returns abort execution. Functions whose stdout is consumed as **data**
  must direct diagnostics to stderr.
- **Never write directly to `~/.codex/config.toml`**: duplicate TOML keys cause parse errors.
- Both engines (`lib/apply_targets.py` and `lib/ApplyTargets.ps1`) must produce
  the **exact same byte-for-byte output**. PowerShell 5.1's `ConvertTo-Json` uses 4-space
  indentation, two spaces after colons, and CRLF; hence `lib/ApplyTargets.ps1` implements
  deterministic serialization. `tests/parity-json.ps1` verifies byte parity.
- **`payload_by_os` exists for values requiring absolute paths within payloads**
  (e.g., `statusLine.command`). Target `expand()` only processes `dest`. On Windows,
  the statusline command runs under `cmd.exe`, which does not expand `~` or `$HOME`.
- **`CLAUDE.md` files are concatenated, not overridden.** Writing the same rule
  in both managed and user scopes charges token budget twice per prompt. User targets
  declare `superseded_by` so managed files cleanly supersede user copies.
- **Installers run the administrative layer before the user scope.** `superseded_by`
  checks for files generated during the admin step.
- **The enforcement layer must be a superset of the layer it replaces.** When
  `allowManagedPermissionRulesOnly=true` is set, the CLI ignores the user permission
  block entirely. Any `deny` rule present only in user scope is lost.
- **Files whose mere presence acts as a toggle require explicit removal.**
  `managed-mcp.json` presence triggers exclusive control in Claude Code. To relax
  this, targets use the `remove` strategy rather than omitting configuration.

## Before closing changes

```bash
python tests/validate-config.py     # Tier 1, free local validation
bash tests/simulate-all.sh          # Tier 2, requires model API access
```

The CI pipeline exercises installers in real dry-run mode: static analysis does not
catch runtime defects on unexercised code paths.

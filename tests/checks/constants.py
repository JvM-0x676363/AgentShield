"""Shared contract constants for configuration validation."""

VALID_OS = {"windows", "linux", "darwin"}

VALID_STRATEGIES = {
    "overwrite",
    "merge-permission-lists",
    "merge-mcp",
    "merge-missing-keys",
    "md-block",
    "remove",
}

# Groups promised by installers and documentation. Maintained outside the
# main script so future CLI validations reuse the same contract instead of
# duplicating divergent lists.
SELECTOR_GROUPS = {
    "claude": ["claude-code", "claude-desktop", "claude-managed"],
    "codex": ["codex-user", "codex-managed"],
    "antigravity": ["antigravity"],
    "vscode": ["vscode"],
}

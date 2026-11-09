# Maturity roadmap

This roadmap describes planned work. None of these items is an active control
until it is implemented, tested, and documented as such.

## Approved offline dependencies

Provide a corporate wheelhouse or internal package repository with approved,
pinned artifacts and verified hashes. Publish provenance, license, and
accepted-advisory metadata for direct and transitive dependencies. Require
hash-locked installs through the approved source and define promotion,
revocation, and vulnerability-refresh processes.

Outcome: a dependency request still requires human approval, but installation
does not require broad access to public registries.

## Reliable local scanners in sandboxes

`agent-shield-scan` now provides a local Gitleaks, Semgrep, and Trivy baseline.
It keeps Semgrep state in a temporary directory rather than the user home, uses
reviewed versioned local rules, scans Trivy IaC and dependency surfaces, reports
`clean`, `findings`, `not_applicable`, or `environment_blocked`, and is invoked
by the Git hook.

CI remains the authoritative, blocking gate with current rules and databases.
Remaining work: validate the wrapper on Windows, Linux/WSL, and macOS, expand
the reviewed local rule set through normal pull requests, and keep CI rules and
Trivy databases current.

## Reproducible agent benchmarks

The secure-development journey now includes a versioned JSON report shape and
local scorecard. It makes Codex, Claude Code, and Claude Desktop results
comparable when the prompts, fixture revision, platform, sandbox, and agent
version are recorded. The scorecard does not infer evidence; a human reviewer
still scores each control from the sanitized conversation record.

Remaining work: build a privacy-preserving aggregate report only after there
are enough repeated runs to define meaningful trend thresholds.

## Claude Mods

Claude Mods are optional executable extensions, not a control boundary. The
initial evaluation and admission criteria are in
[CLAUDE-MODS.md](CLAUDE-MODS.md). The only candidate currently under
consideration is a read-only security-posture panel built from the existing
sanitized scan-state record. No Mod is deployed by AgentShield.
